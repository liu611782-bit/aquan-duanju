import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../core/image_cache_store.dart';
import '../core/ops_switches.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/voice/stt.dart';
import '../core/aqua_client.dart';
import '../core/backup_service.dart';
import '../core/download_service.dart';
import '../core/mp4_download_manager.dart';
import '../core/cache_maintenance.dart';
import '../core/error_log.dart';
import '../widgets/cast_receiver_tile.dart';
import '../core/reader/reader_listen_settings.dart';
import '../core/tv/tv_mode.dart';
import '../widgets/tv_scope.dart';
import '../core/reader/reader_speech_settings.dart';
import '../core/reader/speech/chapter_gap.dart';
import '../core/reader/speech/listen_format.dart';
import '../core/reader/speech/listen_stats.dart';
import '../core/reader/speech/notification_permission.dart';
import '../core/tts/http/http_tts_probe.dart';
import '../core/tts/http/http_tts_preview.dart';
import '../core/tts/http/http_tts_source.dart';
import '../core/tts/http/http_tts_source_store.dart';
import '../core/tts/http/tts_source_presets.dart';
import '../core/tts/piper/piper_engine.dart';
import '../core/tts/win/windows_speech_engine.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../theme/app_theme.dart';
import '../update/update_flow.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import 'config_manage_screen.dart';
import 'detail_screen.dart';
import 'book_detail_screen.dart';
import 'bookshelf_screen.dart';
import 'history_screen.dart';
import 'downloads_screen.dart';
import '../widgets/loading.dart';

/// 我的页：观看历史、追剧、设置、关于（含免责声明）。
class MineScreen extends StatefulWidget {
  const MineScreen({super.key});

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _refreshedCovers = false;

  /// 追剧状态筛选：'' = 全部，'update' = 有更新，其余是 FollowState.name。
  String _followFilter = '';

  static const _followFilters = <String, String>{
    '': '全部',
    'want': '想看',
    'watching': '在看',
    'watched': '已看',
    'update': '有更新',
  };

  List<FollowEntry> _filteredFollows(List<FollowEntry> entries) {
    switch (_followFilter) {
      case '':
        return entries;
      case 'update':
        return entries.where((e) => e.hasUpdate).toList();
      default:
        return entries.where((e) => e.state.name == _followFilter).toList();
    }
  }

  @override
  void initState() {
    super.initState();
    // 封面 URL 带签名过期（x-expires 约 60 天），打开本页时用批量详情
    // 刷新一次历史/追剧的封面；静默失败，不影响页面。
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshCovers());
  }

  Future<void> _refreshCovers() async {
    if (_refreshedCovers || !mounted) return;
    final scope = AppScope.read(context);
    final ids = <String>{
      for (final h in scope.history.entries) h.seriesId,
      for (final f in scope.follows.entries) f.seriesId,
    };
    if (ids.isEmpty) return;
    _refreshedCovers = true;
    try {
      final all = ids.toList();
      for (var i = 0; i < all.length; i += 10) {
        final batch = all.sublist(i, (i + 10).clamp(0, all.length));
        final details = await scope.api.getSeriesBatch(batch);
        final covers = <String, String>{
          for (final d in details)
            if (d.series != null) d.series!.id: d.series!.coverUrl,
        };
        await scope.history.refreshCovers(covers);
        // 追剧同时记录服务端集数，用于「有更新」提醒。
        await scope.follows.refreshFromDetails(
            details.map((d) => d.series).whereType<Series>().toList());
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scope = AppScope.read(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable:
            Listenable.merge([scope.history, scope.follows, scope.reading]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _UpdateBanner(),
            _Section(
              title: '继续观看',
              action: scope.history.entries.isEmpty
                  ? null
                  : Row(mainAxisSize: MainAxisSize.min, children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HistoryScreen()),
                        ),
                        child: const Text('全部'),
                      ),
                      TextButton(
                        onPressed: () =>
                            _confirmClear(context, '清空观看历史？', () async {
                          await scope.history.clear();
                        }),
                        child: const Text('清空'),
                      ),
                    ]),
              child: scope.history.entries.isEmpty
                  ? const _EmptyHint('看过之后，这里会记录进度')
                  : Column(
                      children: [
                        for (final h in scope.history.entries.take(10))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 56,
                              height: 76,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: h.coverUrl),
                              ),
                            ),
                            title: Text(h.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              h.finished
                                  ? '已看完'
                                  : '看到第${h.episode}集 ${_fmtPos(h.position)}',
                            ),
                            onTap: () => openDetail(
                                context, h.seriesId, h.title),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () =>
                                  scope.history.remove(h.seriesId),
                            ),
                          ),
                      ],
                    ),
            ),
            // 电视不提供小说/漫画阅读，书架入口一并隐藏。
            if (!TvScope.isTvOf(context))
            _Section(
              title: '书架',
              action: scope.reading.entries.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const BookshelfScreen()),
                      ),
                      child: const Text('全部'),
                    ),
              child: scope.reading.entries.isEmpty
                  ? const _EmptyHint('读过的小说和漫画会出现在这里')
                  : Column(
                      children: [
                        for (final e in scope.reading.entries.take(3))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 52,
                              height: 70,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: e.coverUrl),
                              ),
                            ),
                            title: Text(e.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              '${e.manga ? '看到' : '读到'} · ${e.chapterTitle}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onTap: () => openBook(context, e),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => scope.reading.remove(e.bookId),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '我的追剧',
              child: scope.follows.entries.isEmpty
                  ? const _EmptyHint('追剧之后，更新一目了然')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 状态筛选：全部 / 想看 / 在看 / 已看 / 有更新。
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final f in _followFilters.entries)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(f.value),
                                    selected: _followFilter == f.key,
                                    onSelected: (_) => setState(
                                        () => _followFilter = f.key),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        for (final f
                            in _filteredFollows(scope.follows.entries))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: SizedBox(
                              width: 56,
                              height: 76,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CoverImage(url: f.coverUrl),
                              ),
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(f.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis),
                                ),
                                if (f.hasUpdate)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('更新到${f.latestEpisodeCount}集',
                                        style: TextStyle(
                                            fontSize: 11,
                                            color:
                                                theme.colorScheme.onPrimary)),
                                  ),
                              ],
                            ),
                            subtitle: Text(switch (f.state) {
                              FollowState.want => '想看',
                              FollowState.watching => '在看',
                              FollowState.watched => '已看',
                            }),
                            onTap: () =>
                                openDetail(context, f.seriesId, f.title),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => scope.follows.toggle(
                                seriesId: f.seriesId,
                                title: f.title,
                                coverUrl: f.coverUrl,
                                episodeCount: f.episodeCount,
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '数据',
              child: Column(
                children: [
                  // 我的下载 + 封面刷新入口。
                  ListenableBuilder(
                    listenable: Listenable.merge(
                        [scope.downloads, scope.downloads.store]),
                    builder: (context, _) {
                      final list = scope.downloads.store.seriesList;
                      // 路径标注：与设置页「下载位置」同源（baseDir）。
                      final dirLabel = scope.downloads.baseDir.path;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.download_outlined),
                        title: const Text('我的下载'),
                        subtitle: Text(
                          list.isEmpty
                              ? '在短剧详情页点「缓存」即可离线观看\n$dirLabel'
                              : '${list.length} 部剧集已缓存离线可看\n$dirLabel',
                        ),
                        isThreeLine: true,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const DownloadsScreen()),
                        ),
                      );
                    },
                  ),
                  // MP4 导出与官方离线缓存目录分离（Mp4DownloadManager.outputDir）。
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.video_file_outlined),
                    title: const Text('MP4 导出下载'),
                    subtitle: const Text(
                      '播放页导出 · 可存相册/分享\n目录 mp4_downloads · 相册专辑「阿圈短剧」',
                    ),
                    isThreeLine: true,
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const Mp4DownloadsScreen()),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('MP4 导出目录'),
                    subtitle: Text(scope.settings.mp4OutputDir.isEmpty
                        ? '默认（应用外部存储 mp4_downloads）'
                        : scope.settings.mp4OutputDir),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final picked =
                          await getDirectoryPath(confirmButtonText: '选择');
                      if (picked == null) return;
                      if (!await DownloadService.ensureWritable(
                          Directory(picked))) {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                            const SnackBar(content: Text('该目录不可写，请选择其他目录')));
                        return;
                      }
                      scope.settings.mp4OutputDir = picked;
                      Mp4DownloadManager.instance
                          .configure(customOutputDir: picked);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.photo_library_outlined),
                    title: const Text('导出完成后自动存相册'),
                    value: scope.settings.mp4AutoSaveGallery,
                    onChanged: (v) {
                      scope.settings.mp4AutoSaveGallery = v;
                      Mp4DownloadManager.instance.configure(autoSave: v);
                    },
                  ),
                  const BackupPanel(),
                  const CachePanel(),
                ],
              ),
            ),
            _Section(
              title: '设置',
              child: const SettingsPanel(),
            ),
            _Section(
              title: '关于',
              child: const AboutPanel(),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtPos(double seconds) {
    final m = (seconds / 60).floor();
    if (m >= 1) return '约 $m 分钟';
    return '刚开头';
  }

  Future<void> _confirmClear(
      BuildContext context, String text, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认'),
        content: Text(text),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确定')),
        ],
      ),
    );
    if (ok == true) await action();
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.action});

  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(title,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const Spacer(),
                ?action,
              ],
            ),
            const SizedBox(height: 6),
            child,
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: Text(text,
              style: TextStyle(color: Theme.of(context).colorScheme.outline)),
        ),
      );
}

