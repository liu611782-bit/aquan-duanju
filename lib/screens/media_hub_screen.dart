import 'dart:async';

import 'package:flutter/material.dart';

import '../core/sources/source_adapter_factory.dart';
import '../core/sources/search_orchestrator.dart';
import '../core/sources/source_adapter.dart';
import '../widgets/common.dart';
import '../widgets/voice_button.dart';
import 'bili_home_screen.dart';
import 'live_screen.dart';
import 'source_detail_screen.dart';
import 'source_manage_screen.dart';
import 'source_market_screen.dart';

/// 影视聚合页：TVBox / CMS 源的分类浏览与聚合搜索（入口在发现页顶部）。
class MediaHubScreen extends StatefulWidget {
  const MediaHubScreen({super.key, this.initialQuery});

  /// 传入时自动切到搜索 Tab 并以此词发起搜索（搜索页「源」入口用）。
  final String? initialQuery;

  @override
  State<MediaHubScreen> createState() => _MediaHubScreenState();
}

class _MediaHubScreenState extends State<MediaHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  String _currentSourceId = '';

  /// 搜索 Tab 的初始关键词（传给 _SearchTab，只消费一次）。
  String? _searchSeed;

  @override
  void initState() {
    super.initState();
    _searchSeed = widget.initialQuery;
    _tabs = TabController(
        length: 2, vsync: this, initialIndex: _searchSeed != null ? 1 : 0);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pickDefaultSource());
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _pickDefaultSource() {
    final sources = AppScope.read(context).sources.enabled;
    if (sources.isEmpty) return;
    setState(() => _currentSourceId = sources.first.id);
  }

  void _ensureCurrentSource() {
    final sources = AppScope.read(context).sources.enabled;
    if (_currentSourceId.isEmpty ||
        !sources.any((s) => s.id == _currentSourceId)) {
      _currentSourceId = sources.isEmpty ? '' : sources.first.id;
    }
  }

  SourceConfig? get _currentSource {
    _ensureCurrentSource();
    if (_currentSourceId.isEmpty) return null;
    return AppScope.read(context).sources.byId(_currentSourceId);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final sources = scope.sources.enabled;
    _ensureCurrentSource();
    final current = _currentSource;
    return Scaffold(
      appBar: AppBar(
        title: const Text('影视聚合'),
        actions: [
          IconButton(
            tooltip: '源市场（自动抓源）',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceMarketScreen()));
              if (mounted) setState(() => _pickDefaultSource());
            },
          ),
          IconButton(
            tooltip: '源管理',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceManageScreen()));
              if (mounted) setState(() {});
            },
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '分类'), Tab(text: '搜索')],
        ),
      ),
      body: Column(
        children: [
          _SourceChipBar(
            sources: sources,
            currentId: current?.id ?? '',
            onSelect: (id) => setState(() => _currentSourceId = id),
          ),
          Expanded(
            child: sources.isEmpty
                ? _EmptySourcesView(onOpenMarket: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SourceMarketScreen()));
                    if (mounted) setState(() => _pickDefaultSource());
                  })
                : TabBarView(
                    controller: _tabs,
                    children: [
                      if (current == null)
                        const Center(child: Text('请选择一个源'))
                      else
                        _BrowseTab(key: ValueKey(current.id), source: current),
                      _SearchTab(
                          key: const ValueKey('search'),
                          seedQuery: _searchSeed),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 源切换条：横滑 chip，末尾一个「管理」入口。
class _SourceChipBar extends StatelessWidget {
  const _SourceChipBar({
    required this.sources,
    required this.currentId,
    required this.onSelect,
  });

  final List<SourceConfig> sources;
  final String currentId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              avatar: Icon(Icons.settings_input_antenna_outlined,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              label: const Text('直播'),
              tooltip: 'TVBox lives 直播频道',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LiveScreen()),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ActionChip(
              avatar: Icon(Icons.smart_display_outlined,
                  size: 18, color: Theme.of(context).colorScheme.primary),
              label: const Text('B 站'),
              tooltip: '哔哩哔哩（登录后推荐/搜索/番剧/弹幕）',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const BiliHomeScreen()),
              ),
            ),
          ),
          for (final s in sources)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(s.shortDrama ? '${s.name} · 短剧' : s.name),
                selected: s.id == currentId,
                onSelected: (_) => onSelect(s.id),
              ),
            ),
        ],
      ),
    );
  }
}

