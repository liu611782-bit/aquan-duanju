import 'package:flutter/material.dart';

import '../core/books/book_source_model.dart';
import '../core/books/book_source_service.dart';
import '../models/book.dart';
import '../widgets/common.dart';
import 'reader_screen.dart';

/// 外部/内置书源的书籍详情：封面 / 作者 / 简介 / 目录 → 点章进阅读器。
///
/// `textLoader` 注入正文来源（legado、so-novel、Wenku8 走同一套 UI）。
/// 目录里的卷条目（`isVolume`）作为分组标题展示，不可点击。
class BookSourceBookPage extends StatefulWidget {
  const BookSourceBookPage({
    super.key,
    required this.service,
    required this.source,
    required this.hit,
  });

  final BookSourceService service;
  final BookSource source;
  final BookHit hit;

  @override
  State<BookSourceBookPage> createState() => _BookSourceBookPageState();
}

class _BookSourceBookPageState extends State<BookSourceBookPage> {
  BookDetailData? _info;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await widget.service
          .detail(widget.source, widget.hit.bookUrl)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String get _readerBookId =>
      'booksrc:${widget.source.url}:${widget.hit.bookUrl}';

  String get _title => _info != null && _info!.name.isNotEmpty
      ? _info!.name
      : widget.hit.name;

  void _openChapter(List<BookTocItem> chapters, BookTocItem chapter) {
    final bookChapters = [
      for (final t in chapters)
        if (!t.isVolume && t.url.isNotEmpty)
          BookChapter(id: t.url, title: t.title),
    ];
    if (bookChapters.isEmpty) return;
    final index = bookChapters.indexWhere((b) => b.id == chapter.url);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        bookId: _readerBookId,
        bookTitle: _title,
        chapters: bookChapters,
        initialIndex: index < 0 ? 0 : index,
        textLoader: (c) => widget.service.content(widget.source, c.id),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = _info?.chapters ?? const <BookTocItem>[];
    final chapterCount = chapters.where((c) => !c.isVolume).length;
    final cover = widget.hit.coverUrl.isEmpty
        ? (_info?.coverUrl ?? '')
        : widget.hit.coverUrl;

    return Scaffold(
      appBar: AppBar(title: Text(widget.hit.name.isEmpty ? '书籍详情' : widget.hit.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetryView(error: _error!, onRetry: _load)
              : ListView(
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
                            child: cover.isNotEmpty
                                ? Image.network(cover,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                        color: theme
                                            .colorScheme.surfaceContainerHighest))
                                : Container(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.menu_book)),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_title, style: theme.textTheme.titleLarge),
                              const SizedBox(height: 4),
                              Text(
                                [widget.hit.author, widget.source.name]
                                    .where((t) => t.trim().isNotEmpty)
                                    .join(' · '),
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: theme.colorScheme.outline),
                              ),
                              if ((_info?.intro ?? widget.hit.intro).isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(_info?.intro ?? widget.hit.intro,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(height: 1.4)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('目录（$chapterCount 章）',
                        style: theme.textTheme.titleMedium),
                    for (final c in chapters)
                      if (c.isVolume)
                        Padding(
                          padding: const EdgeInsets.only(top: 12, bottom: 4),
                          child: Text(
                            c.title,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        )
                      else
                        ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(c.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: c.url.isEmpty
                              ? null
                              : () => _openChapter(chapters, c),
                        ),
                  ],
                ),
    );
  }
}