/// 有新版本时在「我的」页顶部提示；点了跳 GitHub Releases 下载。
class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UpdateService.instance,
      builder: (context, _) {
        final update = UpdateService.instance;
        if (!update.hasUpdate) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.upgrade,
                  color: Theme.of(context).colorScheme.primary),
              title: Text('发现新版本 v${update.latestVersion}'),
              subtitle: const Text('点按前往下载页'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => updateInteractive(context),
            ),
          ),
        );
      },
    );
  }
}

/// 设置面板：主题 / 清晰度 / 倍速 / 历史条数 / 片头片尾 / 播放器高级 / 连播等。
class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.settings,
      builder: (context, _) => Column(
        children: [
          if (OpsSwitches.anyActive)
            Card(
              color: Theme.of(context).colorScheme.errorContainer,
              margin: const EdgeInsets.only(bottom: 12),
              child: ListTile(
                leading: Icon(
                  Icons.pan_tool_alt_outlined,
                  color: Theme.of(context).colorScheme.onErrorContainer,
                ),
                title: Text(
                  '运维急停已开启',
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer),
                ),
                subtitle: Text(
                  [
                    if (OpsSwitches.disableAutoSource) '自动找源',
                    if (OpsSwitches.disableAutoUpdate) '自动检查更新',
                    if (OpsSwitches.disableAutoMerge) '自动重建合并源',
                  ].join(' / '),
                  style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer),
                ),
              ),
            ),
          _selectTile<String>(
            context,
            icon: Icons.brightness_6_outlined,
            title: '主题',
            value: scope.settings.themeMode,
            items: const {
              'system': '跟随系统',
              'light': '浅色',
              'dark': '深色',
            },
            onChanged: (v) => scope.settings.themeMode = v,
          ),
          _selectTile<String>(
            context,
            icon: Icons.hd_outlined,
            title: '默认清晰度',
            value: scope.settings.defaultQuality,
            items: const {
              'best': '最高（推荐）',
              '1080p': '1080p',
              '720p': '720p',
              'worst': '最低（省流量）',
            },
            onChanged: (v) => scope.settings.defaultQuality = v,
          ),
          _selectTile<String>(
            context,
            icon: Icons.download_outlined,
            title: '缓存清晰度',
            value: scope.settings.cacheQuality,
            items: const {
              'best': '最高（体积大）',
              '1080p': '1080p',
              '720p': '720p',
              '540p': '540p（推荐）',
              'worst': '最低（最省空间）',
            },
            onChanged: (v) => scope.settings.cacheQuality = v,
          ),
          if (!Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('下载位置'),
              subtitle: Text(_downloadDirLabel(scope)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _chooseDownloadDir(context, scope),
            ),
          _selectTile<int>(
            context,
            icon: Icons.speed_outlined,
            title: '下载限速',
            subtitle: '限制离线缓存的下载速度，避免占满带宽',
            value: scope.settings.downloadSpeedKbps,
            items: const {
              0: '不限速',
              256: '256 KB/s',
              512: '512 KB/s',
              1024: '1 MB/s',
              2048: '2 MB/s',
              5120: '5 MB/s',
            },
            onChanged: (v) => scope.settings.downloadSpeedKbps = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.downloading,
            title: '同时下载',
            subtitle: '并发集数越高越吃带宽；源站限流时建议保持 1',
            value: scope.settings.downloadConcurrency,
            items: const {1: '1 集', 2: '2 集', 3: '3 集'},
            onChanged: (v) {
              scope.settings.downloadConcurrency = v;
              scope.downloads.concurrency = v;
            },
          ),
          _selectTile<int>(
            context,
            icon: Icons.replay,
            title: '失败自动重试',
            value: scope.settings.downloadRetries,
            items: const {
              0: '不重试',
              1: '重试 1 次',
              2: '重试 2 次',
              3: '重试 3 次',
            },
            onChanged: (v) {
              scope.settings.downloadRetries = v;
              scope.downloads.maxRetries = v;
            },
          ),
          _selectTile<String>(
            context,
            icon: Icons.speed,
            title: '默认倍速',
            value: scope.settings.defaultSpeed,
            items: const {
              '1.0': '1.0x',
              '1.25': '1.25x',
              '1.5': '1.5x',
              '2.0': '2.0x',
            },
            onChanged: (v) => scope.settings.defaultSpeed = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.history,
            title: '历史记录数量',
            value: scope.settings.historyLimit,
            items: {
              for (final n in SettingsStore.historyLimitOptions) n: '$n 条',
            },
            onChanged: (v) async {
              scope.settings.historyLimit = v;
              await scope.history.applyLimit(v);
            },
          ),
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('自动连播'),
            value: scope.settings.autoNext,
            onChanged: (v) => scope.settings.autoNext = v,
          ),
          ListTile(
            leading: const Icon(Icons.tv),
            title: const Text('电视模式'),
            subtitle: Text(
              '${tvOverrideLabel(parseTvOverride(scope.settings.tvMode))}；改动后重启应用生效',
            ),
            onTap: () async {
              final current = parseTvOverride(scope.settings.tvMode);
              final picked = await showDialog<TvOverride>(
                context: context,
                builder: (dialogContext) => SimpleDialog(
                  title: const Text('电视模式'),
                  children: [
                    for (final value in TvOverride.values)
                      SimpleDialogOption(
                        onPressed: () => Navigator.pop(dialogContext, value),
                        child: Text(
                          current == value
                              ? '✓ ${tvOverrideLabel(value)}'
                              : tvOverrideLabel(value),
                        ),
                      ),
                  ],
                ),
              );
              if (picked == null) return;
              scope.settings.tvMode = tvOverrideName(picked);
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('已保存，重启应用后生效')),
              );
            },
          ),
          // DLNA 接收端：允许局域网内设备投到本机（桌面 + Android；
          // iOS 等其余平台整块隐藏，防火墙放行命令仅 Windows 显示）。
          // 投送准入三选与名单管理（设置页形态），运行态写服务准入策略。
          CastReceiverTile(
            onPersistEnabled: (v) => scope.settings.castReceiverEnabled = v,
            onRename: (name) => scope.settings.castReceiverName = name,
            receiverName: scope.settings.castReceiverName,
            admissionMode: scope.settings.castReceiverAdmissionMode,
            onAdmissionModeChanged: (mode) =>
                scope.settings.castReceiverAdmissionMode = mode,
            onAdmissionListsChanged: (allowJson, denyJson) {
              scope.settings.castReceiverAllowIps = allowJson;
              scope.settings.castReceiverDenyIps = denyJson;
            },
          ),
          ListTile(
            leading: const Icon(Icons.mic_none),
            title: const Text('语音输入'),
            subtitle: Text(
              Platform.isAndroid
                  ? '使用系统语音识别（无需配置）；桌面端需配置云识别端点'
                  : scope.settings.voiceDesktopConfigured
                      ? '已配置云识别端点：${scope.settings.voiceBaseUrl}'
                      : '未配置：桌面语音搜剧需要 OpenAI 兼容端点（点此配置）',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showVoiceSettings(context, scope),
          ),
          // 听书：自建朗读 / 引擎 / 音色 / 代理 / 高亮三件套（design.md §7）。
          const ListenSettingsGroup(),
          SwitchListTile(
            secondary: const Icon(Icons.content_cut_outlined),
            title: const Text('片头片尾跳过'),
            subtitle: const Text('按剧设置时间点；片头从开头跳，片尾自然播放到末尾前触发'),
            value: scope.settings.skipIntroOutro,
            onChanged: (v) => scope.settings.skipIntroOutro = v,
          ),
          if (Platform.isWindows)
            _selectTile<String>(
              context,
              icon: Icons.memory,
              title: '硬件解码',
              value: scope.settings.hwdecMode,
              items: SettingsStore.hwdecLabels,
              onChanged: (v) => scope.settings.hwdecMode = v,
            ),
          _selectTile<int>(
            context,
            icon: Icons.sd_storage_outlined,
            title: '网络缓冲时长',
            value: scope.settings.cacheSecs,
            items: const {
              5: '5 秒（省内存）',
              10: '10 秒',
              15: '15 秒',
              30: '30 秒（默认）',
              60: '60 秒（弱网）',
              120: '120 秒',
              300: '300 秒（最稳）',
            },
            onChanged: (v) => scope.settings.cacheSecs = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.av_timer,
            title: '音画同步',
            value: scope.settings.audioDelayMs,
            items: const {
              -500: '音频提前 500ms',
              -200: '音频提前 200ms',
              -100: '音频提前 100ms',
              0: '默认',
              100: '音频延后 100ms',
              200: '音频延后 200ms',
              500: '音频延后 500ms',
            },
            onChanged: (v) => scope.settings.audioDelayMs = v,
          ),
          if (!Platform.isAndroid)
            _selectTile<String>(
              context,
              icon: Icons.aspect_ratio_outlined,
              title: '画面比例',
              value: scope.settings.scale,
              items: SettingsStore.scaleLabels,
              onChanged: (v) => scope.settings.scale = v,
            ),
          _selectTile<int>(
            context,
            icon: Icons.subtitles_outlined,
            title: '字幕字号',
            value: scope.settings.subtitleFontSize,
            items: const {
              36: '小',
              42: '较小',
              48: '标准',
              56: '大',
              64: '特大',
            },
            onChanged: (v) => scope.settings.subtitleFontSize = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.format_size),
            title: const Text('字幕描边'),
            value: scope.settings.subtitleBorder,
            onChanged: (v) => scope.settings.subtitleBorder = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.branding_watermark_outlined),
            title: const Text('字幕背景'),
            subtitle: const Text('半透明黑底，亮画面下更清楚'),
            value: scope.settings.subtitleBackground,
            onChanged: (v) => scope.settings.subtitleBackground = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.shuffle),
            title: const Text('随机看从第 1 集开始'),
            value: scope.settings.randomFromFirst,
            onChanged: (v) => scope.settings.randomFromFirst = v,
          ),
          if (Platform.isWindows || Platform.isMacOS || Platform.isLinux)
            SwitchListTile(
              secondary: const Icon(Icons.aspect_ratio),
              title: const Text('播放时窗口适应片源'),
              subtitle: const Text('竖屏剧自动变竖窗口，横屏剧自动变横窗口'),
              value: scope.settings.autoFitWindow,
              onChanged: (v) => scope.settings.autoFitWindow = v,
            ),
          SwitchListTile(
            secondary: const Icon(Icons.travel_explore),
            title: const Text('自动找源'),
            subtitle: Text(
              OpsSwitches.disableAutoSource
                  ? '运维急停已停用（app_ops.yaml）'
                  : scope.settings.autoDiscovery
                      ? '后台从 GitHub / GitLab / Gitee 发现并验证配置'
                      : '已关闭，仍可在「配置地址管理」手动找源',
            ),
            value: scope.settings.autoDiscovery,
            onChanged: OpsSwitches.disableAutoSource
                ? null
                : (v) {
                    scope.settings.autoDiscovery = v;
                    scope.autoSource.rescheduleOnSettingsChanged();
                  },
          ),
          _selectTile<int>(
            context,
            icon: Icons.schedule,
            title: '找源间隔',
            value: scope.settings.autoSourceIntervalMinutes,
            items: const {
              30: '30 分钟',
              60: '1 小时',
              180: '3 小时',
              360: '6 小时',
            },
            onChanged: scope.settings.autoDiscovery
                ? (v) {
                    scope.settings.autoSourceIntervalMinutes = v;
                    scope.autoSource.rescheduleOnSettingsChanged();
                  }
                : null,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.merge_type),
            title: const Text('自动重建合并源'),
            subtitle: const Text('找源成功后把可用站点合并进 local://merged_sources.json'),
            value: scope.settings.autoMergeSources,
            onChanged: OpsSwitches.disableAutoMerge
                ? null
                : (v) => scope.settings.autoMergeSources = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.shuffle),
            title: const Text('进入影视聚合时随机换源'),
            subtitle: const Text('关闭后按健康分顺序使用第一个源'),
            value: scope.settings.randomHomeSource,
            onChanged: (v) => scope.settings.randomHomeSource = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.filter_alt_outlined),
            title: const Text('搜索按后端去重'),
            subtitle: const Text('同一采集站被多份配置收录时只请求一次'),
            value: scope.settings.dedupeBackendSearch,
            onChanged: (v) => scope.settings.dedupeBackendSearch = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.block_outlined),
            title: const Text('CMS 播放去广告'),
            subtitle: const Text('本地代理重写 m3u8 剔除广告分片；默认关闭更稳，播放失败请保持关闭'),
            value: scope.settings.sourcesAdFilter,
            onChanged: (v) => scope.settings.sourcesAdFilter = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.hub_outlined,
            title: '聚合搜索并发',
            value: scope.settings.searchParallelism,
            items: const {
              2: '2 个源（省流量）',
              4: '4 个源（默认）',
              6: '6 个源',
              8: '8 个源（最快）',
            },
            onChanged: (v) => scope.settings.searchParallelism = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.timer_outlined,
            title: '搜索单源超时',
            value: scope.settings.searchTimeoutMs,
            items: const {
              3000: '3 秒（快）',
              5000: '5 秒（默认）',
              8000: '8 秒',
              10000: '10 秒（慢站）',
            },
            onChanged: (v) => scope.settings.searchTimeoutMs = v,
          ),
          _selectTile<int>(
            context,
            icon: Icons.speed,
            title: '源市场扫描并发',
            subtitle: '并发越高扫得越快，源站不稳时调低',
            value: scope.settings.scanConcurrency,
            items: const {
              4: '4（保守）',
              8: '8',
              12: '12（默认）',
              16: '16',
              24: '24（激进）',
            },
            onChanged: (v) => scope.settings.scanConcurrency = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.swap_horiz),
            title: const Text('详情页显示换源入口'),
            value: scope.settings.detailSourceSwitch,
            onChanged: (v) => scope.settings.detailSourceSwitch = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.system_update_alt),
            title: const Text('启动后自动检查更新'),
            subtitle: Text(
              OpsSwitches.disableAutoUpdate
                  ? '运维急停已停用（仍可手动检查）'
                  : '发现新版本时在「我的」页提示',
            ),
            value: scope.settings.autoCheckUpdate,
            onChanged: OpsSwitches.disableAutoUpdate
                ? null
                : (v) => scope.settings.autoCheckUpdate = v,
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add_check_outlined),
            title: const Text('配置地址管理'),
            subtitle: Text(
              '自动找源：${scope.settings.autoDiscovery ? scope.discovery.statusText : '已关闭'}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const ConfigManageScreen()));
              if (context.mounted) {
                await scope.discovery.ensureLoaded();
              }
            },
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: const Text('更新源地址'),
            subtitle: Text(
              scope.settings.updateUrls.isEmpty
                  ? '默认（GitHub Releases 清单）'
                  : scope.settings.updateUrls,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => _editUpdateUrls(context, scope),
          ),
          ListenableBuilder(
            listenable: UpdateService.instance,
            builder: (context, _) {
              final u = UpdateService.instance;
              final source = (u.sourceLabel != null && u.sourceLabel != '官方')
                  ? '（${u.sourceLabel}）'
                  : '';
              final subtitle = u.checking
                  ? '正在检查…'
                  : u.hasUpdate
                      ? '发现新版本 v${u.latestVersion}$source，点按前往下载'
                      : (u.error == null
                          ? '当前已是最新$source'
                          : '检查失败，请稍后再试');
              return ListTile(
                leading: const Icon(Icons.system_update_outlined),
                title: const Text('检查更新'),
                subtitle: Text(subtitle),
                onTap: u.checking
                    ? null
                    : () async {
                        await u.checkManually();
                        if (!context.mounted) return;
                        if (u.hasUpdate) {
                          await updateInteractive(context);
                        }
                      },
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重置匿名设备'),
            subtitle: const Text('遇到访问受限时使用'),
            // 与错误面板「立即重置」共用一条路径与文案（resetAnonymousDevice）。
            onTap: () => resetAnonymousDevice(context, scope.api.resetDevice),
          ),
        ],
      ),
    );
  }

  /// 更新清单地址：多个地址用英文逗号分隔，依次尝试；清空恢复内置默认。
  static Future<void> _editUpdateUrls(
      BuildContext context, AppScope scope) async {
    final controller = TextEditingController(text: scope.settings.updateUrls);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('更新源地址'),
        content: TextField(
          controller: controller,
          minLines: 3,
          maxLines: 6,
          decoration: const InputDecoration(
            hintText: 'https://…/update.json,https://…/update.json',
            helperText: '英文逗号分隔，依次尝试；留空恢复内置默认清单',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final value = controller.text;
    controller.dispose();
    if (ok != true) return;
    scope.settings.updateUrls = value;
    UpdateService.instance.resetManifestCache();
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('更新源地址已保存')));
    }
  }

  static String _downloadDirLabel(AppScope scope) {
    final custom = scope.settings.downloadDir;
    final active = scope.downloads.baseDir.path;
    if (custom == null) return active;
    return _samePath(custom, active)
        ? active
        : '$custom（不可用，已用 $active）';
  }

  static bool _samePath(String a, String b) =>
      a.toLowerCase().replaceAll('\\', '/') ==
      b.toLowerCase().replaceAll('\\', '/');

  Future<void> _chooseDownloadDir(
      BuildContext context, AppScope scope) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final picked = await getDirectoryPath(confirmButtonText: '选择');
      if (picked == null) return;
      if (scope.downloads.hasActiveTasks) {
        messenger.showSnackBar(
            const SnackBar(content: Text('有下载任务正在进行，请完成后再切换目录')));
        return;
      }
      final target = Directory(picked);
      if (!await DownloadService.ensureWritable(target)) {
        messenger.showSnackBar(
            const SnackBar(content: Text('该目录不可写，请换一个位置')));
        return;
      }
      if (!context.mounted) return;
      final mode = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('切换下载位置'),
          content: Text('新位置：${target.path}\n\n'
              '「仅切换」：新下载写到新目录，已有缓存保留原位置（仍可播放）。\n'
              '「迁移已有缓存」：逐集复制并校验后删除原文件，失败的单集保留原位置。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'switch'),
                child: const Text('仅切换')),
            FilledButton(
                onPressed: () => Navigator.pop(context, 'migrate'),
                child: const Text('迁移已有缓存')),
          ],
        ),
      );
      if (mode == null) return;
      if (mode == 'migrate') {
        final result = await scope.downloads.migrateDownloadsTo(target);
        scope.settings.downloadDir = target.path;
        messenger.showSnackBar(SnackBar(
          content: Text(result.failed > 0
              ? '已迁移 ${result.moved} 集，${result.failed} 集失败（保留原位置）'
              : '已迁移 ${result.moved} 集到新目录'),
        ));
      } else {
        await scope.downloads.setBaseDir(target);
        scope.settings.downloadDir = target.path;
        messenger.showSnackBar(
            const SnackBar(content: Text('已切换下载位置，旧缓存保留在原目录')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('切换失败：$e')));
    }
  }

  static Widget _selectTile<T>(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    required T value,
    required Map<T, String> items,
    required void Function(T)? onChanged,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: PopupMenuButton<T>(
        enabled: onChanged != null,
        initialValue: value,
        onSelected: onChanged,
        itemBuilder: (_) => [
          for (final e in items.entries)
            PopupMenuItem(value: e.key, child: Text(e.value)),
        ],
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(items[value] ?? '$value'),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }
}