/// 没有任何源：引导去源市场。
class _EmptySourcesView extends StatelessWidget {
  const _EmptySourcesView({required this.onOpenMarket});

  final VoidCallback onOpenMarket;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.video_library_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('还没有导入任何影视源'),
          const SizedBox(height: 4),
          Text('源由你自行导入，App 不内置任何内容源',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onOpenMarket,
            icon: const Icon(Icons.storefront_outlined),
            label: const Text('打开源市场'),
          ),
        ],
      ),
    );
  }
}

/// 分类浏览：当前源的分类条 + 条目网格（分页加载）。
class _BrowseTab extends StatefulWidget {
  const _BrowseTab({super.key, required this.source});

  final SourceConfig source;

  @override
  State<_BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends State<_BrowseTab>
    with AutomaticKeepAliveClientMixin {
  late final SourceAdapter _adapter;

  final _categories = <SourceCategory>[];
  final _items = <UnifiedSeries>[];
  String _categoryId = '';
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _seq = 0;

  /// 跨页去重 + 整页重复终止（站点分页垃圾重复防护）。
  final SearchPageLedger _ledger = SearchPageLedger();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final adapter = buildSourceAdapter(widget.source);
    if (adapter == null) {
      _loading = false;
      _error = SourceException(
          SourceExceptionCode.importUnsupported, '该源需要 JVM 爬虫引擎');
    } else {
      _adapter = adapter;
      _reload();
    }
  }

  Future<void> _reload() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
      _items.clear();
      _page = 1;
      _hasMore = false;
      _ledger.reset();
    });
    try {
      final cats = await _adapter.categories();
      if (!mounted || seq != _seq) return;
      setState(() {
        _categories
          ..clear()
          ..addAll(cats);
        _categoryId = cats.isEmpty ? '' : cats.first.id;
      });
      await _loadPage(reset: true);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _loadPage({bool reset = false}) async {
    final seq = _seq;
    final page = reset ? 1 : _page;
    try {
      final result = await _adapter.list(
          categoryId: _categoryId.isEmpty ? null : _categoryId, page: page);
      if (!mounted || seq != _seq) return;
      final fresh = _ledger.accept(page, result.items);
      setState(() {
        if (reset) _items.clear();
        _items.addAll(fresh);
        _page = page + 1;
        _hasMore = result.hasMore && _ledger.wantsMore;
        _loading = false;
        _loadingMore = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (reset) _error = e;
      });
    }
  }

  void _loadMore() {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    _loadPage();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        if (_categories.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final c in _categories)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(c.name),
                      selected: c.id == _categoryId,
                      onSelected: (_) {
                        setState(() => _categoryId = c.id);
                        _reload();
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
            onRetry: _reload,
            empty: _items.isEmpty,
            emptyText: '该分类暂无内容',
            child: _SourceGrid(
              items: _items,
              hasMore: _hasMore,
              onLoadMore: _loadMore,
              headers: widget.source.headers,
              onTap: (series) => _openDetail(series),
            ),
          ),
        ),
      ],
    );
  }

  void _openDetail(UnifiedSeries series) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourceDetailScreen(
        source: widget.source,
        series: series,
        adapter: _adapter,
      ),
    ));
  }
}

/// 聚合搜索：跨启用源流式搜索，同名同年份合并分组。
class _SearchTab extends StatefulWidget {
  const _SearchTab({super.key, this.seedQuery});

  final String? seedQuery;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  final _groups = <SourceGroup>[];
  final _failedSources = <String, SourceExceptionCode>{};
  final _orchestrator = SearchOrchestrator();

  bool _searching = false;
  int _done = 0;
  int _total = 0;

  /// 已有回应的源 id：同一个源可能多次回包（分页），只算一次。
  final _responded = <String>{};
  int _seq = 0;
  CancelToken? _cancel;
  StreamSubscription<SearchEvent>? _sub;

