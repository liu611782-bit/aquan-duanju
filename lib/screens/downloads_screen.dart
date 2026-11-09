import 'dart:io';

import 'package:flutter/material.dart';

import '../core/cast/cast_controller.dart';
import '../core/download_service.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/cast_panel.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

/// 我的下载：已缓存剧集列表（封面/集数/体积），点开直接离线播放。
class DownloadsScreen extends StatelessWidget {
  /// 一键删除：取消所有排队/进行中/暂停的任务，并删除全部已缓存分集文件。
  Future<void> _deleteAll(BuildContext context) async {
    final downloads = AppScope.read(context).downloads;
    final list = List.of(downloads.store.seriesList);
    final activeSeriesIds = downloads.tasks.values
        .where((t) =>
            t.state == DownloadState.queued ||
            t.state == DownloadState.running ||
            t.state == DownloadState.paused)
        .map((t) => t.episode.seriesId)
        .toSet();
    if (list.isEmpty && activeSeriesIds.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('没有可删除的下载')));
      return;
    }
    final episodeCount =
        list.fold<int>(0, (sum, s) => sum + s.episodes.length);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除全部下载？'),
        content: Text('将取消 ${activeSeriesIds.length} 部剧的排队或进行中的下载，'
            '并删除 ${list.length} 部剧共 $episodeCount 个已缓存分集。此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('全部删除')),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final id in activeSeriesIds) {
      downloads.cancelSeries(id);
    }
    for (final s in list) {
      await downloads.deleteSeries(s.seriesId);
    }
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('已删除 ${list.length} 部剧的下载')));
  }

  /// 把本地缓存的某一集投到电视。
  /// 加密缓存经本机解密中继转成明文流投放（原画优先），不再推送密文。
  Future<void> _castLocal(BuildContext context, DownloadEntry entry) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (entry.filePath.isEmpty || !File(entry.filePath).existsSync()) {
      messenger?.showSnackBar(
        const SnackBar(content: Text('本地文件不存在，可能已被清理')),
      );
      return;
    }
    await showCastSheet(
      context,
      media: CastMedia(
        url: '',
        title: '${entry.seriesTitle} 第${entry.number}集',
        coverUrl: entry.coverUrl,
        localPath: entry.filePath,
        decKey: entry.keyHex,
        episodeIndex: entry.number,
      ),
      onLocalPause: () async {},
    );
  }

  const DownloadsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的下载'),
        actions: [
          IconButton(
            tooltip: '全部删除',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _deleteAll(context),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([scope.downloads, scope.downloads.store]),
        builder: (context, _) {
          final list = scope.downloads.store.seriesList;
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.download_outlined,
                      size: 56, color: theme.colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('还没有缓存的剧集',
                      style: TextStyle(color: theme.colorScheme.outline)),
                  const SizedBox(height: 8),
                  const Text('在短剧详情页点「缓存」即可离线观看',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              Text('共 ${list.length} 部 · ${_fmtBytes(scope.downloads.store.totalBytes)}',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              const SizedBox(height: 8),
              for (final s in list)
                Card(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: Theme(
                    data: theme.copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 44,
                          height: 60,
                          child: CoverImage(url: s.coverUrl),
                        ),
                      ),
                      title: Text(s.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                          '${s.episodes.length}集 · ${_fmtBytes(s.totalBytes)}'
                          '${_activeLabel(scope.downloads, s.seriesId)}'),
                      childrenPadding:
                          const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      children: [
                        if (scope.downloads.activeCount(s.seriesId) > 0 ||
                            scope.downloads.pausedCount(s.seriesId) > 0)
                          Wrap(
                            spacing: 4,
                            children: [
                              if (scope.downloads.activeCount(s.seriesId) > 0)
                                TextButton(
                                  onPressed: () => scope.downloads
                                      .pauseSeries(s.seriesId),
                                  child: const Text('全部暂停'),
                                ),
                              if (scope.downloads.pausedCount(s.seriesId) > 0)
                                TextButton(
                                  onPressed: () => scope.downloads
                                      .resumeSeries(s.seriesId),
                                  child: const Text('全部继续'),
                                ),
                            ],
                          ),
                        if (_failedCount(scope.downloads, s.seriesId) > 0)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.replay, size: 20),
                            title: Text(
                                '有 ${_failedCount(scope.downloads, s.seriesId)} 集下载失败'),
                            trailing: TextButton(
                              onPressed: () => scope.downloads
                                  .retryFailed(s.seriesId),
                              child: const Text('重试'),
                            ),
                          ),
                        for (final t
                            in _activeTasks(scope.downloads, s.seriesId))
                          ListTile(
                            dense: true,
                            leading: Icon(
                              t.state == DownloadState.paused
                                  ? Icons.pause_circle_outline
                                  : Icons.downloading,
                              size: 20,
                            ),
                            title: Text(
                                '第${t.episode.number}集 · ${_stateLabel(t.state)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: LinearProgressIndicator(
                                value: t.progress > 0 ? t.progress : null),
                            trailing: IconButton(
                              tooltip: t.state == DownloadState.paused
                                  ? '继续'
                                  : '暂停',
                              icon: Icon(
                                t.state == DownloadState.paused
                                    ? Icons.play_arrow
                                    : Icons.pause,
                                size: 20,
                              ),
                              onPressed: () {
                                if (t.state == DownloadState.paused) {
                                  scope.downloads
                                      .resumeEpisode(t.episode.id);
                                } else {
                                  scope.downloads.pauseEpisode(t.episode.id);
                                }
                              },
                            ),
                          ),
                        for (final e in s.episodes)
                          ListTile(
                            dense: true,
                            leading: SizedBox(
                              width: 34,
                              child: Text('${e.number}',
                                  textAlign: TextAlign.center,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(
                                          fontWeight: FontWeight.w600)),
                            ),
                            title: Text(
                                e.title.isEmpty ? '第${e.number}集' : e.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(_fmtBytes(e.sizeBytes)),
                            onTap: () => _playOffline(
                                context, scope.downloads, s,
                                startNumber: e.number),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: '投到电视',
                                  icon: const Icon(Icons.cast, size: 18),
                                  onPressed: () => _castLocal(context, e),
                                ),
                                IconButton(
                                  tooltip: '删除本集',
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18),
                                  onPressed: () => scope.downloads
                                      .deleteEpisode(e.episodeId),
                                ),
                              ],
                            ),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            TextButton.icon(
                              onPressed: () =>
                                  _fillMissing(context, scope, s),
                              icon: const Icon(Icons.refresh, size: 18),
                              label: const Text('补齐缺失'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () => _playOffline(
                                  context, scope.downloads, s),
                              icon: const Icon(Icons.play_arrow, size: 18),
                              label: const Text('继续观看'),
                            ),
                            const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: Text('删除《${s.title}》的缓存？'),
                                    content: Text(
                                        '将删除 ${s.episodes.length} 个已下载分集文件。'),
                                    actions: [
                                      TextButton(
                                          onPressed: () =>
                                              Navigator.pop(context, false),
                                          child: const Text('取消')),
                                      FilledButton(
                                          onPressed: () =>
                                              Navigator.pop(context, true),
                                          child: const Text('删除')),
                                    ],
                                  ),
                                );
                                if (confirmed == true) {
                                  await scope.downloads
                                      .deleteSeries(s.seriesId);
                                }
                              },
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              label: const Text('删除全部'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  void _playOffline(
      BuildContext context, DownloadService service, DownloadedSeries s,
      {int? startNumber}) {
    final eps = s.episodes
        .map((e) => Episode(
              id: e.episodeId,
              seriesId: e.seriesId,
              number: e.number,
              title: e.title,
            ))
        .toList();
    if (eps.isEmpty) return;
    var start = 0;
    if (startNumber != null) {
      final i = eps.indexWhere((e) => e.number == startNumber);
      if (i >= 0) start = i;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        series: Series(
          id: s.seriesId,
          title: s.title,
          coverUrl: s.coverUrl,
        ),
        episodes: eps,
        startIndex: start,
      ),
    ));
  }

  /// 补齐缺失：拉取全部分集列表，把未缓存的（失败/取消/新集）重新入队。
  Future<void> _fillMissing(
      BuildContext context, AppScope scope, DownloadedSeries s) async {
    try {
      final all = <Episode>[];
      var cursor = '';
      for (var guard = 0; guard < 50; guard++) {
        final page =
            await scope.api.listEpisodes(s.seriesId, cursor: cursor);
        all.addAll(page.items);
        if (!page.hasMore || page.cursor.isEmpty) break;
        cursor = page.cursor;
      }
      final added = scope.downloads.enqueue(
        Series(id: s.seriesId, title: s.title, coverUrl: s.coverUrl),
        all,
      );
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(added > 0
                ? '已加入 $added 集下载队列'
                : '没有需要补齐的集')));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
            content: Text('拉取分集列表失败，请检查网络')));
      }
    }
  }

  List<DownloadTask> _activeTasks(
          DownloadService service, String seriesId) =>
      service.tasks.values
          .where((t) =>
              t.episode.seriesId == seriesId &&
              (t.state == DownloadState.queued ||
                  t.state == DownloadState.running ||
                  t.state == DownloadState.paused))
          .toList();

  int _failedCount(DownloadService service, String seriesId) => service
      .tasks
      .values
      .where((t) =>
          t.episode.seriesId == seriesId &&
          t.state == DownloadState.failed)
      .length;

  String _activeLabel(DownloadService service, String seriesId) {
    final active = service.activeCount(seriesId);
    final paused = service.pausedCount(seriesId);
    return '${active > 0 ? ' · 下载中 $active 集' : ''}'
        '${paused > 0 ? ' · 暂停 $paused 集' : ''}';
  }

  String _stateLabel(DownloadState state) => switch (state) {
        DownloadState.queued => '排队中',
        DownloadState.running => '下载中',
        DownloadState.paused => '已暂停',
        DownloadState.done => '已完成',
        DownloadState.failed => '失败',
        DownloadState.cancelled => '已取消',
      };

  String _fmtBytes(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)}GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)}MB';
    if (bytes >= 1 << 10) return '${(bytes / (1 << 10)).toStringAsFixed(0)}KB';
    return '${bytes}B';
  }
}