/// 设置 → 听书：自建朗读开关、合成引擎/音色/代理，以及高亮粒度/样式/颜色。
///
/// 键的分工刻意跟着「谁读它」走：`listen.tts.*` 走 [ReaderListenSettings]，显示三件
/// 套继续走 `ReaderSpeechSettings`（渲染层每帧现取的就是它），设置页不另开第二套入口。
/// `listen.tts.proxy` 是**敏感项**：只写本机 prefs，`SettingsStore.exportBackup()` 的
/// 字面量名单里没有它，导出备份不会带上（与 `voice.apiKey` 同一处理方式）。
class ListenSettingsGroup extends StatefulWidget {
  const ListenSettingsGroup({super.key});

  @override
  State<ListenSettingsGroup> createState() => _ListenSettingsGroupState();
}

class _ListenSettingsGroupState extends State<ListenSettingsGroup> {
  SharedPreferences? _prefs;

  /// 音色 id → 显示名。列表**懒加载**：没拿到就只显示已存值，绝不挡住设置页打开。
  Map<String, String> _voices = const <String, String>{};
  bool _voiceFailed = false;

  /// 通知权限状态（null = 还没查；非 Android 不动通道）。
  bool? _notifGranted;

  /// 本机是否装了 Windows 语音引擎（null = 还没探；非 Windows 不探）。
  bool? _winVoiceAvailable;

