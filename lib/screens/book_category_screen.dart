import 'package:flutter/material.dart';

import '../core/error_log.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'book_detail_screen.dart';

/// 小说分类页：受众标签页（全部/男生/女生）+ 分类瓦片网格。
///
/// 瓦片来自 `new_category/front`，点进去是 `new_category/landing` 的书单页。
class BookCategoryScreen extends StatefulWidget {
  const BookCategoryScreen({super.key});

  @override
  State<BookCategoryScreen> createState() => _BookCategoryScreenState();
}

class _BookCategoryScreenState extends State<BookCategoryScreen> {
  CategoryPage? _page;
  Object? _error;
  bool _loading = true;
  String _tab = '1';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context).api.categoryTiles(tab: _tab);
      if (!mounted) return;
      setState(() {
        _page = page;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: const Text('小说分类')),
      body: Column(
        children: [
          if (page != null && page.tabs.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final tab in page.tabs)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(tab.name),
                        selected: tab.value == _tab,
                        onSelected: (_) {
                          if (tab.value == _tab) return;
                          setState(() => _tab = tab.value);
                          _load();
                        },
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _load,
              empty: (page?.tiles.isEmpty) ?? false,
              emptyText: '没有分类',
              child: RefreshIndicator(
                onRefresh: _load,
                child: GridView.builder(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 4,
                    mainAxisSpacing: 12,
                    crossAxisSpacing: 12,
                    childAspectRatio: 0.78,
                  ),
                  itemCount: page?.tiles.length ?? 0,
                  itemBuilder: (context, i) {
                    final tile = page!.tiles[i];
                    return InkWell(
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => BookCategoryListScreen(
                          categoryId: tile.categoryId,
                          categoryName: tile.name,
                          tab: _tab,
                        ),
                      )),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: SizedBox(
                                width: double.infinity,
                                child: tile.picUrl.isEmpty
                                    ? Container(
                                        color: theme
                                            .colorScheme.surfaceContainerHighest,
                                        child: const Icon(Icons.menu_book))
                                    : CoverImage(url: tile.picUrl,
                                        onFetchError: () {
                                          ErrorLog.instance.record(
                                              '分类封面',
                                              '加载失败 name=${tile.name} '
                                              'url=${tile.picUrl}');
                                        }),
                              ),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(tile.name,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
/// 某个分类下的书单页：筛选组 + 书网格。
class BookCategoryListScreen extends StatefulWidget {
  const BookCategoryListScreen({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.tab = '1',
  });

  final String categoryId;
  final String categoryName;

  /// 受众标签页（1 男频 / 0 女频 / 8 全部）。
  final String tab;

  @override
  State<BookCategoryListScreen> createState() => _BookCategoryListScreenState();
}

class _BookCategoryListScreenState extends State<BookCategoryListScreen> {
  final _items = <SeriesSummary>[];
  final _filters = <String, String>{};
  CategoryPage? _page;
  Object? _error;
  bool _loading = true;
  bool _loadingMore = false;
  String _cursor = '';
  bool _hasMore = false;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context).api.categoryLanding(
        widget.categoryId,
        tab: widget.tab,
        filters: _filters,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _page = page;
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = '${page.nextOffset}';
        _hasMore = page.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _error != null) return;
    final seq = _seq;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context).api.categoryLanding(
        widget.categoryId,
        tab: widget.tab,
        filters: _filters,
        cursor: _cursor,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        final seen = {for (final s in _items) s.id};
        for (final item in page.items) {
          if (!seen.contains(item.id)) {
            seen.add(item.id);
            _items.add(item);
          }
        }
        _cursor = '${page.nextOffset}';
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // 翻页失败静默，下次触底再试。
    } finally {
      if (seq == _seq) _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      appBar: AppBar(title: Text(widget.categoryName)),
      body: Column(
        children: [
          if (page != null && page.filters.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final group in page.filters)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: SizedBox(
                        height: 38,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          children: [
                            for (final option in group.options)
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(option.name),
                                  selected: _filters[group.key] == option.value,
                                  onSelected: (_) {
                                    setState(() {
                                      if (option.value.isEmpty) {
                                        _filters.remove(group.key);
                                      } else {
                                        _filters[group.key] = option.value;
                                      }
                                    });
                                    _load();
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _load,
              empty: _items.isEmpty,
              emptyText: '这个分类下暂时没有书',
              child: RefreshIndicator(
                onRefresh: _load,
                child: SeriesGrid(
                  items: _items,
                  hasMore: _hasMore,
                  onLoadMore: _loadMore,
                  onTap: (item) => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BookDetailScreen(
                        bookId: item.id,
                        title: item.title,
                        coverUrl: item.coverUrl,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}