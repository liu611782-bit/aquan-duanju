import 'package:flutter/material.dart';

import '../core/aqua_error.dart';
import '../core/reading_sort.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'book_audio_screen.dart';
import 'book_detail_screen.dart';

/// 书架：在读的小说与漫画，可继续、可移除、可排序。
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  ReadingSort _sort = ReadingSort.recent;

  /// 多选模式（Pathfin LibrarySelection 同语义）：长按进入，批量移除。
  bool _selectionMode = false;
  final Set<String> _selectedBookIds = {};

  void _enterSelection(String bookId) {
    setState(() {
      _selectionMode = true;
      _selectedBookIds
        ..clear()
        ..add(bookId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selectedBookIds.clear();
    });
  }

  void _toggleSelected(String bookId) {
    setState(() {
      if (!_selectedBookIds.remove(bookId)) _selectedBookIds.add(bookId);
      if (_selectedBookIds.isEmpty) _selectionMode = false;
    });
  }

  Future<void> _removeSelected() async {
    if (_selectedBookIds.isEmpty) return;
    final scope = AppScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('移除选中的 ${_selectedBookIds.length} 本？'),
        content: const Text('会移除这些书的阅读记录，离线缓存不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final bookId in List<String>.of(_selectedBookIds)) {
      await scope.reading.remove(bookId);
    }
    _exitSelection();
  }

  Future<void> _clearAll(BuildContext context) async {
    final scope = AppScope.read(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空书架？'),
        content: const Text('会移除全部阅读记录，离线缓存不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final entry in scope.reading.entries) {
      await scope.reading.remove(entry.bookId);
    }
  }

  /// 继续听：书架没有章节数据，先拉目录再进听书页。
  Future<void> _continueListening(ListenEntry entry) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final directory = await AppScope.read(context).api.bookDirectory(
        entry.bookId,
      );
      if (!mounted) return;
      if (directory.chapters.isEmpty) {
        messenger.showSnackBar(
          const SnackBar(content: Text('这本书暂时没有可听的章节')),
        );
        return;
      }
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => BookAudioScreen(
            bookId: entry.bookId,
            bookTitle: entry.title,
            coverUrl: entry.coverUrl,
            chapters: directory.chapters,
            startIndex: entry.chapterIndex.clamp(
              0,
              directory.chapters.length - 1,
            ),
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(e is AquaException ? e.friendlyText : '打开听书失败'),
        ),
      );
    }
  }

  /// 「继续听」卡片：只展示最近一条听书记录（没有就不画）。
  Widget _buildContinueListen(ListenEntry entry) {
    final theme = Theme.of(context);
    final chapter = entry.chapterTitle.isEmpty ? '上次听到' : entry.chapterTitle;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        leading: SizedBox(
          width: 44,
          height: 58,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: CoverImage(url: entry.coverUrl),
          ),
        ),
        title: Text(
          '继续听 · ${entry.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          entry.chapters > 0
              ? '$chapter · 第 ${entry.chapterIndex + 1}/${entry.chapters} 章'
              : chapter,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Icon(
          Icons.play_circle_fill,
          color: theme.colorScheme.primary,
        ),
        onTap: () => _continueListening(entry),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return Scaffold(
      appBar: _selectionMode
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '退出多选',
                onPressed: _exitSelection,
              ),
              title: Text('已选 ${_selectedBookIds.length} 本'),
              actions: [
                TextButton(
                  onPressed: () {
                    final entries = sortReadingEntries(
                        scope.reading.entries, _sort);
                    final allSelected = entries.isNotEmpty &&
                        entries.every((e) => _selectedBookIds.contains(e.bookId));
                    setState(() {
                      if (allSelected) {
                        _selectedBookIds.clear();
                      } else {
                        _selectedBookIds
                          ..clear()
                          ..addAll(entries.map((e) => e.bookId));
                      }
                    });
                  },
                  child: const Text('全选'),
                ),
                IconButton(
                  tooltip: '移除选中',
                  icon: const Icon(Icons.delete_outline),
                  onPressed:
                      _selectedBookIds.isEmpty ? null : _removeSelected,
                ),
              ],
            )
          : AppBar(
              title: const Text('书架'),
              actions: [
                PopupMenuButton<ReadingSort>(
                  tooltip: '排序',
                  icon: const Icon(Icons.sort),
                  onSelected: (sort) => setState(() => _sort = sort),
                  itemBuilder: (context) => [
                    for (final sort in ReadingSort.values)
                      PopupMenuItem(
                        value: sort,
                        child: Row(
                          children: [
                            if (sort == _sort)
                              const Icon(Icons.check, size: 16)
                            else
                              const SizedBox(width: 16),
                            const SizedBox(width: 8),
                            Text(readingSortLabel(sort)),
                          ],
                        ),
                      ),
                  ],
                ),
                IconButton(
                  tooltip: '清空',
                  icon: const Icon(Icons.delete_sweep_outlined),
                  onPressed: () => _clearAll(context),
                ),
              ],
            ),
      body: ListenableBuilder(
        // 阅读与听书两个 store 任一变都要重画（听书记录会带来「继续听」卡片）。
        listenable: Listenable.merge(<Listenable>[
          scope.reading,
          scope.listening,
        ]),
        builder: (context, _) {
          final entries = sortReadingEntries(scope.reading.entries, _sort);
          final listen = scope.listening.entries.isEmpty
              ? null
              : scope.listening.entries.first;
          final hasListen = listen != null;
          if (entries.isEmpty && !hasListen) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_book_outlined,
                      size: 56, color: Theme.of(context).colorScheme.outline),
                  const SizedBox(height: 12),
                  Text('读过的小说和漫画会出现在这里',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.outline)),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            itemCount: entries.length + (hasListen ? 1 : 0),
            separatorBuilder: (_, i) => i == 0 && hasListen
                ? const SizedBox(height: 4)
                : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (listen != null && i == 0) {
                return _buildContinueListen(listen);
              }
              final entry = entries[i - (hasListen ? 1 : 0)];
              final selected = _selectedBookIds.contains(entry.bookId);
              return ListTile(
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
                leading: _selectionMode
                    ? Checkbox(
                        value: selected,
                        onChanged: (_) => _toggleSelected(entry.bookId),
                      )
                    : SizedBox(
                        width: 52,
                        height: 70,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CoverImage(url: entry.coverUrl),
                        ),
                      ),
                title: Text(entry.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${entry.manga ? '看到' : '读到'} · ${entry.chapterTitle}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: entry.percent),
                  ],
                ),
                trailing: _selectionMode
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => scope.reading.remove(entry.bookId),
                      ),
                onLongPress:
                    _selectionMode ? null : () => _enterSelection(entry.bookId),
                onTap: () {
                  if (_selectionMode) {
                    _toggleSelected(entry.bookId);
                    return;
                  }
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BookDetailScreen(
                      bookId: entry.bookId,
                      title: entry.title,
                      coverUrl: entry.coverUrl,
                      manga: entry.manga,
                    ),
                  ));
                },
              );
            },
          );
        },
      ),
    );
  }
}