  Future<void> _loadNotificationPermission() async {
    final granted = await NotificationPermission.has();
    if (!mounted) return;
    setState(() => _notifGranted = granted);
  }

  /// 调试台正在体检：防重复点击（一次会真发合成请求）。
  bool _probing = false;

  /// 背景音量拖动中的草稿值（松手才落盘，避免每帧写 prefs）。
  int? _bgmVolumeDraft;
  bool _voicesRequested = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (mounted) setState(() => _prefs = prefs);
    });
    // 通知权限状态：只查不申请（要在用户开听书时才弹系统框）。
    // ignore: discarded_futures
    _loadNotificationPermission();
    // Windows 离线语音可用性：只探一次，结果只用于设置项的文案（不阻塞页面）。
    if (Platform.isWindows) {
      // ignore: discarded_futures
      WindowsSpeechEngine().isAvailable().then((available) {
        if (mounted) setState(() => _winVoiceAvailable = available);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_voicesRequested) return;
    _voicesRequested = true;
    _loadVoices();
  }

  Future<void> _loadVoices() async {
    final scope = AppScope.read(context);
    try {
      final list = await scope.speech.listTtsVoices();
      if (!mounted) return;
      setState(() {
        _voices = <String, String>{for (final v in list) v.id: v.displayName};
        _voiceFailed = false;
      });
    } catch (_) {
      // 合成音色要联网才能列出来。失败就退化成「只有引擎默认 + 已存值」，
      // 已存值照样回显（下面的 items 里补了它），设置页其余项目照常可用。
      if (!mounted) return;
      setState(() => _voiceFailed = true);
    }
  }

  /// 写对话音色偏好：**按槽位存**（位置有意义），空槽用空串占位；
  /// 末尾的空槽去掉，避免存出 `['a','']` 这种噪声。
  Future<void> _saveRoleVoice(
    ReaderListenSettings tts, {
    required int slot,
    required String value,
  }) async {
    final next = List<String>.from(tts.roleVoices);
    while (next.length < 2) {
      next.add('');
    }
    next[slot] = value;
    while (next.isNotEmpty && next.last.isEmpty) {
      next.removeLast();
    }
    await tts.setRoleVoices(next);
    if (!mounted) return;
    setState(() {});
  }

  /// Piper 离线：两个路径（可执行文件 + 模型）。
  ///
  /// 保存前不校验可执行性（没法跨平台验），**路径写错的代价是回退 Edge**，
  /// 不会让书听不了 —— 所以这里不做阻塞式校验。
  Future<void> _showPiperDialog(ReaderListenSettings tts) async {
    final exeController = TextEditingController(text: tts.piperExe);
    final modelController = TextEditingController(text: tts.piperModel);
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Piper 离线合成'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: exeController,
                decoration: const InputDecoration(
                  labelText: 'piper 可执行文件',
                  hintText: r'C:\piper\piper.exe（或 PATH 里的 piper）',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: modelController,
                decoration: const InputDecoration(
                  labelText: '模型文件（.onnx）',
                  hintText: r'C:\piper\zh_CN-huayan-medium.onnx',
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text(
                  'Piper 不提供词/句边界，朗读高亮只能到「段」（会如实显示）。'
                  '路径填错会自动回退 Edge，不影响其它设置。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved != true) return;
    await tts.setPiperExe(exeController.text);
    await tts.setPiperModel(modelController.text);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      const SnackBar(content: Text('Piper 配置已保存（只存本机）')),
    );
  }

  /// 选本地音频当背景音乐。取消选择不改动已存的路径。
  Future<void> _pickBgm(ReaderListenSettings tts) async {
    try {
      final picked = await openFile(
        acceptedTypeGroups: const <XTypeGroup>[
          XTypeGroup(
            label: '音频',
            extensions: <String>[
              'mp3',
              'm4a',
              'aac',
              'flac',
              'wav',
              'ogg',
            ],
          ),
        ],
      );
      if (picked == null) return;
      await tts.setBgmFile(picked.path);
      if (mounted) setState(() {});
    } catch (_) {
      // 平台不支持文件选择器时静默：不影响其它听书设置。
    }
  }

  /// 恢复听书默认设置：`listen.*` 全清（含代理与源配置里的 key）。
  ///
  /// 阅读/听书**进度**不在 `listen.*` 里（另两张表），所以不会让用户丢进度 ——
  /// 确认框要把这点说清楚，否则用户会以为要从头听。
  Future<void> _resetListenSettings(SharedPreferences prefs) async {
    final messenger = ScaffoldMessenger.of(context);
    final controller = AppScope.read(context).speech;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('恢复听书默认设置？'),
        content: const Text(
          '会清空音色、语速、定时、高亮、多角色、合成引擎与已填的 key / 代理。'
          '\n\n阅读进度与听书进度不受影响。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removed = await ReaderListenSettings(prefs).resetAll();
    // 控制器手里还有设置快照与旧引擎：必须重读 + 重建，
    // 否则界面回到默认而播放还在用旧源。
    await controller.reloadSettings();
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          removed == 0 ? '本来就是默认设置' : '已清除 $removed 项听书偏好',
        ),
      ),
    );
  }

  Map<String, String> _voiceItems(String saved) {
    final items = <String, String>{'': '引擎默认'};
    items.addAll(_voices);
    if (saved.isNotEmpty) items.putIfAbsent(saved, () => saved);
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    if (prefs == null) {
      return const ListTile(
        leading: Icon(Icons.record_voice_over_outlined),
        title: Text('听书'),
        subtitle: Text('正在读取本机设置…'),
      );
    }
    final tts = ReaderListenSettings(prefs);
    final display = ReaderSpeechSettings(prefs);
    // 多源列表：选择 / 编辑当前 / 删除 / 测试，都是同一份 store。
    final sources = TtsSourceStore(prefs);
    final sourceList = sources.list();
    final activeSource = sources.active;
    // 多角色的两个对话音色偏好（槽位 0/1，空串 = 自动）。
    final roleVoices = tts.roleVoices;
    // 章间间隔：老数据可能是任意毫秒值，不在档位表里也要能显示出来。
    final gapValue = tts.chapterGapMs;
    String gapLabel(int ms) =>
        ms <= 0 ? '关闭（硬切）' : '${(ms / 1000).toStringAsFixed(1)} 秒';
    final gapItems = <int, String>{
      for (final ms in kChapterGapOptions) ms: gapLabel(ms),
      if (!kChapterGapOptions.contains(gapValue)) gapValue: gapLabel(gapValue),
    };
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.record_voice_over_outlined),
          title: const Text('听书自建朗读'),
          subtitle: const Text('没有真人音轨的章节改用合成朗读，并可逐词高亮'),
          trailing: Switch(
            value: tts.ttsEnabled,
            onChanged: (v) async {
              await tts.setTtsEnabled(v);
              if (v) {
                // 开了合成朗读就顺手要通知权限：否则后台播了也没法从通知暂停。
                // 拒绝也不报错——只影响通知显示。
                await NotificationPermission.ensure();
                await _loadNotificationPermission();
              }
              if (mounted) setState(() {});
            },
          ),
        ),
        if (Platform.isAndroid)
          ListTile(
            leading: const Icon(Icons.notifications_active_outlined),
            title: const Text('通知权限'),
            subtitle: Text(
              _notifGranted == null
                  ? '检测中…'
                  : (_notifGranted!
                        ? '已授予 · 锁屏与通知栏可以控制播放'
                        : '未授予 · 后台通知与锁屏控制不会显示'),
            ),
            trailing: _notifGranted == true
                ? const Icon(Icons.check, size: 18)
                : const Icon(Icons.chevron_right),
            onTap: () async {
              // 先取 messenger 再 await：避免跨 async gap 用 BuildContext。
              final messenger = ScaffoldMessenger.of(context);
              final granted = await NotificationPermission.ensure();
              if (!mounted) return;
              setState(() => _notifGranted = granted);
              messenger.showSnackBar(
                SnackBar(
                  content: Text(
                    granted
                        ? '通知权限已授予'
                        : '未授予：听书仍可播放，但后台通知/锁屏控制不显示',
                  ),
                ),
              );
            },
          ),
        SettingsPanel._selectTile<String>(
          context,
          icon: Icons.memory,
          title: '合成引擎',
          value: tts.ttsEngineId,
          items: <String, String>{
            kDefaultTtsEngineId: 'Edge 神经网络',
            if (Platform.isWindows)
              kWindowsSpeechEngineId: _winVoiceAvailable == false
                  ? '本机离线语音（未装语音）'
                  : '本机离线语音（Windows）',
            kHttpTtsEngineId: 'HTTP TTS 源',
            kPiperEngineId: 'Piper 离线（自备模型）',
          },
          onChanged: (v) => tts.setTtsEngineId(v),
        ),
        if (tts.ttsEngineId == kPiperEngineId)
          ListTile(
            leading: const Icon(Icons.offline_bolt_outlined),
            title: const Text('Piper 离线配置'),
            subtitle: Text(
              tts.piperExe.isEmpty || tts.piperModel.isEmpty
                  ? '未配置（此时回退到 Edge）'
                  : '已配置 · 只能段级高亮（Piper 不提供句/词边界）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showPiperDialog(tts),
          ),
        if (tts.ttsEngineId == kHttpTtsEngineId && sourceList.isNotEmpty)
          SettingsPanel._selectTile<String>(
            context,
            icon: Icons.cloud_queue_outlined,
            title: 'HTTP TTS 源',
            subtitle: activeSource == null
                ? '未配置（此时回退 Edge）'
                : '当前：${activeSource.name} · 只存本机，不进备份',
            value: activeSource?.id ?? '',
            items: <String, String>{
              for (final s in sourceList) s.id: s.name,
            },
            onChanged: (id) => sources.select(id),
          ),
        if (tts.ttsEngineId == kHttpTtsEngineId)
          ListTile(
            leading: const Icon(
              Icons.add_link,
            ),
            title: Text(activeSource == null ? '新增源' : '编辑当前源'),
            subtitle: Text(
              activeSource == null
                  ? '粘贴一段 JSON 即接上一个语音接口'
                  : '修改后按新的 id 决定缓存是否重建（改配置请换 id）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showHttpSourceDialog(sources),
          ),
        if (tts.ttsEngineId == kHttpTtsEngineId && activeSource != null)
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('删除当前源'),
            subtitle: Text('删除「${activeSource.name}」'),
            onTap: () => _deleteHttpSource(sources, activeSource),
          ),
        if (tts.ttsEngineId == kHttpTtsEngineId)
          ListTile(
            leading: const Icon(Icons.network_check),
            title: const Text('测试 HTTP 源'),
            subtitle: const Text('发一次真实的合成请求，看状态码/耗时/字节/时长'),
            trailing: _probing
                ? const AppLoading.inline()
                : const Icon(Icons.play_arrow_outlined),
            onTap: _probing ? null : () => _runHttpProbe(sources, tts),
          ),
        SettingsPanel._selectTile<String>(
          context,
          icon: Icons.people_alt_outlined,
          title: '朗读音色',
          subtitle: _voiceFailed
              ? '音色列表暂时读不到，仍显示已存值'
              : (_voices.isEmpty ? '音色列表加载中' : null),
          value: tts.ttsVoiceId,
          items: _voiceItems(tts.ttsVoiceId),
          onChanged: (v) async {
            // 先快照控制器：await 后不得再摸 context。
            final speech = AppScope.read(context).speech;
            await tts.setTtsVoiceId(v);
            // 朗读进行中热切换：从当前段继续，不再等下次重开才生效。
            try {
              await speech.setTtsVoice(v);
            } catch (_) {}
            if (mounted) setState(() {});
          },
        ),
        // 静音裁剪：逐段合成自带的首尾空白，按帧边界裁掉（时间点同步平移）。
        // 开关状态会进缓存键，切换后首次播放会重合成一次。
        ListTile(
          leading: const Icon(Icons.content_cut),
          title: const Text('静音裁剪'),
          subtitle: Text(
            tts.trimSilenceEnabled
                ? '裁掉每段首尾多余空白，连播更紧凑（关掉可对比原始效果）'
                : '关闭：保留合成原始空白',
          ),
          trailing: Switch(
            value: tts.trimSilenceEnabled,
            onChanged: (v) async {
              await tts.setTrimSilenceEnabled(v);
              if (mounted) setState(() {});
            },
          ),
        ),
        // 流式朗读：按单元合成，第一段好就开播（首播延迟从整章几十秒降到几秒）。
        // 关掉即回到整章合成；切换对**下一次开章**生效，不打断正在播的这一章。
        ListTile(
          leading: const Icon(Icons.bolt_outlined),
          title: const Text('流式朗读（首段即播）'),
          subtitle: Text(
            tts.streamingTtsEnabled
                ? '按段合成、第一段就开播；切段/跳段照常可用（下次开章生效）'
                : '关闭：整章合成完才开播（首播等待较长，作为回滚开关保留）',
          ),
          trailing: Switch(
            value: tts.streamingTtsEnabled,
            onChanged: (v) async {
              await tts.setStreamingTtsEnabled(v);
              if (mounted) setState(() {});
            },
          ),
        ),
        // 章间间隔：自动连播切章前的呼吸（播放器侧等待，不碰时间轴）。
        SettingsPanel._selectTile<int>(
          context,
          icon: Icons.more_time,
          title: '章节间隔',
          subtitle: '自动连播时两章之间停一下（手动切章不受影响）',
          value: gapValue,
          items: gapItems,
          onChanged: (v) async {
            await tts.setChapterGapMs(v);
            if (mounted) setState(() {});
          },
        ),
        // 定时淡出：到点渐弱再暂停，避免睡眠场景下被硬切惊醒。
        ListTile(
          leading: const Icon(Icons.volume_down_alt),
          title: const Text('定时淡出'),
          subtitle: Text(
            tts.sleepFadeOutEnabled
                ? '定时到点时音量渐弱再暂停（约 3 秒）'
                : '关闭：定时到点立即暂停',
          ),
          trailing: Switch(
            value: tts.sleepFadeOutEnabled,
            onChanged: (v) async {
              await tts.setSleepFadeOutEnabled(v);
              if (mounted) setState(() {});
            },
          ),
        ),
        // 多角色：用引号栈规则把旁白/对话分开用不同音色（不接模型）。
        // 默认关：它会把一章拆成多次合成请求（耗时与限流都会增加），
        // 交给用户自己决定；音色不够时自动退化为单角色。
        ListTile(
          leading: const Icon(Icons.record_voice_over_outlined),
          title: const Text('多角色朗读'),
          subtitle: Text(
            tts.rolesEnabled
                ? '旁白与对白使用不同音色（对话按轮次交替）'
                : '关闭时全章用同一音色',
          ),
          trailing: Switch(
            value: tts.rolesEnabled,
            onChanged: (v) async {
              await tts.setRolesEnabled(v);
              if (mounted) setState(() {});
            },
          ),
        ),
        // 两个对话音色：A 是主对话，B 是轮次交替时的第二个声音。
        // 都不填就交给引擎自动挑不同音色（音色不够时自动退化为单角色）。
        if (tts.rolesEnabled) ...[
          SettingsPanel._selectTile<String>(
            context,
            icon: Icons.record_voice_over_outlined,
            title: '对话音色',
            subtitle: '旁白之外的主音色（空 = 自动挑一个）',
            value: roleVoices.isNotEmpty ? roleVoices[0] : '',
            items: _voiceItems(roleVoices.isNotEmpty ? roleVoices[0] : ''),
            onChanged: (v) => _saveRoleVoice(tts, slot: 0, value: v),
          ),
          SettingsPanel._selectTile<String>(
            context,
            icon: Icons.group_outlined,
            title: '第二对话音色',
            subtitle: '两轮对话交替时使用（空 = 自动挑一个）',
            value: roleVoices.length > 1 ? roleVoices[1] : '',
            items: _voiceItems(roleVoices.length > 1 ? roleVoices[1] : ''),
            onChanged: (v) => _saveRoleVoice(tts, slot: 1, value: v),
          ),
        ],
        ListTile(
          leading: const Icon(Icons.lan_outlined),
          title: const Text('合成代理'),
          subtitle: Text(
            tts.ttsProxy.isEmpty
                ? '未配置（直连）· 只存本机，不进备份'
                : '${tts.ttsProxy} · 只存本机，不进备份',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _showProxySettings(tts),
        ),
        SettingsPanel._selectTile<String>(
          context,
          icon: Icons.text_format,
          title: '高亮粒度',
          subtitle: '词级更跟手，句级更安静',
          value: display.granularity.name,
          items: <String, String>{
            for (final g in SpeechHighlightGranularity.values) g.name: g.label,
          },
          onChanged: (v) =>
              display.setGranularity(SpeechHighlightGranularity.parse(v)),
        ),
        SettingsPanel._selectTile<String>(
          context,
          icon: Icons.brush,
          title: '高亮样式',
          value: display.style.name,
          items: <String, String>{
            for (final s in SpeechHighlightStyle.values) s.name: s.label,
          },
          onChanged: (v) => display.setStyle(SpeechHighlightStyle.parse(v)),
        ),
        SettingsPanel._selectTile<int>(
          context,
          icon: Icons.palette_outlined,
          title: '高亮颜色',
          value: display.colorArgb,
          items: kSpeechColorPresets,
          onChanged: (v) => display.setColorArgb(v),
        ),
        const Divider(height: 24),
        // 背景音乐：独立低音量循环播放器，跟随朗读起停（未配置时完全不启动）。
        ListTile(
          leading: const Icon(Icons.music_note_outlined),
          title: const Text('背景音乐'),
          subtitle: Text(
            tts.bgmFile.isEmpty ? '未选择（选本地音频，边听边放）' : tts.bgmFile,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: tts.bgmFile.isEmpty
              ? const Icon(Icons.folder_open)
              : IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: '清除背景音乐',
                  onPressed: () async {
                    await tts.setBgmFile('');
                    if (mounted) setState(() {});
                  },
                ),
          onTap: () => _pickBgm(tts),
        ),
        if (tts.bgmFile.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                const Icon(Icons.volume_down_alt, size: 20),
                const SizedBox(width: 8),
                const Text('背景音量'),
                Expanded(
                  child: Slider(
                    value: (_bgmVolumeDraft ?? tts.bgmVolume).toDouble(),
                    max: 100,
                    divisions: 20,
                    label: '${_bgmVolumeDraft ?? tts.bgmVolume}%',
                    onChanged: (v) =>
                        setState(() => _bgmVolumeDraft = v.round()),
                    onChangeEnd: (v) async {
                      await tts.setBgmVolume(v.round());
                      if (mounted) setState(() => _bgmVolumeDraft = null);
                    },
                  ),
                ),
                Text('${_bgmVolumeDraft ?? tts.bgmVolume}%'),
              ],
            ),
          ),
        const Divider(height: 24),
        // 听书统计：本地计数（墙钟），不联网。只显示已落盘部分。
        Builder(
          builder: (context) {
            final stats = ListenStats(prefs);
            return ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('听书时长'),
              subtitle: Text(
                '今日 ${listenDurationLabel(stats.todayMs)} · '
                '近 7 天 ${listenDurationLabel(stats.last7DaysMs)}',
              ),
            );
          },
        ),
        const Divider(height: 24),
        // 恢复默认：`listen.*` 散在七八处（音色/语速/定时/高亮/合成源/代理），
        // 用户调乱了没有复位入口，只能逐项改回去。
        ListTile(
          leading: const Icon(Icons.settings_backup_restore),
          title: const Text('恢复听书默认设置'),
          subtitle: const Text('清空音色 / 语速 / 定时 / 高亮 / 合成源等全部听书偏好'),
          onTap: () => _resetListenSettings(prefs),
        ),
      ],
    );
  }

  Future<void> _showProxySettings(ReaderListenSettings tts) async {
    final controller = TextEditingController(text: tts.ttsProxy);
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('合成代理'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '代理地址（留空 = 直连）',
                  hintText: 'http://127.0.0.1:10809',
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '代理地址可能带凭据，因此只写本机：备份白名单里没有它，'
                  '导出备份不会带上。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (saved == null) return;
    await tts.setTtsProxy(saved);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
        const SnackBar(content: Text('合成代理已更新（只存本机，不进备份）')));
  }

  /// 调试台：发一次真实请求，把状态码/耗时/字节/时长/服务端原话展示出来。
  /// 只用**已保存**的配置体检（避免“测的是草稿、播的是旧配置”）。
  Future<void> _runHttpProbe(
    TtsSourceStore sources,
    ReaderListenSettings tts,
  ) async {
    final source = sources.active;
    final messenger = ScaffoldMessenger.of(context);
    if (source == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('先保存一份合法的源配置再测试')),
      );
      return;
    }
    setState(() => _probing = true);
    final result = await HttpTtsProbe.run(source, voice: tts.ttsVoiceId);
    if (!mounted) return;
    setState(() => _probing = false);

    final lines = <String>[
      result.headline,
      '耗时 ${result.elapsedMs} ms',
      if (result.sentenceCount != null) '句数 ${result.sentenceCount}',
      if (result.requestLines.isNotEmpty)
        '请求：${result.requestLines.join('；')}',
      if (result.message.isNotEmpty) '详情：${result.message}',
      if (result.snippet.isNotEmpty) '响应：${result.snippet}',
    ];
    // 试听复用**现有播放链路**（临时文件 → media_kit），听到的就是正式播放听到的。
    final preview = TtsPreviewPlayer(
      onError: (m) =>
          messenger.showSnackBar(SnackBar(content: Text('试听失败：$m'))),
    );
    try {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(result.ok ? '源可用' : '源不可用'),
          content: SizedBox(
            width: 520,
            child: SelectableText(
              lines.join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          actions: [
            if (result.audio != null)
              TextButton(
                onPressed: () => preview.play(result.audio!),
                child: const Text('试听'),
              ),
            if (result.audio != null)
              TextButton(
                onPressed: () => preview.stop(),
                child: const Text('停止'),
              ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
    } finally {
      // 关弹窗即停并删临时文件（不留垃圾、不占声道）。
      await preview.dispose();
    }
  }

  /// 新增/编辑源：编辑时预填当前选中的那份，保存走 store.upsert。
  Future<void> _showHttpSourceDialog(TtsSourceStore sources) async {
    final active = sources.active;
    final controller = TextEditingController(
      text: active == null
          ? ''
          : const JsonEncoder.withIndent('  ').convert(active.toJson()),
    );
    final messenger = ScaffoldMessenger.of(context);
    final saved = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        // 选过的预设提示：告诉用户还要改哪几个字段（key/区域/url）。
        var presetHint = '';
        return StatefulBuilder(
          builder: (dialogContext, setState) => AlertDialog(
            title: const Text('HTTP TTS 源'),
            content: SizedBox(
              width: 520,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 预设：一键填入模板，再改 key。不内置引擎，只内置模板。
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final preset in kTtsSourcePresets)
                          ActionChip(
                            label: Text(
                              preset.name,
                              style: const TextStyle(fontSize: 12),
                            ),
                            onPressed: () {
                              controller.text = preset.json;
                              setState(() => presetHint = preset.hint);
                            },
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    minLines: 6,
                    maxLines: 12,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                    decoration: const InputDecoration(
                      labelText: '源配置 JSON',
                      hintText:
                          '{"id":"local","url":"http://127.0.0.1:9880/tts?text={text}&voice={voice}",'
                          '"voices":["zh-A"]}',
                    ),
                  ),
                  if (presetHint.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        '需要改：$presetHint',
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(dialogContext).colorScheme.primary,
                        ),
                      ),
                    ),
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '占位符：{text} 与 {voice}（URL 里自动编码；body 里按 bodyEscape 转义：'
                      'json 默认 / xml 用于 SSML）。mode 可选 audio / jsonUrl / jsonBase64；'
                      '仅支持返回 mp3 的接口。配置可能带 header 密钥，因此只存本机、不进备份。',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
        );
      },
    );
    if (saved == null) return;
    final parsed = HttpTtsSource.tryParse(saved);
    if (saved.isNotEmpty && parsed == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('配置不合法：需要 id，且 {text} 要出现在 url 或 body 里')),
      );
      return;
    }
    if (parsed != null) await sources.upsert(parsed);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(
      SnackBar(
        content: Text(parsed == null ? '未保存（空白配置）' : '已保存「${parsed.name}」'),
      ),
    );
  }

  /// 删除当前源：二次确认（删错了要重贴整段 JSON）。
  Future<void> _deleteHttpSource(
    TtsSourceStore sources,
    HttpTtsSource source,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除源'),
        content: Text('确定删除「${source.name}」？删除后需要重新粘贴配置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await sources.remove(source.id);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(content: Text('已删除「${source.name}」')));
  }
}