  /// 各源是否还有下一页（「加载更多结果」页脚可见性）。
  final _hasMoreBySource = <String, bool>{};
  bool _loadingMore = false;
  String _lastQuery = '';
  List<SourceAdapter> _lastAdapters = const [];
  StreamSubscription<SearchEvent>? _moreSub;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.seedQuery != null && widget.seedQuery!.isNotEmpty) {
      _controller.text = widget.seedQuery!;
      WidgetsBinding.instance.addPostFrameCallback((_) => _search());
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _cancel?.cancel();
    _sub?.cancel();
    _moreSub?.cancel();
    super.dispose();
  }

  void _search() {
    final scope = AppScope.read(context);
    final adapters = [
      for (final s in scope.sources.enabled) ?buildSourceAdapter(s),
    ];
    final settings = scope.settings;
    final query = _controller.text.trim();
    if (query.isEmpty || adapters.isEmpty) return;

    _cancel?.cancel();
    _moreSub?.cancel();
    final cancel = _cancel = CancelToken();
    final seq = ++_seq;
    _lastQuery = query;
    _lastAdapters = adapters;
    setState(() {
      _groups.clear();
      _failedSources.clear();
      _hasMoreBySource.clear();
      _loadingMore = false;
      _searching = true;
      _done = 0;
      _responded.clear();
      _total = adapters.length;
    });
    _sub?.cancel();
    _sub = _orchestrator
        .search(
      query,
      adapters: adapters,
      parallelism: settings.searchParallelism,
      perSourceTimeout: Duration(milliseconds: settings.searchTimeoutMs),
      cancel: cancel,
    )
        .listen((event) {
      if (!mounted || seq != _seq) return;
      setState(() {
        switch (event) {
          case SourceResult():
            _mergeGroups(event);
            _responded.add(event.sourceId);
            _hasMoreBySource[event.sourceId] = event.hasMore;
            _done = _responded.length;
          case SourceFailedEvent():
            _failedSources[event.sourceName] = event.code;
            _responded.add(event.sourceId);
            _done = _responded.length;
          case SearchDoneEvent():
            _searching = false;
            _done = _total;
          case SearchStarted():
            break;
        }
      });
    });
  }

  /// 聚合续页：对还有下一页的源拉下一页，增量并入分组。
  ///
  /// 编排层已做去重/重复页终止/代际保护；这里只负责合并与页脚状态。
  void _loadMoreResults() {
    if (_searching || _loadingMore || _lastQuery.isEmpty) return;
    final scope = AppScope.read(context);
    final adapters = _lastAdapters.isNotEmpty
        ? _lastAdapters
        : [for (final s in scope.sources.enabled) ?buildSourceAdapter(s)];
    if (adapters.isEmpty) return;
    final seq = ++_seq;
    _moreSub?.cancel();
    setState(() => _loadingMore = true);
    _moreSub = _orchestrator
        .searchMore(
      _lastQuery,
      adapters: adapters,
      parallelism: scope.settings.searchParallelism,
      perSourceTimeout: Duration(milliseconds: scope.settings.searchTimeoutMs),
      cancel: _cancel,
    )
        .listen((event) {
      if (!mounted || seq != _seq) return;
      switch (event) {
        case SourceResult():
          _mergeGroups(event);
          _hasMoreBySource[event.sourceId] = event.hasMore;
        case SourceFailedEvent():
          // 续页失败不打断已有结果；页脚保留，可再次点击重试。
          break;
        case SearchDoneEvent():
          setState(() => _loadingMore = false);
        case SearchStarted():
          break;
      }
    });
  }

  void _mergeGroups(SourceResult result) {
    for (final series in result.items) {
      final key = '${series.normalizedTitle}@${series.year}';
      final existing = _groups.indexWhere((g) {
        final primaryKey =
            '${g.primary.normalizedTitle}@${g.primary.year}';
        return primaryKey == key;
      });
      if (existing >= 0) {
        _groups[existing].add(series);
      } else {
        _groups.add(SourceGroup()..add(series));
      }
    }
    _groups.sort((a, b) {
      if (a.sourceCount != b.sourceCount) {
        return b.sourceCount.compareTo(a.sourceCount);
      }
      return 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _controller,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索全部启用源',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  VoiceSearchButton(
                    onText: (text) {
                      _controller.text = text;
                      _search();
                    },
                  ),
                  IconButton(
                    tooltip: '搜索',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _search,
                  ),
                ],
              ),
              border: const OutlineInputBorder(),
            ),
          ),
        ),
        if (_searching)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('已响应 $_done/$_total 个源',
                    style: theme.textTheme.bodySmall),
                const Spacer(),
                TextButton(
                  onPressed: () => _cancel?.cancel(),
                  child: const Text('停止'),
                ),
              ],
            ),
          ),
        if (_failedSources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '失败源：${_failedSources.keys.join('、')}（不影响其他源）',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          ),
        if (!_searching && _hasMoreBySource.containsValue(true))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton.icon(
                      onPressed: _loadMoreResults,
                      icon: const Icon(Icons.expand_more, size: 18),
                      label: const Text('加载更多结果'),
                    ),
            ),
          ),
        Expanded(
          child: _groups.isEmpty && !_searching
              ? Center(
                  child: Text('输入关键词开始聚合搜索',
                      style: TextStyle(color: theme.colorScheme.outline)))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 24),
                  itemCount: _groups.length,
                  itemBuilder: (context, index) {
                    final group = _groups[index];
                    return ListTile(
                      leading: SourceCover(
                        url: group.coverUrl,
                        headers: group.primary.headers,
                        width: 42,
                      ),
                      title: Text(group.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          if (group.primary.year.isNotEmpty) group.primary.year,
                          if (group.primary.remarks.isNotEmpty)
                            group.primary.remarks,
                          '${group.sourceCount} 个源',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _openGroup(group),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void _openGroup(SourceGroup group) {
    final scope = AppScope.read(context);
    // 组内按健康分排序：健康分高的源排前面。
    group.sortBy((a, b) {
      final scoreA = a.sourceKey.isEmpty
          ? 0
          : scope.sourceHealth.scoreOf(a.sourceKey);
      final scoreB = b.sourceKey.isEmpty
          ? 0
          : scope.sourceHealth.scoreOf(b.sourceKey);
      return scoreB.compareTo(scoreA);
    });
    final primary = group.primary;
    final config = scope.sources.byId(primary.sourceKey);
    if (config == null) return;
    final adapter = buildSourceAdapter(config);
    if (adapter == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourceDetailScreen(
        source: config,
        series: primary,
        adapter: adapter,
      ),
    ));
  }
}

/// 第三方源封面：普通 JPEG 直连（带源级 Referer/UA），不走 Go 核心转码。
class SourceCover extends StatelessWidget {
  const SourceCover({
    super.key,
    required this.url,
    this.headers = const {},
    this.width,
    this.height,
    this.fit = BoxFit.cover,
  });

  final String url;
  final Map<String, String> headers;
  final double? width;
  final double? height;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final placeholder = Container(
      width: width,
      height: height,
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.movie_outlined, color: theme.colorScheme.outline),
    );
    if (url.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(
        url,
        width: width,
        height: height,
        fit: fit,
        headers: {
          if (!headers.containsKey('User-Agent'))
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
          ...headers,
        },
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

/// 统一内模条目网格：复用 SeriesGrid 的视觉（封面/标题/副行）。
class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.items,
    required this.onTap,
    required this.headers,
    this.hasMore = false,
    this.onLoadMore,
  });

  final List<UnifiedSeries> items;
  final void Function(UnifiedSeries series) onTap;
  final Map<String, String> headers;
  final bool hasMore;
  final VoidCallback? onLoadMore;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols =
        width >= 1100 ? 6 : width >= 800 ? 4 : width >= 560 ? 3 : 2;
    final childCount =
        items.length + (hasMore && onLoadMore != null ? cols : 0);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.62,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: childCount,
      itemBuilder: (context, index) {
        if (index >= items.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) => onLoadMore!());
          return const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final item = items[index];
        final theme = Theme.of(context);
        return InkWell(
          onTap: () => onTap(item),
          borderRadius: BorderRadius.circular(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SourceCover(
                  url: item.coverUrl,
                  headers: headers,
                  fit: BoxFit.cover,
                  width: double.infinity,
                ),
              ),
              const SizedBox(height: 6),
              Text(item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                item.remarks.isEmpty ? item.year : item.remarks,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        );
      },
    );
  }
}
