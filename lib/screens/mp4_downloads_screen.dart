import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:share_plus/share_plus.dart';

import '../core/mp4_download_manager.dart';

/// 「我的」→「MP4 导出下载」列表页。
class Mp4DownloadsScreen extends StatefulWidget {
  const Mp4DownloadsScreen({super.key});

  @override
  State<Mp4DownloadsScreen> createState() => _Mp4DownloadsScreenState();
}

class _Mp4DownloadsScreenState extends State<Mp4DownloadsScreen> {
  final _mgr = Mp4DownloadManager.instance;

  @override
  void initState() {
    super.initState();
    _mgr.scanExisting();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('MP4 导出下载'),
        actions: [
          ListenableBuilder(
            listenable: _mgr,
            builder: (context, _) {
              return Row(
                children: [
                  const Text('完成存相册', style: TextStyle(fontSize: 12)),
                  Switch(
                    value: _mgr.autoSaveToGallery,
                    onChanged: (v) {
                      _mgr.autoSaveToGallery = v;
                      setState(() {});
                    },
                  ),
                ],
              );
            },
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 合规提示
          Material(
            color: Colors.orange.shade50,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: Colors.orange.shade800, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '请仅下载和分享你拥有版权或已获授权的内容',
                      style: TextStyle(color: Colors.orange.shade900, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 路径标注
          ListenableBuilder(
            listenable: _mgr,
            builder: (context, _) {
              final path = _mgr.lastOutputDirPath;
              if (path == null || path.isEmpty) {
                return const SizedBox.shrink();
              }
              return Material(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                child: InkWell(
                  onLongPress: () async {
                    await Clipboard.setData(ClipboardData(text: path));
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('已复制导出目录路径')),
                      );
                    }
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        Icon(Icons.folder_outlined, size: 18, color: theme.colorScheme.outline),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '导出目录：$path\n相册专辑：阿圈短剧（系统相册）',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: _mgr,
              builder: (context, _) {
                final tasks = _mgr.orderedTasks;
                if (tasks.isEmpty) {
                  return const Center(
                    child: Text(
                      '暂无导出记录\n在播放页点下载按钮即可导出 MP4',
                      textAlign: TextAlign.center,
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: tasks.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (context, i) => _TaskTile(task: tasks[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});
  final Mp4DownloadTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = task.state == Mp4TaskState.done &&
        task.outputPath != null &&
        File(task.outputPath!).existsSync();

    return ListTile(
      title: Text(task.title, maxLines: 2, overflow: TextOverflow.ellipsis),
 subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            task.message.isNotEmpty ? task.message : _stateLabel(task.state),
            style: TextStyle(
              color: task.state == Mp4TaskState.failed
                  ? theme.colorScheme.error
                  : null,
              fontSize: 13,
            ),
          ),
          if (task.outputPath != null) ...[
            const SizedBox(height: 2),
            Text(
              task.outputPath!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
                fontSize: 11,
              ),
            ),
          ],
          if (task.state == Mp4TaskState.running) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: task.progress > 0 ? task.progress : null,
            ),
          ],
        ],
      ),
      isThreeLine: true,
      trailing: done
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: task.savedToGallery ? '已存相册' : '存相册',
                  icon: Icon(
                    task.savedToGallery
                        ? Icons.photo_library
                        : Icons.photo_library_outlined,
                  ),
                  onPressed: () => _saveToGallery(context),
                ),
                IconButton(
                  tooltip: '分享',
                  icon: const Icon(Icons.share_outlined),
                  onPressed: () => _share(context),
                ),
              ],
            )
          : task.state == Mp4TaskState.running
              ? IconButton(
                  tooltip: '取消',
                  icon: const Icon(Icons.close),
                  onPressed: () => Mp4DownloadManager.instance.cancel(task.id),
                )
              : IconButton(
                  tooltip: '移除',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => Mp4DownloadManager.instance.remove(task.id),
                ),
    );
  }

  String _stateLabel(Mp4TaskState s) {
    switch (s) {
      case Mp4TaskState.queued:
        return '排队中';
      case Mp4TaskState.running:
        return '正在下载中';
      case Mp4TaskState.done:
        return '下载完成';
      case Mp4TaskState.failed:
        return '失败';
      case Mp4TaskState.cancelled:
        return '已取消';
    }
  }

  Future<void> _saveToGallery(BuildContext context) async {
    try {
      await Mp4DownloadManager.instance.saveToGallery(task.id);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到相册 · 专辑「阿圈短剧」')),
        );
      }
    } on GalException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: ${e.type}')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    }
  }

  Future<void> _share(BuildContext context) async {
    final path = task.outputPath;
    if (path == null) return;
    await SharePlus.instance.share(
      ShareParams(files: [XFile(path)], text: task.title),
    );
  }
}