/// 关于面板：版本、核心版本、免责声明入口。
class AboutPanel extends StatefulWidget {
  const AboutPanel({super.key});

  @override
  State<AboutPanel> createState() => _AboutPanelState();
}

class _AboutPanelState extends State<AboutPanel> {
  String _version = '';
  String _core = '';
  String _build = '';
  String _logPath = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    String core = '';
    try {
      core = AquaClient.coreVersion();
    } catch (_) {}
    final logPath = await ErrorLog.instance.resolveLogFilePath();
    if (mounted) {
      setState(() {
        _version = '${info.version}+${info.buildNumber}';
        _core = core;
        // 构建标识：用来确认用户跑的是不是最新包。
        _build = const String.fromEnvironment('AQUAN_BUILD',
            defaultValue: 'dev');
        _logPath = logPath;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.local_movies_outlined),
          title: const Text('阿圈短剧'),
          subtitle: Text('版本 $_version · 核心 $_core · 构建 $_build'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.description_outlined),
          title: const Text('数据来源与免责声明'),
          subtitle: const Text('本应用基于开源项目 openhongguo，仅供学习'),
          onTap: () => showAboutDialog(
            context: context,
            applicationName: '阿圈短剧',
            applicationVersion: _version,
            children: [
              Text(
                '阿圈短剧的数据来自开源项目 openhongguo（Apache License 2.0）逆向的'
                '红果短剧公开接口，所有内容版权归原平台与权利方所有。\n\n'
                '本项目仅供学习与研究，禁止用于商业用途；请勿用于任何侵犯他人合法权益'
                '的用途。使用本应用即表示您同意上述条款。\n\n'
                '主题色 ${AppTheme.seed}。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
        ListenableBuilder(
          listenable: ErrorLog.instance,
          builder: (context, _) => ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.bug_report_outlined),
            title: const Text('错误日志'),
            subtitle: Text(ErrorLog.instance.isEmpty
                ? '本次运行没有错误'
                : '本次运行 ${ErrorLog.instance.length} 条，点按查看 / 复制'),
            onTap: () => _showErrorLog(context),
          ),
        ),
        if (_logPath.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText('日志文件：$_logPath',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton.icon(
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(context);
                        await Clipboard.setData(ClipboardData(text: _logPath));
                        messenger.showSnackBar(
                            const SnackBar(content: Text('日志路径已复制')));
                      },
                      icon: const Icon(Icons.copy_rounded, size: 18),
                      label: const Text('复制路径'),
                    ),
                    if (Platform.isWindows ||
                        Platform.isLinux ||
                        Platform.isMacOS)
                      TextButton.icon(
                        onPressed: _openLogFolder,
                        icon: const Icon(Icons.folder_open, size: 18),
                        label: const Text('打开所在文件夹'),
                      ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// 在系统文件管理器里定位日志目录（Windows 高亮文件本体）。
  /// explorer 即使命中也返回非 0 退出码，故不判结果、只防抛异常。
  Future<void> _openLogFolder() async {
    if (_logPath.isEmpty) return;
    final file = File(_logPath);
    final dir = file.parent.path;
    try {
      if (Platform.isWindows) {
        await Process.run(
            'explorer', [file.existsSync() ? '/select,${file.path}' : dir]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [dir]);
      } else {
        await Process.run('xdg-open', [dir]);
      }
    } catch (e, s) {
      ErrorLog.instance.record('打开日志目录', e, s);
    }
  }

  Future<void> _showErrorLog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Text('错误日志'),
            const Spacer(),
            IconButton(
              tooltip: '复制全部',
              icon: const Icon(Icons.copy_rounded, size: 20),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: ErrorLog.instance.text));
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                      const SnackBar(content: Text('错误日志已复制')));
                }
              },
            ),
            IconButton(
              tooltip: '导出运行日志',
              icon: const Icon(Icons.save_alt, size: 20),
              onPressed: () async {
                // M4-2：一键导出 ErrorLog 全文快照（app_log_<时间戳>.txt）。
                final path = await ErrorLog.instance.exportToFile();
                if (!dialogContext.mounted) return;
                ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(
                  content: Text(path.isEmpty ? '导出失败' : '已导出运行日志：$path'),
                  duration: const Duration(seconds: 4),
                ));
              },
            ),
            IconButton(
              tooltip: '清空',
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: ErrorLog.instance.clear,
            ),
          ],
        ),
        content: Builder(
          builder: (context) {
            final media = MediaQuery.sizeOf(context);
            return SizedBox(
              width: (media.width - 120).clamp(240.0, 640.0),
              height: (media.height * 0.6).clamp(220.0, 480.0),
              child: ListenableBuilder(
                listenable: ErrorLog.instance,
                builder: (context, _) => ErrorLog.instance.isEmpty
                    ? const Center(child: Text('本次运行没有错误'))
                    : const _ErrorLogText(),
              ),
            );
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭')),
        ],
      ),
    );
  }
}

