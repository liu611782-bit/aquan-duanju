import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../core/mp4_download_manager.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import 'downloads_screen.dart';
import 'history_screen.dart';
import 'mp4_downloads_screen.dart';

/// 我的页：观看历史、追剧、设置、关于。
class MineScreen extends StatefulWidget {
  const MineScreen({super.key});

  @override
  State<MineScreen> createState() => _MineScreenState();
}

class _MineScreenState extends State<MineScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

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
  Widget build(BuildContext context) {
    super.build(context);
    final scope = AppScope.read(context);
    final theme = Theme.of(context);

    final historyEntries = scope.history.entries.take(10).toList();
    final filteredFollows = _filteredFollows(scope.follows.entries);

    return Scaffold(
      appBar: AppBar(title: const Text('我的')),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.history, scope.follows, scope.reading]),
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _UpdateBanner(),
            _Section(
              title: '继续观看',
              action: historyEntries.isEmpty
                  ? null
                  : TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const HistoryScreen()),
                      ),
                      child: const Text('全部'),
                    ),
              child: historyEntries.isEmpty
                  ? const _EmptyHint('看过之后，这里会记录进度')
                  : Column(
                      children: [
                        for (final h in historyEntries)
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
                            title: Text(
                              h.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              h.finished
                                  ? '已看完'
                                  : '看到第${h.episode}集 ${_fmtPos(h.position)}',
                            ),
                            onTap: () => openDetail(context, h.seriesId, h.title),
                            trailing: IconButton(
                              icon: const Icon(Icons.close, size: 18),
                              onPressed: () => scope.history.remove(h.seriesId),
                            ),
                          ),
                      ],
                    ),
            ),
            _Section(
              title: '我的追剧',
              child: filteredFollows.isEmpty
                  ? const _EmptyHint('追剧之后，更新一目了然')
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final entry in _followFilters.entries)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: ChoiceChip(
                                    label: Text(entry.value),
                                    selected: _followFilter == entry.key,
                                    onSelected: (_) => setState(
                                      () => _followFilter = entry.key,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        for (final f in filteredFollows)
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
                                  child: Text(
                                    f.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                if (f.hasUpdate)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: theme.colorScheme.primary,
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text(
                                      '更新到${f.latestEpisodeCount}集',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: theme.colorScheme.onPrimary,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: Text(switch (f.state) {
                              FollowState.want => '想看',
                              FollowState.watching => '在看',
                              FollowState.watched => '已看',
                            }),
                            onTap: () => openDetail(context, f.seriesId, f.title),
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
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('我的下载'),
                    subtitle: const Text('在短剧详情页点「缓存」即可离线观看'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DownloadsScreen()),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_outlined),
                    title: const Text('MP4 导出目录'),
                    subtitle: Text(
                      scope.settings.mp4OutputDir.isEmpty
                          ? '默认（应用外部存储 mp4_downloads）'
                          : scope.settings.mp4OutputDir,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final picked =
                          await getDirectoryPath(confirmButtonText: '选择');
                      if (picked == null) return;
                      if (!await DownloadService.ensureWritable(Directory(picked))) {
                        if (!context.mounted) return;
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          const SnackBar(content: Text('该目录不可写，请选择其他目录')),
                        );
                        return;
                      }
                      scope.settings.mp4OutputDir = picked;
                      Mp4DownloadManager.instance.configure(customOutputDir: picked);
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
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('MP4 导出下载'),
                    subtitle: const Text('查看已导出的 MP4 文件列表'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const Mp4DownloadsScreen()),
                    ),
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
    final minutes = (seconds / 60).floor();
    if (minutes >= 1) return '约 $minutes 分钟';
    return '刚开头';
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
                Text(
                  title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                if (action != null) action!,
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
          child: Text(
            text,
            style: TextStyle(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      );
}

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
              leading: Icon(Icons.upgrade, color: Theme.of(context).colorScheme.primary),
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

class SettingsPanel extends StatelessWidget {
  const SettingsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.settings,
      builder: (context, _) => Column(
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.travel_explore),
            title: const Text('自动找源'),
            subtitle: Text(scope.settings.autoDiscovery ? '已开启' : '已关闭'),
            value: scope.settings.autoDiscovery,
            onChanged: (v) => scope.settings.autoDiscovery = v,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.playlist_play),
            title: const Text('自动连播'),
            value: scope.settings.autoNext,
            onChanged: (v) => scope.settings.autoNext = v,
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重置匿名设备'),
            subtitle: const Text('遇到访问受限时使用'),
            onTap: () => resetAnonymousDevice(context, scope.api.resetDevice),
          ),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: const Text('检查更新'),
            subtitle: const Text('手动检查新版本'),
            onTap: () async {
              final u = UpdateService.instance;
              await u.checkManually();
              if (!context.mounted) return;
              if (u.hasUpdate) {
                await updateInteractive(context);
              }
            },
          ),
        ],
      ),
    );
  }
}

class BackupPanel extends StatelessWidget {
  const BackupPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.backup_outlined),
      title: const Text('备份与恢复'),
      subtitle: const Text('在设置页中管理备份与恢复'),
      onTap: () {},
    );
  }
}

class CachePanel extends StatelessWidget {
  const CachePanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.cleaning_services_outlined),
      title: const Text('缓存清理'),
      subtitle: const Text('清理应用缓存与临时文件'),
      onTap: () {},
    );
  }
}

class AboutPanel extends StatelessWidget {
  const AboutPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.info_outline, color: theme.colorScheme.primary),
          title: const Text('阿圈短剧'),
          subtitle: const Text('面向短剧、书籍与漫画的聚合播放与下载工具。'),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('免责声明'),
          subtitle: const Text(
            '本应用仅提供聚合入口与播放能力，内容版权归原作者/平台所有。请遵守当地法律法规。',
          ),
        ),
      ],
    );
  }
}
