import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/aqua_error.dart';
import '../core/books/local_book_source.dart';
import '../core/reading_sort.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import 'book_audio_screen.dart';
import 'book_detail_screen.dart';
import 'reader_screen.dart';

/// 书架：在读的小说与漫画，可继续、可移除、可排序。
class BookshelfScreen extends StatefulWidget {
  const BookshelfScreen({super.key});

  @override
  State<BookshelfScreen> createState() => _BookshelfScreenState();
}

class _BookshelfScreenState extends State<BookshelfScreen> {
  /// 排序偏好持久化（Pathfin LibraryPersonalization 同语义）：按枚举 name
  /// 存 SharedPreferences，损坏/未知值回退 recent。
  static const _sortKey = 'shelf.sort';

  ReadingSort _sort = ReadingSort.recent;

  /// 本地书库（复制入库；TXT/EPUB/HTML/MD/ZIP）。
  LocalBookStore? _localStore;

  /// 拖拽悬停高亮。
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _loadSort();
    _loadLocalBooks();
  }

  Future<void> _loadLocalBooks() async {
    final prefs = await SharedPreferences.getInstance();
    final library = await BookLibrary.openDefault(prefs: prefs);
    final store = LocalBookStore(library);
    await store.ensureLoaded();
    if (!mounted) return;
    setState(() => _localStore = store);
  }

  Future<void> _loadSort() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      final saved = prefs.getString(_sortKey);
      _sort = ReadingSort.values
          .where((v) => v.name == saved)
          .firstOrNull ?? ReadingSort.recent;
    });
  }

  Future<void> _changeSort(ReadingSort sort) async {
    setState(() => _sort = sort);
    final prefs = await SharedPreferences.getInstance();
    // ignore: discarded_futures
    prefs.setString(_sortKey, sort.name);
  }

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

  /// 导入本地书（多选）：支持 txt/epub/html/md/zip，复制入库并解析章节。
  Future<void> _importLocalBooks() async {
    final store = _localStore;
    if (store == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final typeGroup = XTypeGroup(
        label: '电子书',
        extensions: store.supportedExtensions.toList()..sort(),
      );
      final files = await openFiles(acceptedTypeGroups: [typeGroup]);
      if (files.isEmpty) return;
      await _runImport(
        messenger,
        () => store.importPaths([for (final f in files) f.path]),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  /// 扫描文件夹导入（递归，跳过隐藏目录）。
  Future<void> _importLocalFolder() async {
    final store = _localStore;
    if (store == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final dir = await getDirectoryPath(confirmButtonText: '扫描导入');
      if (dir == null) return;
      await _runImport(messenger, () => store.importFolder(dir));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('扫描失败：$e')));
    }
  }

  /// 拖拽导入（文件或文件夹）。
  Future<void> _importDropped(List<String> paths) async {
    final store = _localStore;
    if (store == null || paths.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    await _runImport(messenger, () async {
      final results = <LocalBookImportResult>[];
      for (final path in paths) {
        if (FileSystemEntity.isDirectorySync(path)) {
          results.addAll(await store.importFolder(path));
        } else {
          results.addAll(await store.importPaths([path]));
        }
      }
      return results;
    });
  }

  /// 统一导入结果汇报：成功/重复/失败逐条列出前几条原因。
  Future<void> _runImport(
    ScaffoldMessengerState messenger,
    Future<List<LocalBookImportResult>> Function() run,
  ) async {
    final results = await run();
    if (!mounted) return;
    final ok = results.where((r) => r.ok && !r.duplicated).length;
    final dup = results.where((r) => r.duplicated).length;
    final failed = results.where((r) => !r.ok).toList();
    final buffer = StringBuffer('导入 $ok 本');
    if (dup > 0) buffer.write('，$dup 本已存在（去重）');
    if (failed.isNotEmpty) {
      buffer.write('，${failed.length} 个失败');
      final sample = failed
          .take(3)
          .map((r) =>
              '${r.sourcePath.replaceAll('\\', '/').split('/').last}：${r.error}')
          .join('；');
      buffer.write('（$sample${failed.length > 3 ? '…' : ''}）');
    }
    messenger.showSnackBar(SnackBar(content: Text(buffer.toString())));
  }

  /// 打开本地书（直接进阅读器，无需网络；从上次进度续读）。
  Future<void> _openLocalBook(LocalBookEntry entry) async {
    final store = _localStore;
    if (store == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final scope = AppScope.read(context);
    try {
      final doc = await store.open(entry.id);
      if (doc == null) {
        messenger.showSnackBar(const SnackBar(content: Text('本地书不存在，可能已被删除')));
        return;
      }
      final chapters = [
        for (final c in store.chaptersOf(entry))
          BookChapter(id: c.id, title: c.title),
      ];
      if (chapters.isEmpty) {
        messenger.showSnackBar(const SnackBar(content: Text('这本书没有可读章节')));
        return;
      }
      final bookId = 'local:${entry.id}';
      final saved = scope.reading.entry(bookId);
      final initialIndex = saved == null
          ? 0
          : saved.chapterIndex.clamp(0, chapters.length - 1);
      final runtime = LocalBookRuntime(store);
      if (!mounted) return;
      await navigator.push(MaterialPageRoute(
        builder: (_) => ReaderScreen(
          bookId: bookId,
          bookTitle: entry.title,
          chapters: chapters,
          initialIndex: initialIndex,
          textLoader: (chapter) => runtime.content(chapter.id),
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('本地书读取失败：$e')));
    }
  }

  /// 本地书列表段（书架顶部，独立于阅读记录）。
  List<Widget> _localBookTiles() {
    final store = _localStore;
    if (store == null || store.entries.isEmpty) return const [];
    final reading = AppScope.read(context).reading;
    final theme = Theme.of(context);
    final roots = store.entries.values.toList()
      ..sort((a, b) => b.importedAt.compareTo(a.importedAt));
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
        child: Row(
          children: [
            Text('本地书（${store.entries.length}）',
                style: theme.textTheme.titleSmall),
            const Spacer(),
            Text(store.supportedExtensions.map((e) => e.toUpperCase()).join(' / '),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
        ),
      ),
      for (final entry in roots)
        Builder(builder: (context) {
          final coverPath = store.coverPathOf(entry);
          final progress = reading.entry('local:${entry.id}');
          final progressText = progress == null
              ? null
              : '读到 ${progress.chapterTitle.isEmpty ? '第 ${progress.chapterIndex + 1} 章' : progress.chapterTitle}'
                  '（${progress.chapterIndex + 1}/${entry.chapterCount}）';
          return ListTile(
            contentPadding: const EdgeInsets.symmetric(vertical: 4),
            leading: SizedBox(
              width: 52,
              height: 70,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: coverPath.isEmpty
                    ? Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.menu_book_outlined),
                      )
                    : Image.file(
                        File(coverPath),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.menu_book_outlined)),
                      ),
              ),
            ),
            title: Text(entry.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                entry.format.toUpperCase(),
                '${entry.chapterCount} 章',
                '${entry.totalChars} 字',
                ?progressText,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: IconButton(
              tooltip: '移除',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => store.remove(entry.id),
            ),
            onTap: () => _openLocalBook(entry),
          );
        }),
      const Divider(height: 1),
    ];
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
    // 拖拽导入：把文件/文件夹拖到书架窗口即导入（桌面端主入口之一）。
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: (detail) async {
        setState(() => _dragging = false);
        await _importDropped([for (final f in detail.files) f.path]);
      },
      child: Scaffold(
        backgroundColor: _dragging
            ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.35)
            : null,
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
                PopupMenuButton<String>(
                  tooltip: '导入本地书',
                  icon: const Icon(Icons.file_open_outlined),
                  onSelected: (value) {
                    if (value == 'files') _importLocalBooks();
                    if (value == 'folder') _importLocalFolder();
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'files',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.library_add_outlined),
                        title: Text('导入文件'),
                        subtitle: Text('TXT / EPUB / HTML / MD / ZIP，可多选'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'folder',
                      child: ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(Icons.folder_open_outlined),
                        title: Text('扫描文件夹'),
                        subtitle: Text('递归扫描并逐本导入'),
                      ),
                    ),
                  ],
                ),
                PopupMenuButton<ReadingSort>(
                  tooltip: '排序',
                  icon: const Icon(Icons.sort),
                  onSelected: _changeSort,
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
          ?_localStore,
        ]),
        builder: (context, _) {
          final entries = sortReadingEntries(scope.reading.entries, _sort);
          final listen = scope.listening.entries.isEmpty
              ? null
              : scope.listening.entries.first;
          final hasListen = listen != null;
          final localTiles = _localBookTiles();
          if (entries.isEmpty && !hasListen && localTiles.isEmpty) {
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
            itemCount: localTiles.length + entries.length + (hasListen ? 1 : 0),
            separatorBuilder: (_, i) => i == 0 && hasListen
                ? const SizedBox(height: 4)
                : const Divider(height: 1),
            itemBuilder: (context, i) {
              if (i < localTiles.length) {
                return localTiles[i];
              }
              final j = i - localTiles.length;
              if (listen != null && j == 0) {
                return _buildContinueListen(listen);
              }
              final entry = entries[j - (hasListen ? 1 : 0)];
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
      ),
    );
  }
}