class _ErrorLogText extends StatelessWidget {
  const _ErrorLogText();

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: SelectableText(
        ErrorLog.instance.text,
        style: const TextStyle(fontSize: 12, height: 1.45),
      ),
    );
  }
}


/// 语音识别配置对话框：OpenAI 兼容端点（桌面用），支持端点自检。
Future<void> _showVoiceSettings(BuildContext context, AppScope scope) async {
  final baseController =
      TextEditingController(text: scope.settings.voiceBaseUrl ?? '');
  final keyController = TextEditingController(text: scope.settings.voiceApiKey ?? '');
  final modelController = TextEditingController(text: scope.settings.voiceModel ?? '');
  String? checkResult;
  bool checking = false;
  String? checkError;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('语音识别设置'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (Platform.isAndroid)
                const ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.android),
                  title: Text('Android 使用系统语音识别'),
                  subtitle: Text('无需配置；桌面端可配置 OpenAI 兼容端点'),
                ),
              TextField(
                controller: baseController,
                decoration: const InputDecoration(
                  labelText: '端点 base_url（OpenAI 兼容）',
                  hintText: 'https://api.groq.com/openai/v1',
                ),
              ),
              TextField(
                controller: keyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                ),
              ),
              TextField(
                controller: modelController,
                decoration: const InputDecoration(
                  labelText: '模型（留空用端点默认）',
                  hintText: 'whisper-large-v3-turbo',
                ),
              ),
              if (checkResult != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('自检通过 · ${checkResult}ms',
                      style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                ),
              if (checkError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(checkError!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: checking
                ? null
                : () async {
                    final base = baseController.text.trim();
                    final key = keyController.text.trim();
                    if (base.isEmpty || key.isEmpty) {
                      setDialogState(() => checkError = '先填 base_url 与 API Key');
                      return;
                    }
                    setDialogState(() {
                      checking = true;
                      checkError = null;
                      checkResult = null;
                    });
                    try {
                      final ms = await pingVoiceEndpoint(
                          baseUrl: base, apiKey: key, model: modelController.text.trim());
                      setDialogState(() {
                        checking = false;
                        checkResult = '$ms';
                      });
                    } on VoiceException catch (e) {
                      setDialogState(() {
                        checking = false;
                        checkError = e.friendlyText;
                      });
                    } catch (e) {
                      setDialogState(() {
                        checking = false;
                        checkError = '自检失败：$e';
                      });
                    }
                  },
            child: Text(checking ? '自检中…' : '端点自检'),
          ),
          FilledButton(
            onPressed: () {
              scope.settings.voiceBaseUrl = baseController.text.trim();
              scope.settings.voiceApiKey = keyController.text.trim();
              scope.settings.voiceModel = modelController.text.trim();
              Navigator.of(dialogContext).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    ),
  );
}

/// 备份与恢复：导出观看历史 / 追剧 / 搜索历史 / 片头片尾 / 设置。
///
/// 备份带版本、体积上限与逐项 SHA-256；导入时先校验，再合并，并在恢复前
/// 自动把当前数据快照到 `<数据目录>/backups/`（失败时尽力回滚）。
class BackupPanel extends StatelessWidget {
  const BackupPanel({super.key});

  Future<Map<String, Map<String, dynamic>>> _collect(AppScope scope) async => {
        'history': await scope.history.exportData(),
        'follows': await scope.follows.exportData(),
        'searches': await scope.searches.exportData(),
        'play_skip': await scope.playSkip.exportData(),
        'settings': scope.settings.exportBackup(),
        'sources': await scope.sources.exportData(),
        'source_health': await scope.sourceHealth.exportData(),
        'market_sites': await scope.marketSites.exportData(),
        'cast': await scope.cast.exportData(),
        'lives': await scope.lives.exportData(),
      };

  Future<void> _export(BuildContext context) async {
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final info = await PackageInfo.fromPlatform();
      final appVersion = '${info.version}+${info.buildNumber}';
      final files = await _collect(scope);
      final service = DataBackupService();
      if (Platform.isAndroid) {
        // Android 没有系统保存对话框：写临时文件走分享面板。
        final dir = await getTemporaryDirectory();
        final file = File(
            '${dir.path}${Platform.pathSeparator}aquan_backup_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json');
        await service.exportTo(file.path, files, appVersion: appVersion);
        await SharePlus.instance.share(ShareParams(files: [XFile(file.path)]));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: 'aquan_backup.json',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (location == null) return;
      await service.exportTo(location.path, files, appVersion: appVersion);
      messenger.showSnackBar(
          SnackBar(content: Text('已导出到 ${location.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    }
  }

  Future<void> _import(BuildContext context) async {
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'JSON', extensions: ['json'])
        ],
      );
      if (file == null) return;
      final service = DataBackupService();
      final backup = await service.readFile(file.path);
      if (!context.mounted) return;
      final labels = backup.files.keys.map(_labelOf).join('、');
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('恢复数据备份？'),
          content: Text(
            '将恢复：$labels\n\n'
            '历史 / 追剧按较新记录合并；搜索历史追加去重；设置与片头片尾以备份为准。\n'
            '恢复前会自动备份当前数据。',
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('恢复')),
          ],
        ),
      );
      if (ok != true) return;
      final current = await _collect(scope);
      final result = await service.restore(
        backup,
        currentFiles: current,
        apply: (name, data) async {
          switch (name) {
            case 'history':
              await scope.history.importData(data);
            case 'follows':
              await scope.follows.importData(data);
            case 'searches':
              await scope.searches.importData(data);
            case 'play_skip':
              await scope.playSkip.importData(data);
            case 'settings':
              scope.settings.importBackup(data);
              scope.downloads.concurrency = scope.settings.downloadConcurrency;
              scope.downloads.maxRetries = scope.settings.downloadRetries;
              await scope.history.applyLimit(scope.settings.historyLimit);
            case 'sources':
              await scope.sources.importData(data);
            case 'source_health':
              await scope.sourceHealth.importData(data);
            case 'market_sites':
              await scope.marketSites.importData(data);
            case 'cast':
              await scope.cast.importData(data);
            case 'lives':
              await scope.lives.importData(data);
          }
        },
      );
      messenger.showSnackBar(SnackBar(
        content: Text('恢复完成：${result.restored.length} 项'
            '${result.preRestorePath == null ? '' : '，恢复前备份已保存'}'),
      ));
    } on DataBackupException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  static String _labelOf(String name) => switch (name) {
        'history' => '观看历史',
        'follows' => '追剧',
        'searches' => '搜索历史',
        'play_skip' => '片头片尾',
        'settings' => '设置',
        'sources' => '影视源',
        'source_health' => '源健康数据',
        'market_sites' => '源市场索引站',
        'cast' => '投屏设备记忆',
        'lives' => '直播配置',
        _ => name,
      };

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('导出备份'),
          subtitle: const Text('历史 / 追剧 / 搜索 / 片头片尾 / 设置，JSON 文件'),
          onTap: () => _export(context),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.file_download_outlined),
          title: const Text('导入恢复'),
          subtitle: const Text('校验后合并，恢复前自动备份当前数据'),
          onTap: () => _import(context),
        ),
      ],
    );
  }
}

