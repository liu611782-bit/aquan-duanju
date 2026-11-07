import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/sources/backend_dedupe.dart';
import '../core/sources/source_adapter_factory.dart';
import '../core/sources/search_orchestrator.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_probe.dart';
import '../core/sources/source_registry.dart';
import '../widgets/common.dart';
import '../widgets/voice_button.dart';
import 'bili_home_screen.dart';
import 'live_screen.dart';
import 'source_detail_screen.dart';
import 'source_manage_screen.dart';
import 'source_market_screen.dart';
import '../widgets/loading.dart';

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

  /// 每次冷启动只自动随机一次（用户在本次会话里手动选过的源不再覆盖）。
  static bool _homeRandomized = false;

  static final Random _random = Random();

  /// 空内容自动换源次数上限（对齐 TVBox `RANDOM_HOME_MAX_RETRY`）。
  static const int _maxReroll = 5;

  int _rerollCount = 0;
  final Set<String> _rerollTried = <String>{};

  String _currentSourceId = '';

  /// 搜索 Tab 的初始关键词（传给 _SearchTab，只消费一次）。
  String? _searchSeed;

  @override
  void initState() {
    super.initState();
    _searchSeed = widget.initialQuery;
    _tabs = TabController(
        length: 2, vsync: this, initialIndex: _searchSeed != null ? 1 : 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(_pickDefaultSource);
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// 启用源按「本轮测速 + 健康分」排序：源管理批量测速 back 回来，好源在前。
  List<SourceConfig> _rankedSources(AppScope scope) => sortSourcesForDisplay(
        scope.sources.enabled,
        scoreOf: (s) => scope.sourceHealth.scoreOf(s.id),
        latencyOf: (s) => scope.sourceHealth.latencyOf(s.id),
        probeOf: (s) => scope.sourceHealth.probeOf(s.id),
      );

  /// 直连采集站（不看爬虫源）：随机落点必须是首切就出内容的类型。
  List<SourceConfig> _directCandidates(List<SourceConfig> sources) {
    final direct = sources
        .where((s) =>
            (s.kind == SourceKind.cmsJson || s.kind == SourceKind.cmsXml) &&
            !s.pinned)
        .toList();
    if (direct.isNotEmpty) return direct;
    return sources
        .where((s) =>
            s.kind == SourceKind.cmsJson || s.kind == SourceKind.cmsXml)
        .toList();
  }

  SourceConfig? _randomOther(List<SourceConfig> pool, String excludeId) {
    final candidates =
        pool.where((s) => s.id != excludeId).toList(growable: false);
    if (candidates.isEmpty) return null;
    return candidates[_random.nextInt(candidates.length)];
  }

  /// 选默认源：冷启动首次进入随机一个直连源；之后保持用户/当前选择。
  void _pickDefaultSource() {
    final sources = _rankedSources(AppScope.read(context));
    if (sources.isEmpty) {
      _currentSourceId = '';
      return;
    }
    if (!_homeRandomized) {
      _homeRandomized = true;
      // 设置里关掉随机后按健康分顺序取第一个（保持原有「好源在前」语义）。
      if (!AppScope.read(context).settings.randomHomeSource) {
        _currentSourceId = sources.first.id;
        return;
      }
      final pool = _directCandidates(sources);
      final picked = _randomOther(pool, '') ?? pool.firstOrNull;
      _currentSourceId = picked?.id ?? sources.first.id;
      return;
    }
    if (sources.any((s) => s.id == _currentSourceId)) return;
    _currentSourceId = sources.first.id;
  }

  /// 功能栏「刷新」：立即随机换一个直连源。
  void _shuffleSource() {
    final sources = _rankedSources(AppScope.read(context));
    if (sources.isEmpty) return;
    final pool = _directCandidates(sources);
    final previous = _currentSourceId;
    final next = _randomOther(pool.isEmpty ? sources : pool, previous);
    if (next == null) {
      _snack('没有可随机切换的直连源');
      return;
    }
    setState(() {
      _currentSourceId = next.id;
      _rerollCount = 0;
      // 记住换走的那一个：紧接着的空内容自动换源不该又转回它。
      _rerollTried
        ..clear()
        ..add(previous);
    });
    _snack('已随机切换：${next.name}');
  }

  /// 选中源没有内容：自动换下一个（最多 [_maxReroll] 次）。
  void _handleEmptySource() {
    if (!AppScope.read(context).settings.randomHomeSource) return;
    if (_rerollCount >= _maxReroll) {
      _snack('当前源没有内容，可在上方手动切换');
      return;
    }
    final sources = _rankedSources(AppScope.read(context));
    final pool = _directCandidates(sources)
        .where((s) =>
            s.id != _currentSourceId && !_rerollTried.contains(s.id))
        .toList();
    if (pool.isEmpty) {
      _snack('没有其它可用的直连源');
      return;
    }
    final next = pool[_random.nextInt(pool.length)];
    setState(() {
      _rerollTried
        ..add(_currentSourceId)
        ..add(next.id);
      _rerollCount++;
      _currentSourceId = next.id;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _ensureCurrentSource() {
    final sources = _rankedSources(AppScope.read(context));
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
    final sources = _rankedSources(scope);
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
              if (!mounted) return;
              // 健康分/源列表可能已变：无条件重建，但保留用户已选的源。
              setState(_pickDefaultSource);
            },
          ),
          IconButton(
            tooltip: '源管理',
            icon: const Icon(Icons.tune),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceManageScreen()));
              if (!mounted) return;
              // 批量测速写的是健康分，回来必须重建才能看到新排序。
              setState(_pickDefaultSource);
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
            latencyOf: (s) => scope.sourceHealth.latencyOf(s.id),
            onSelect: (id) => setState(() => _currentSourceId = id),
            onShuffle: _shuffleSource,
          ),
          Expanded(
            child: sources.isEmpty
                ? _EmptySourcesView(onOpenMarket: () async {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const SourceMarketScreen()));
                    if (!mounted) return;
                    setState(_pickDefaultSource);
                  })
                : TabBarView(
                    controller: _tabs,
                    children: [
                      if (current == null)
                        const Center(child: Text('请选择一个源'))
                      else
                        _BrowseTab(
                          key: ValueKey(current.id),
                          source: current,
                          onEmpty: _handleEmptySource,
                        ),
                      _SearchTab(
                          key: const ValueKey('search'),
                          seedQuery: _searchSeed,
                          homeSourceId: current?.id ?? ''),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 源切换条：横滑 chip（按健康分排序，好源在前），末尾一个「管理」入口。
class _SourceChipBar extends StatelessWidget {
  const _SourceChipBar({
    required this.sources,
    required this.currentId,
    required this.latencyOf,
    required this.onSelect,
    required this.onShuffle,
  });

  final List<SourceConfig> sources;
  final String currentId;
  final int Function(SourceConfig config) latencyOf;
  final ValueChanged<String> onSelect;
  final VoidCallback onShuffle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 桌面端：常显滚动条 + 鼠标拖拽 + 滚轮转横向（源多时滚不到右侧的主诉）。
    return HorizontalScrollStrip(
      height: 52,
      children: [
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(Icons.settings_input_antenna_outlined,
                size: 18, color: theme.colorScheme.primary),
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
                size: 18, color: theme.colorScheme.primary),
            label: const Text('B 站'),
            tooltip: '哔哩哔哩（登录后推荐/搜索/番剧/弹幕）',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BiliHomeScreen()),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(Icons.refresh, size: 18, color: theme.colorScheme.primary),
            label: const Text('刷新'),
            tooltip: '随机换一个直连源',
            onPressed: onShuffle,
          ),
        ),
        for (final s in sources)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(
              label: _chipLabel(theme, s),
              selected: s.id == currentId,
              onSelected: (_) => onSelect(s.id),
            ),
          ),
      ],
    );
  }

  /// 名字 + 健康延迟：让「哪个源快」在条上直接可读。
  Widget _chipLabel(ThemeData theme, SourceConfig s) {
    final latency = latencyOf(s);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.shortDrama ? '${s.name} · 短剧' : s.name),
        if (latency > 0) ...[
          const SizedBox(width: 6),
          Text(
            '${latency}ms',
            style: TextStyle(
              fontSize: 10,
              color: switch (probeLevel(latency)) {
                ProbeLevel.fast => Colors.green,
                ProbeLevel.normal => Colors.orange,
                ProbeLevel.slow => theme.colorScheme.error,
              },
            ),
          ),
        ],
      ],
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
  const _BrowseTab({super.key, required this.source, this.onEmpty});

  final SourceConfig source;

  /// 首次加载后分类与列表都空（或直接报错）时回调：用于自动换源。
  final VoidCallback? onEmpty;

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
        // 保留用户已选分类（否则点分类后 _reload 又跳回第一个）。
        _categoryId = cats.isEmpty
            ? ''
            : (cats.any((c) => c.id == _categoryId) ? _categoryId : cats.first.id);
      });
      await _loadPage(reset: true);
      if (!mounted || seq != _seq) return;
      // 分类与列表都空：交给外层自动换下一个源（换源会重建本 widget）。
      if (_categories.isEmpty && _items.isEmpty) widget.onEmpty?.call();
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _error = e;
      });
      widget.onEmpty?.call();
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
          HorizontalScrollStrip(
            height: 44,
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
  const _SearchTab({super.key, this.seedQuery, this.homeSourceId = ''});

  final String? seedQuery;

  /// 当前主页源：同一后端有多个源时优先用它（TVBox 把 home 提到队首的语义）。
  final String homeSourceId;

  @override
  State<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<_SearchTab>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  final _groups = <SourceGroup>[];
  final _failedSources = <String, SourceExceptionCode>{};

  /// 各源的检索备注（如红果退化重试后的「已按 X 检索」），随失败源行展示。
  final _notices = <String, String>{};
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
    final settings = scope.settings;
    // 按后端去重：同一采集站被多份配置收录时只请求一次（设置可关）。
    final ordered = settings.dedupeBackendSearch
        ? dedupeByBackend(
            scope.sources.enabled,
            priorityId: widget.homeSourceId,
          )
        : scope.sources.enabled;
    final adapters = [
      for (final s in ordered) ?buildSourceAdapter(s),
    ];
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
      _notices.clear();
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
            if (event.notice.isNotEmpty) _notices[event.sourceName] = event.notice;
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
        : [
            for (final s in (scope.settings.dedupeBackendSearch
                ? dedupeByBackend(
                    scope.sources.enabled,
                    priorityId: widget.homeSourceId,
                  )
                : scope.sources.enabled))
              ?buildSourceAdapter(s),
          ];
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
                const AppLoading.inline(),
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
        if (_notices.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _notices.entries.map((e) => '${e.key}：${e.value}').join('；'),
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
                  ? const AppLoading.inline()
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
        groupHits: group.hits,
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
              child: AppLoading.inline());
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
