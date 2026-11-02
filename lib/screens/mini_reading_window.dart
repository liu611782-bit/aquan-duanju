import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/stats/reading_stats.dart';
import '../widgets/common.dart';

/// 置顶迷你阅读浮窗（桌面替代「手机桌面小组件」）。
///
/// 实现方式：**复用主窗口**——临时缩小 + 置顶 + 去标题栏内容，
/// 退出时恢复原尺寸与置顶状态。不用多窗口插件，避免平台侧风险。
class MiniReadingWindow {
  const MiniReadingWindow._();

  static const Size miniSize = Size(380, 260);
  static const Size minSize = Size(320, 200);

  /// 打开浮窗（[context] 用于取数据与导航）。
  static Future<void> open(BuildContext context) async {
    final navigator = Navigator.of(context);
    Size? previousSize;
    try {
      previousSize = await windowManager.getSize();
      await windowManager.setAlwaysOnTop(true);
      await windowManager.setMinimumSize(minSize);
      await windowManager.setSize(miniSize);
      await windowManager.center();
    } catch (_) {
      // 窗口管理不可用（如测试环境）时仍展示面板，只是不改变窗口。
    }

    try {
      await navigator.push(MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => const MiniReadingPanel(),
      ));
    } finally {
      try {
        await windowManager.setAlwaysOnTop(false);
        if (previousSize != null) {
          await windowManager.setSize(previousSize);
        }
        await windowManager.setMinimumSize(const Size(900, 600));
        await windowManager.center();
      } catch (_) {}
    }
  }
}

/// 浮窗内容：今日阅读、当前在读与进度、最近摘录。
class MiniReadingPanel extends StatefulWidget {
  const MiniReadingPanel({super.key, this.stats});

  final ReadingStatsStore? stats;

  @override
  State<MiniReadingPanel> createState() => _MiniReadingPanelState();
}

class _MiniReadingPanelState extends State<MiniReadingPanel> {
  ReadingStatsSnapshot? _snapshot;
  late final ReadingStatsStore _stats = widget.stats ?? ReadingStatsStore.shared;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _stats.ensureLoaded();
    if (!mounted) return;
    setState(() => _snapshot = _stats.snapshot());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.read(context);
    final reading = scope.reading.entries;
    final current = reading.isEmpty ? null : reading.first;

    String excerpt = '';
    if (reading.isNotEmpty) {
      final marks = scope.bookmarks.of(reading.first.bookId);
      if (marks.isNotEmpty) excerpt = marks.first.excerpt;
    }

    final today = _snapshot?.secondsOn(DateTime.now()) ?? 0;
    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.auto_stories_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Text('阅读浮窗', style: theme.textTheme.labelLarge),
                const Spacer(),
                Text(
                  today <= 0 ? '今日还没读' : '今日 ${(today / 60).round()} 分钟',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
                const SizedBox(width: 6),
                IconButton(
                  tooltip: '还原窗口',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close_fullscreen, size: 16),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (current == null)
              Expanded(
                child: Center(
                  child: Text('书架还是空的', style: theme.textTheme.bodySmall),
                ),
              )
            else ...[
              Text(
                current.title.isEmpty ? '未命名' : current.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 4),
              Text(
                '读到 ${current.chapterTitle.isEmpty ? '第 ${current.chapterIndex + 1} 章' : current.chapterTitle}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              const SizedBox(height: 6),
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: current.percent,
                  minHeight: 4,
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest
                        .withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    excerpt.isEmpty ? '（这本书还没有摘录）' : excerpt,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
