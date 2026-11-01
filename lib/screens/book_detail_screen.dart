import 'dart:async';

import 'package:flutter/material.dart';

import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import 'book_audio_screen.dart';
import 'manga_reader_screen.dart';
import 'search_screen.dart';
import 'reader_screen.dart';

/// 从阅读进度打开一本书（统一入口，便于以后加转场/埋点）。
void openBook(BuildContext context, ReadingEntry entry) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => BookDetailScreen(
      bookId: entry.bookId,
      title: entry.title,
      coverUrl: entry.coverUrl,
      manga: entry.manga,
    ),
  ));
}

/// 书籍详情：封面/简介/目录入口/继续阅读。
class BookDetailScreen extends StatefulWidget {
  const BookDetailScreen({
    super.key,
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.manga = false,
  });

  final String bookId;

  /// 漫画：用「话」计量并进入图片阅读器。
  final bool manga;

  /// 列表页带过来的标题与封面，加载期间先占位。
  final String title;
  final String coverUrl;

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  BookDetail? _detail;
  BookDirectory? _directory;
  Object? _error;
  bool _loading = true;
  bool _abstractExpanded = false;

  /// 当前内容来自快照缓存（秒开）；后台刷新失败时保留缓存并提示。
  bool _fromCache = false;
  bool _refreshFailed = false;

