import 'dart:io';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/reader/reader_annotations.dart';
import '../core/stats/reading_stats.dart';
import '../widgets/common.dart';
import '../widgets/quote_card.dart';
import '../widgets/skeleton.dart';

/// 阅读统计 + 摘录卡。
///
/// - 统计：总时长 / 今日 / 连续天数 + 18 周热力图 + 按书排行；
/// - 摘录卡：从书签里挑一条，预览后导出 PNG（带季节点缀与水印）。
class ReadingStatsScreen extends StatefulWidget {
  const ReadingStatsScreen({super.key, this.stats});

  final ReadingStatsStore? stats;

  @override
  State<ReadingStatsScreen> createState() => _ReadingStatsScreenState();
}

class _ReadingStatsScreenState extends State<ReadingStatsScreen>
    with SingleTickerProviderStateMixin {
  late final ReadingStatsStore _stats = widget.stats ?? ReadingStatsStore.shared;
  late final TabController _tabs = TabController(length: 2, vsync: this);

  ReadingStatsSnapshot? _snapshot;
  List<ReaderBookmark> _bookmarks = const [];
  ReaderBookmark? _selected;
  final _cardKey = GlobalKey();
  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    await _stats.ensureLoaded();
    if (!mounted) return;
    final scope = AppScope.read(context);
    final bookmarks = <ReaderBookmark>[];
    for (final entry in scope.reading.entries) {
      bookmarks.addAll(scope.bookmarks.of(entry.bookId));
    }
    bookmarks.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    setState(() {
      _snapshot = _stats.snapshot();
      _bookmarks = bookmarks;
      _selected = bookmarks.isEmpty ? null : bookmarks.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读统计'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '统计'), Tab(text: '摘录卡')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildStats(), _buildQuotes()],
      ),
    );
  }

  // ------------------------------------------------------------------ 统计

  Widget _buildStats() {
    final snapshot = _snapshot;
    if (snapshot == null) {
      return const Center(child: SkeletonView(layout: SkeletonLayout.list));
    }
    final theme = Theme.of(context);
    final today = DateTime.now();
    final todaySeconds = snapshot.secondsOn(today);
    final recent = snapshot.recentDays(126);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        Row(
          children: [
            _StatTile(label: '总时长', value: _formatDuration(snapshot.totalSeconds)),
            const SizedBox(width: 10),
            _StatTile(label: '今日', value: _formatDuration(todaySeconds)),
            const SizedBox(width: 10),
            _StatTile(label: '连续', value: '${snapshot.streakDays} 天'),
          ],
        ),
        const SizedBox(height: 18),
        Text('近 18 周', style: theme.textTheme.titleSmall),
        const SizedBox(height: 8),
        _Heatmap(days: recent),
        const SizedBox(height: 6),
        Row(
          children: [
            Text('少', style: theme.textTheme.labelSmall),
            const SizedBox(width: 6),
            for (final level in [0, 1, 2, 3, 4])
              Container(
                width: 12,
                height: 12,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(
                  color: _heatColor(level, theme),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            const SizedBox(width: 6),
            Text('多', style: theme.textTheme.labelSmall),
            const Spacer(),
            Text(
              '共 ${snapshot.days.where((d) => d.seconds > 0).length} 天有阅读',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text('按书统计', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        if (snapshot.books.isEmpty)
          Text('还没有阅读记录', style: theme.textTheme.bodySmall)
        else
          for (final entry in _sortedBooks(snapshot))
            _BookStatRow(
              title: _bookTitle(entry.key),
              seconds: entry.value,
              maxSeconds: _maxSeconds(snapshot),
            ),
      ],
    );
  }

  List<MapEntry<String, int>> _sortedBooks(ReadingStatsSnapshot snapshot) {
    final list = snapshot.books.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(12).toList();
  }

  int _maxSeconds(ReadingStatsSnapshot snapshot) =>
      snapshot.books.values.fold<int>(1, (a, b) => a > b ? a : b);

  String _bookTitle(String bookId) {
    final entry = AppScope.read(context).reading.entry(bookId);
    final title = entry?.title ?? '';
    if (title.isNotEmpty) return title;
    if (bookId.startsWith('local:')) return '本地书（${bookId.substring(6)}）';
    return bookId;
  }

  // ------------------------------------------------------------------ 摘录卡

  Widget _buildQuotes() {
    final theme = Theme.of(context);
    if (_bookmarks.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            '还没有摘录。阅读时长按选中文字「加入书签」，这里就能生成摘录卡。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      );
    }
    final selected = _selected ?? _bookmarks.first;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
      children: [
        SizedBox(
          height: 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _bookmarks.length,
            separatorBuilder: (_, i) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final mark = _bookmarks[i];
              final active = mark.id == selected.id;
              return InkWell(
                onTap: () => setState(() => _selected = mark),
                child: Container(
                  width: 200,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: active
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                      width: active ? 1.6 : 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(mark.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.labelSmall),
                      const SizedBox(height: 6),
                      Expanded(
                        child: Text(
                          mark.excerpt.isEmpty ? '（无摘录正文）' : mark.excerpt,
                          maxLines: 5,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: RepaintBoundary(
              key: _cardKey,
              child: QuoteCard(
                excerpt: selected.excerpt,
                bookTitle: _bookTitle(selected.bookId),
                chapterTitle: selected.chapterTitle,
                createdAt: selected.createdAt,
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: _exporting ? null : () => _export(selected),
          icon: const Icon(Icons.download_outlined),
          label: Text(_exporting ? '导出中…' : '导出 PNG'),
        ),
      ],
    );
  }

  Future<void> _export(ReaderBookmark mark) async {
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _exporting = true);
    try {
      final png = await QuoteCardExporter.capture(_cardKey);
      if (png == null) {
        messenger.showSnackBar(const SnackBar(content: Text('截图失败，请重试')));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: '摘录-${mark.createdAt.year}'
            '${mark.createdAt.month.toString().padLeft(2, '0')}'
            '${mark.createdAt.day.toString().padLeft(2, '0')}.png',
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG 图片', extensions: ['png']),
        ],
      );
      if (location == null) return;
      await File(location.path).writeAsBytes(Uint8List.fromList(png));
      messenger.showSnackBar(SnackBar(content: Text('已导出：${location.path}')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }
}

String _formatDuration(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes 分钟';
  final hours = minutes ~/ 60;
  final rest = minutes % 60;
  return rest == 0 ? '$hours 小时' : '$hours 小时 $rest 分';
}

Color _heatColor(int level, ThemeData theme) {
  final base = theme.colorScheme.primary;
  return switch (level) {
    0 => theme.colorScheme.surfaceContainerHighest,
    1 => base.withValues(alpha: 0.22),
    2 => base.withValues(alpha: 0.42),
    3 => base.withValues(alpha: 0.68),
    _ => base,
  };
}

int _levelOf(int seconds) {
  if (seconds <= 0) return 0;
  final minutes = seconds / 60;
  if (minutes < 15) return 1;
  if (minutes < 40) return 2;
  if (minutes < 90) return 3;
  return 4;
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.days});

  final List<ReadingDay> days;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (days.isEmpty) return const SizedBox.shrink();
    // 按列（周）排：每列 7 天，最后不足 7 天补空。
    final columns = (days.length / 7).ceil();
    return SizedBox(
      height: 7 * 15.0,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: columns,
        itemBuilder: (context, col) {
          return Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Column(
              children: [
                for (var row = 0; row < 7; row++)
                  () {
                    final index = col * 7 + row;
                    final day = index < days.length ? days[index] : null;
                    return Container(
                      width: 12,
                      height: 12,
                      margin: const EdgeInsets.only(bottom: 3),
                      decoration: BoxDecoration(
                        color: day == null
                            ? Colors.transparent
                            : _heatColor(_levelOf(day.seconds), theme),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }(),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(label,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
    );
  }
}

class _BookStatRow extends StatelessWidget {
  const _BookStatRow({
    required this.title,
    required this.seconds,
    required this.maxSeconds,
  });

  final String title;
  final int seconds;
  final int maxSeconds;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium),
              ),
              Text(_formatDuration(seconds),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (seconds / maxSeconds).clamp(0.0, 1.0),
              minHeight: 5,
            ),
          ),
        ],
      ),
    );
  }
}
