import 'package:flutter/material.dart';

import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 全部观看历史：完整列表（不再截断 10 条），单条可删、可一键清空，
/// 点条目进详情页（播放中的会按秒续播）。
class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  /// 列表滚动控制器：给「回到顶部」用。
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('观看历史'),
        actions: [
          ListenableBuilder(
            listenable: scope.history,
            builder: (context, _) {
              if (scope.history.entries.isEmpty) {
                return const SizedBox.shrink();
              }
              return TextButton(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('清空观看历史？'),
                      content: const Text('进度记录会全部删除，追剧不受影响。'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('取消'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('清空'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true) await scope.history.clear();
                },
                child: const Text('清空'),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: scope.history,
        builder: (context, _) {
          final entries = scope.history.entries;
          if (entries.isEmpty) {
            return const Center(
              child: Text('看过之后，这里会记录进度', style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.separated(
            controller: _scroll,
            itemCount: entries.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final h = entries[i];
              final when = _fmtWhen(h.updatedAt);
              return ListTile(
                leading: SizedBox(
                  width: 56,
                  height: 76,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CoverImage(url: h.coverUrl),
                  ),
                ),
                title: Text(h.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                  h.finished
                      ? '已看完 · $when'
                      : '看到第${h.episode}集 ${_fmtPos(h.position)} · $when',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => openDetail(context, h.seriesId, h.title),
                trailing: IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '删除这条记录',
                  onPressed: () => scope.history.remove(h.seriesId),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: BackToTopFab(controller: _scroll),
    );
  }

  static String _fmtPos(double seconds) {
    final d = Duration(seconds: seconds.floor());
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  static String _fmtWhen(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
    if (diff.inHours < 24) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
  }
}
