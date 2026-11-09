import 'package:flutter/material.dart';

import '../core/download_service.dart';
import '../models/models.dart';

/// 播放器选集抽屉：集数网格，当前集高亮，点任意集回调。
///
/// 头部提供「全部下载」「下载管理」；每集右下角提供单集下载/状态按钮。
/// 独立无状态组件，不依赖播放器与 FFI，可纯 widget 测试。
class EpisodePickerSheet extends StatelessWidget {
  const EpisodePickerSheet({
    super.key,
    required this.title,
    required this.episodes,
    required this.currentIndex,
    required this.onSelect,
    this.isDownloaded,
    this.taskStateOf,
    this.onDownloadEpisode,
    this.onDownloadAll,
    this.onManageDownloads,
    this.refresh,
  });

  final String title;
  final List<Episode> episodes;

  /// 当前正在播的集在 [episodes] 里的下标。
  final int currentIndex;
  final ValueChanged<int> onSelect;

  /// 可选：该集是否已离线缓存（角标用）。
  final bool Function(Episode episode)? isDownloaded;

  /// 可选：该集下载任务的状态；null 表示没有任务。
  final DownloadState? Function(Episode episode)? taskStateOf;

  /// 可选：单集下载（点集右下角按钮）。参数为 [episodes] 下标。
  final ValueChanged<int>? onDownloadEpisode;

  /// 可选：一键下载全部可播放集。
  final VoidCallback? onDownloadAll;

  /// 可选：打开完整的离线缓存管理面板。
  final VoidCallback? onManageDownloads;

  /// 可选：下载状态变化时用来刷新格子（例如 DownloadService）。
  final Listenable? refresh;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final playableCount = episodes.where((e) => e.playable).length;

    Widget grid() => GridView.builder(
          shrinkWrap: true,
          itemCount: episodes.length,
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 72,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.6,
          ),
          itemBuilder: (context, i) {
            final ep = episodes[i];
            final label = ep.title.trim().isNotEmpty
                ? ep.title.trim()
                : '${i + 1}';
            final downloaded = isDownloaded?.call(ep) ?? false;
            final state = taskStateOf?.call(ep);
            return _EpisodeCell(
              label: label,
              current: i == currentIndex,
              locked: !ep.playable,
              downloaded: downloaded,
              taskState: downloaded ? null : state,
              onTap: () => onSelect(i),
              onDownload: onDownloadEpisode == null ||
                      !ep.playable ||
                      downloaded ||
                      state == DownloadState.queued ||
                      state == DownloadState.running
                  ? null
                  : () => onDownloadEpisode!(i),
            );
          },
        );

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '选集 · $title',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ),
                Text('${episodes.length}集',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
                if (onDownloadAll != null)
                  TextButton.icon(
                    onPressed: playableCount == 0 ? null : onDownloadAll,
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: const Text('全部下载'),
                  ),
                if (onManageDownloads != null)
                  IconButton(
                    tooltip: '下载管理',
                    icon: const Icon(Icons.tune, size: 20),
                    onPressed: onManageDownloads,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: refresh == null
                  ? grid()
                  : ListenableBuilder(
                      listenable: refresh!,
                      builder: (_, __) => grid(),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EpisodeCell extends StatelessWidget {
  const _EpisodeCell({
    required this.label,
    required this.current,
    required this.locked,
    required this.downloaded,
    required this.taskState,
    required this.onTap,
    required this.onDownload,
  });

  final String label;
  final bool current;
  final bool locked;
  final bool downloaded;
  final DownloadState? taskState;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  IconData? get _downloadIcon {
    if (downloaded) return null;
    switch (taskState) {
      case DownloadState.queued:
        return Icons.schedule;
      case DownloadState.running:
        return Icons.downloading;
      case DownloadState.failed:
        return Icons.error_outline;
      default:
        return locked ? null : Icons.download_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = current ? theme.colorScheme.onPrimary : theme.colorScheme.primary;
    final icon = _downloadIcon;
    return Material(
      color: current
          ? theme.colorScheme.primary
          : theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: locked ? null : onTap,
        borderRadius: BorderRadius.circular(8),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: current
                    ? theme.colorScheme.onPrimary
                    : (locked ? theme.colorScheme.outline : null),
                fontWeight: current ? FontWeight.bold : null,
              ),
            ),
            if (downloaded)
              Positioned(
                right: 3,
                top: 3,
                child: Icon(Icons.download_done, size: 13, color: fg),
              ),
            if (icon != null)
              Positioned(
                right: 0,
                bottom: 0,
                child: InkWell(
                  onTap: onDownload,
                  customBorder: const CircleBorder(),
                  child: Padding(
                    padding: const EdgeInsets.all(3),
                    child: Icon(icon, size: 14, color: fg),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 打开选集抽屉；选择集数后先关抽屉再回调下标。
/// 下载相关回调不关闭抽屉，状态通过 [refresh] 实时刷新。
Future<void> showEpisodePicker(
  BuildContext context, {
  required String title,
  required List<Episode> episodes,
  required int currentIndex,
  required ValueChanged<int> onSelect,
  bool Function(Episode episode)? isDownloaded,
  DownloadState? Function(Episode episode)? taskStateOf,
  ValueChanged<int>? onDownloadEpisode,
  VoidCallback? onDownloadAll,
  VoidCallback? onManageDownloads,
  Listenable? refresh,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: BoxConstraints(
      maxHeight: MediaQuery.sizeOf(context).height * 0.65,
    ),
    builder: (sheetContext) => EpisodePickerSheet(
      title: title,
      episodes: episodes,
      currentIndex: currentIndex,
      onSelect: (i) {
        Navigator.of(sheetContext).pop();
        onSelect(i);
      },
      isDownloaded: isDownloaded,
      taskStateOf: taskStateOf,
      onDownloadEpisode: onDownloadEpisode,
      onDownloadAll: onDownloadAll,
      onManageDownloads: onManageDownloads == null
          ? null
          : () {
              Navigator.of(sheetContext).pop();
              onManageDownloads();
            },
      refresh: refresh,
    ),
  );
}