  String get _detailKey => 'aqua:detail:${widget.bookId}';
  String get _directoryKey => 'aqua:dir:${widget.bookId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _fromCache = false;
      _refreshFailed = false;
    });
    // 快照秒开：命中先渲染（无 loading 闪烁），后台刷新；失败保留缓存。
    // async 间隙不摸 context：scope 在首个 await 前一次取齐。
    final scope = AppScope.read(context);
    final store = scope.detailSnapshots;
    final api = scope.api;
    await store.ensureLoaded();
    final cachedDetail = store.get(_detailKey);
    final cachedDirectory = store.get(_directoryKey);
    final hasSnapshot = cachedDetail != null || cachedDirectory != null;
    if (hasSnapshot && mounted) {
      setState(() {
        if (cachedDetail != null) _detail = BookDetail.fromJson(cachedDetail);
        if (cachedDirectory != null) {
          _directory = BookDirectory.fromJson(cachedDirectory);
        }
        _loading = false;
        _fromCache = true;
      });
    }
    try {
      final results = await Future.wait<Object>([
        api.bookDetail(widget.bookId),
        api.bookDirectory(widget.bookId),
      ]);
      if (!mounted) return;
      final detail = results[0] as BookDetail;
      final directory = results[1] as BookDirectory;
      setState(() {
        _detail = detail;
        _directory = directory;
        _loading = false;
        _fromCache = false;
        _refreshFailed = false;
      });
      unawaited(store.put(_detailKey, detail.toJson()));
      unawaited(store.put(_directoryKey, directory.toJson()));
    } catch (e) {
      if (!mounted) return;
      if (hasSnapshot) {
        // 刷新失败：保留缓存内容，轻提示（详情页仍可用）。
        setState(() {
          _loading = false;
          _refreshFailed = true;
        });
      } else {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  String get _title =>
      _detail?.title.isNotEmpty == true ? _detail!.title : widget.title;

  String get _cover =>
      _detail?.coverUrl.isNotEmpty == true ? _detail!.coverUrl : widget.coverUrl;

  ReadingEntry? get _progress =>
      AppScope.read(context).reading.entry(widget.bookId);

  /// 小说按「章」，漫画按「话」。
  String get _unit => widget.manga ? '话' : '章';

  void _openReader({int? chapterIndex}) {
    final directory = _directory;
    if (directory == null || directory.isEmpty) return;
    final progress = _progress;
    final index = (chapterIndex ?? progress?.chapterIndex ?? 0)
        .clamp(0, directory.chapters.length - 1);
    final restore = chapterIndex == null ? (progress?.offset ?? 0) : 0.0;
    // 字符偏移比比例更稳：改过字号也落回同一句。
    final restoreChar =
        chapterIndex == null ? (progress?.charOffset ?? -1) : -1;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => widget.manga
          ? MangaReaderScreen(
              bookId: widget.bookId,
              bookTitle: _title,
              coverUrl: _cover,
              chapters: directory.chapters,
              initialIndex: index,
              restoreOffset: restore,
            )
          : ReaderScreen(
              bookId: widget.bookId,
              bookTitle: _title,
              coverUrl: _cover,
              chapters: directory.chapters,
              initialIndex: index,
              restoreOffset: restore,
              restoreCharOffset: restoreChar,
            ),
    ));
  }

  /// 听书：同一部书的音轨（智能朗读 / 真人讲书）。
  void _openAudio() {
    final directory = _directory;
    if (directory == null || directory.isEmpty) return;
    final progress = _progress;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookAudioScreen(
        bookId: widget.bookId,
        bookTitle: _title,
        coverUrl: _cover,
        chapters: directory.chapters,
        startIndex: (progress?.chapterIndex ?? 0)
            .clamp(0, directory.chapters.length - 1),
      ),
    ));
  }

  Future<void> _showDirectory() async {
    final directory = _directory;
    if (directory == null) return;
    final picked = await showBookDirectorySheet(
      context,
      chapters: directory.chapters,
      currentIndex: _progress?.chapterIndex ?? -1,
      title: _title,
    );
    if (picked != null && mounted) _openReader(chapterIndex: picked);
  }

  @override
  Widget build(BuildContext context) {
    // 阅读进度是全局 store：从阅读器返回后「继续阅读」的章节文案要立刻刷新。
    return ListenableBuilder(
      listenable: AppScope.read(context).reading,
      builder: (context, _) => _buildScaffold(context),
    );
  }

  Widget _buildScaffold(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书籍详情')),
      body: Column(
        children: [
          if (_fromCache && _refreshFailed) _buildCacheBanner(context),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _load,
              child: _buildContent(context),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _loading || _error != null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!widget.manga) ...[
                      OutlinedButton.icon(
                        onPressed: _openAudio,
                        icon: const Icon(Icons.headset, size: 18),
                        label: const Text('听书'),
                        style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(42)),
                      ),
                      const SizedBox(height: 8),
                    ],
                    FilledButton.icon(
                      onPressed: () => _openReader(),
                      icon: const Icon(Icons.menu_book),
                      label: Text(_progress == null
                          ? '开始阅读'
                          : '继续阅读 · ${_progress!.chapterTitle}'),
                      style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(46)),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  /// 缓存兜底横幅：刷新失败但快照可用。
  Widget _buildCacheBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cloud_off_rounded,
                  size: 14, color: theme.colorScheme.outline),
              const SizedBox(width: 6),
              Text('网络不可用，正在显示缓存数据',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final directory = _directory;
    final progress = _progress;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 104,
                height: 140,
                child: CoverImage(url: _cover),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    detail?.author.isNotEmpty == true
                        ? detail!.author
                        : '佚名',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      if (detail?.category.isNotEmpty == true)
                        // 分类标签可点：跳按标签词的搜索（书库筛选入口的补充路径）。
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => showSearchScreen(context,
                              query: detail.category),
                          child: _chip(context, detail!.category),
                        ),
                      if (detail?.finished == true) _chip(context, '完结'),
                      if (detail?.score.isNotEmpty == true)
                        _chip(context, '评分 ${detail!.score}'),
                      if ((detail?.chapterCount ?? 0) > 0)
                        _chip(context, '${detail!.chapterCount} $_unit'),
                      if ((detail?.wordCount ?? 0) > 0)
                        _chip(context, _formatWords(detail!.wordCount)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 16),
          Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(Icons.history,
                  color: theme.colorScheme.primary),
              title: Text('上次读到 · ${progress.chapterTitle}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              // 漫画同样复用这条记录，只是章节标题是「第N话」。
              subtitle: LinearProgressIndicator(value: progress.percent),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openReader(),
            ),
          ),
        ],
        if ((detail?.abstractText ?? '').isNotEmpty) ...[
          const SizedBox(height: 18),
          Text('简介',
              style: theme.textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            detail!.abstractText,
            maxLines: _abstractExpanded ? null : 4,
            overflow: _abstractExpanded ? null : TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () =>
                  setState(() => _abstractExpanded = !_abstractExpanded),
              child: Text(_abstractExpanded ? '收起' : '展开'),
            ),
          ),
        ],
        if (directory != null && !directory.isEmpty) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Text('目录',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const Spacer(),
              TextButton(
                onPressed: _showDirectory,
                child: Text('全部 ${directory.total} $_unit'),
              ),
            ],
          ),
          for (final chapter in directory.chapters.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(chapter.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _openReader(chapterIndex: chapter.index),
            ),
        ],
      ],
    );
  }

  Widget _chip(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }

  String _formatWords(int words) {
    if (words >= 10000) return '${(words / 10000).toStringAsFixed(1)} 万字';
    return '$words 字';
  }
}