/// 存储与缓存：盘点应用数据 / 离线缓存 / 孤儿临时文件，并支持一键清理。
class CachePanel extends StatefulWidget {
  const CachePanel({super.key});

  @override
  State<CachePanel> createState() => _CachePanelState();
}

class _CachePanelState extends State<CachePanel> {
  CacheInventory? _inventory;
  int _imageCacheEntries = 0;
  int _imageCacheBytes = 0;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final scope = AppScope.read(context);
    final inventory = await CacheMaintenance(
      downloadsDirectory: () async => scope.downloads.baseDir,
    ).inspect();
    try {
      _imageCacheEntries = await ImageCacheStore.instance.entryCount();
      _imageCacheBytes = await ImageCacheStore.instance.totalBytes();
    } catch (_) {}
    if (mounted) setState(() => _inventory = inventory);
  }

  Future<void> _clean(BuildContext context) async {
    if (_busy) return;
    final scope = AppScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final result = await CacheMaintenance(
        downloadsDirectory: () async => scope.downloads.baseDir,
      ).cleanOrphans();
      try {
        await DefaultCacheManager().emptyCache();
      } catch (_) {}
      try {
        // 封面/漫画页已迁到统一图片缓存仓，清缓存必须同步清它。
        await ImageCacheStore.instance.clear();
      } catch (_) {}
      await _refresh();
      messenger.showSnackBar(SnackBar(
        content: Text(result.deleted > 0
            ? '已清理 ${_fmtBytes(result.bytes)} 临时文件（${result.deleted} 个）'
            : '没有可清理的临时文件'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('清理失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openDataDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      if (Platform.isWindows) {
        await Process.start('explorer', [dir.path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isMacOS) {
        await Process.start('open', [dir.path],
            mode: ProcessStartMode.detached);
      } else if (Platform.isLinux) {
        await Process.start('xdg-open', [dir.path],
            mode: ProcessStartMode.detached);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final inv = _inventory;
    final subtitle = inv == null
        ? '正在统计…'
        : !inv.directoryReadable
            ? '数据目录不可读'
            : '应用数据 ${_fmtBytes(inv.userDataBytes)} · '
                '离线缓存 ${_fmtBytes(inv.downloadBytes)}'
                ' · 图片 $_imageCacheEntries 张 ${_fmtBytes(_imageCacheBytes)}'
                '${inv.orphanFiles > 0 ? ' · 可清理 ${_fmtBytes(inv.orphanBytes)}' : ''}';
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.cleaning_services_outlined),
          title: const Text('存储与缓存'),
          subtitle: Text(subtitle),
          trailing: _busy
              ? const AppLoading.inline()
              : TextButton(
                  onPressed: () => _clean(context),
                  child: const Text('清理'),
                ),
        ),
        if (!Platform.isAndroid)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('打开数据目录'),
            subtitle: const Text('备份文件与离线缓存都在这里'),
            onTap: _openDataDir,
          ),
      ],
    );
  }
}

String _fmtBytes(int bytes) {
  if (bytes >= 1 << 30) {
    return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
  }
  if (bytes >= 1 << 20) {
    return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1 << 10) {
    return '${(bytes / (1 << 10)).toStringAsFixed(0)} KB';
  }
  return '$bytes B';
}
