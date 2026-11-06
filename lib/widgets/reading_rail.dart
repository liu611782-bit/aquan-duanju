import 'package:flutter/material.dart';

import '../screens/book_detail_screen.dart';
import '../store/stores.dart';
import 'common.dart';
import 'tv_focusable.dart';
import 'tv_scope.dart';

/// 「最近在读」横排：小说与漫画各看各的（[manga] 过滤域），
/// 发现页小说 tab 只显示小说、漫画 tab 只显示漫画——不与影视的「继续观看」混排。
///
/// [collapsed] 为真时只保留一条约 40dp 的标题栏；[onToggleCollapsed] 提供时
/// 标题行右侧出现收起/展开按钮。不传这两个参数时行为与旧版完全一致。
class ReadingRail extends StatelessWidget {
  const ReadingRail({
    super.key,
    this.manga = false,
    this.collapsed = false,
    this.onToggleCollapsed,
  });

  /// true = 只显示漫画；false = 只显示小说。
  final bool manga;

  /// true = 折叠成一条标题栏（不渲染卡片）。
  final bool collapsed;

  /// 收起/展开回调；null 表示不显示按钮。
  final VoidCallback? onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.reading,
      builder: (context, _) {
        final entries = scope.reading.entries
            .where((e) => e.manga == manga)
            .take(10)
            .toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 4),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      const Text('最近在读',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                      if (collapsed) ...[
                        const SizedBox(width: 8),
                        Text('共${entries.length}本',
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      ],
                      const Spacer(),
                      if (onToggleCollapsed != null)
                        IconButton(
                          tooltip: collapsed ? '展开最近在读' : '收起最近在读',
                          onPressed: onToggleCollapsed,
                          visualDensity: VisualDensity.compact,
                          icon: Icon(
                            collapsed
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_up,
                            size: 20,
                          ),
                        )
                      else
                        const SizedBox(width: 12),
                    ],
                  ),
                ),
                if (!collapsed) ...[
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 172,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      children: [
                        for (final e in entries) _ReadingCard(entry: e),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ReadingCard extends StatelessWidget {
  const _ReadingCard({required this.entry});

  final ReadingEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 电视上必须可聚焦：GestureDetector 收不到遥控器确定键。
    return TvFocusable(
      enabled: TvScope.isTvOf(context),
      onTap: () => openBook(context, entry),
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 104,
                      height: 140,
                      child: CoverImage(url: entry.coverUrl),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        entry.manga ? '漫画' : '小说',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: 2),
              Text(entry.chapterTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }
}
