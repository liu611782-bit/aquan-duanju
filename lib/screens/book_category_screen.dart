import 'package:flutter/material.dart';

import '../core/error_log.dart';
import '../models/models.dart';
import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import 'book_detail_screen.dart';

/// 小说分类页：受众标签页（全部/男生/女生）+ 分类瓦片网格。
///
/// 瓦片来自 `new_category/front`，点进去是 `new_category/landing` 的书单页。
class BookCategoryScreen extends StatefulWidget {
  const BookCategoryScreen({super.key, this.initialCategory = ''});

  /// 从书详情点分类标签带入的类目名：进入后自动打开对应分类的书单页（匹配不到则停在分类网格）。
  final String initialCategory;

  @override
  State<BookCategoryScreen> createState() => _BookCategoryScreenState();
}

class _BookCategoryScreenState extends State<BookCategoryScreen> {
  CategoryPage? _page;
  Object? _error;
  bool _loading = true;
  String _tab = '1';
  bool _autoOpened = false;

  @override
  void initState() {
    super.initState();
    // 由书详情标签带入类目名时，直接用「全部」tab（含全部类目）打开，匹配率更高。
    if (widget.initialCategory.trim().isNotEmpty) _tab = '8';
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
      _maybeAutoOpenCategory(page);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 带入的类目名→分类瓦片：优先精确、再取包含，命中就自动跳到该分类书单页。
  void _maybeAutoOpenCategory(CategoryPage page) {
    if (_autoOpened || widget.initialCategory.trim().isEmpty) return;
    _autoOpened = true;
    final want = widget.initialCategory.trim();
    CategoryTile? hit;
    for (final t in page.tiles) {
      if (t.name == want) {
        hit = t;
        break;
      }
    }
    if (hit == null) {
      for (final t in page.tiles) {
        if (t.name.isNotEmpty &&
            (t.name.contains(want) || want.contains(t.name))) {
          hit = t;
          break;
        }
      }
    }
    if (hit == null) {
      // 3) 模糊：取与标签词最长公共子串 ≥ 2 的类目（如「玄幻脑洞」→「玄幻仙侠」）。
      var best = 0;
      for (final t in page.tiles) {
        final c = _commonLen(want, t.name);
        if (c > best) {
          best = c;
          hit = t;
        }
      }
      if (best < 2) hit = null;
    }
    final found = hit;
    if (found == null) {
      ErrorLog.instance.record(
          '分类标签匹配', '未匹配 want="$want" tab=$_tab '
          'tiles=${page.tiles.map((t) => t.name).take(12).join(",")}');
      return;
    }
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => BookCategoryListScreen(
        categoryId: found.categoryId,
        categoryName: found.name,
        tab: _tab,
      ),
    ));
  }

  static const List<Color> _tilePalette = <Color>[
    Color(0xFF5B8FF9), Color(0xFF61C9A0), Color(0xFFF6BD16), Color(0xFFE8684A),
    Color(0xFF6DC8EC), Color(0xFF9270CA), Color(0xFFFF9D4D), Color(0xFF5AD8A6),
  ];

  /// 无封面的分类瓦片：按类目名哈希取一个色块 + 首字，让占位看着像有意设计。
  static Color _tileColor(String name) {
    if (name.isEmpty) return _tilePalette.first;
    var h = 0;
    for (final r in name.runes) {
      h = (h * 31 + r) & 0x7FFFFFFF;
    }
    return _tilePalette[h % _tilePalette.length];
  }

  /// 两串最长公共连续子串的长度（标签词↔粗类目的模糊度，短串 O(n*m) 足够）。
  static int _commonLen(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final al = a.runes.toList();
    final bl = b.runes.toList();
    var best = 0;
    final dp = List.generate(al.length + 1, (_) => List.filled(bl.length + 1, 0));
    for (var i = 1; i <= al.length; i++) {
      for (var j = 1; j <= bl.length; j++) {
        if (al[i - 1] == bl[j - 1]) {
          dp[i][j] = dp[i - 1][j - 1] + 1;
          if (dp[i][j] > best) best = dp[i][j];
        }
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
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
                                        color: _tileColor(tile.name),
                                        alignment: Alignment.center,
                                        child: Text(
                                          tile.name.isEmpty
                                              ? ''
                                              : tile.name.substring(0, 1),
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 22,
                                          ),
                                        ))
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

  /// 书单网格滚动控制器：给「回到顶部」用。
  final ScrollController _listScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
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
                  controller: _listScroll,
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
      floatingActionButton: BackToTopFab(controller: _listScroll),
    );
  }
}