import 'dart:async';

import 'package:flutter/material.dart';

import '../core/auto_retry.dart';
import '../core/error_log.dart';
import '../models/models.dart';
import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 短剧筛选页：shortFilterPanel 的行 → 单选 chips → shortFilter 结果流。
///
/// 服务端语义：每行（genre、主题、角色、年代、排序……）选一个值；缺省行=全部。
/// 任一变更都回到第一页重新拉取；cursor 携带已展示的剧，服务端会跳过。
class FilterScreen extends StatefulWidget {
  const FilterScreen({super.key, this.initialGenre = 'short_play'});

  /// 初始体裁：short_play 真人剧 / comic_series 漫剧 / ai_series AI 剧。
  final String initialGenre;

  @override
  State<FilterScreen> createState() => _FilterScreenState();
}

class _FilterScreenState extends State<FilterScreen> {
  List<FilterRow> _rows = const [];
  final Map<String, String> _selections = {};
  final _items = <SeriesSummary>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loadingPanel = true;
  bool _loadingResults = true;
  bool _loadingMore = false;
  Object? _error;

  /// 请求代际：只有最新一次请求的响应能落地，避免快速连点标签时旧响应
  /// 后到并覆盖新选择。面板与结果分开计数。
  int _panelSeq = 0;
  int _resultSeq = 0;

  /// 已经用掉的自动重试次数（手动重试会清零）。
  int _panelRetry = 0;
  int _resultRetry = 0;

  late String _genre = widget.initialGenre;

  /// 选择防抖：连点多个标签时只发最后一次请求。
  ///
  /// 匿名设备有服务端配额，一次连点能打出七八个请求，既浪费配额又容易触发
  /// `ANONYMOUS_LIMITED`。
  Timer? _selectDebounce;

  /// 结果网格的滚动控制器：给「回到顶部」用。
  final ScrollController _resultScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadPanel();
  }

  @override
  void dispose() {
    _selectDebounce?.cancel();
    _resultScroll.dispose();
    super.dispose();
  }

  Future<void> _loadPanel({bool resetRetry = true}) async {
    if (resetRetry) _panelRetry = 0;
    final seq = ++_panelSeq;
    setState(() {
      _loadingPanel = true;
      _error = null;
    });
    try {
      final rows =
          await AppScope.read(context).api.shortFilterPanel(_genre);
      if (!mounted || seq != _panelSeq) return;
      setState(() {
        _rows = rows;
        _selections.clear();
        // 空字符串 = 全部体裁（服务端 default scene）：不写入 genre，
        // 否则会发出空值筛选被 SDK 拒绝（empty value for short filter row）。
        if (_genre.isNotEmpty) _selections['genre'] = _genre;
        _loadingPanel = false;
      });
      await _reloadResults();
    } catch (e) {
      if (!mounted || seq != _panelSeq) return;
      // 面板失败时整页只剩错误页，自动重试比让用户手点更有价值；
      // 重试期间保持骨架（_loadingPanel 仍为 true）。
      final delay = worthAutoRetry(e) ? autoRetryDelay(_panelRetry) : null;
      if (delay != null) {
        _panelRetry++;
        await Future<void>.delayed(delay);
        if (!mounted || seq != _panelSeq) return;
        return _loadPanel(resetRetry: false);
      }
      ErrorLog.instance.record('筛选', '面板加载失败：$e', StackTrace.current);
      setState(() {
        _error = e;
        _loadingPanel = false;
      });
    }
  }

  Future<void> _switchGenre(String genre) async {
    setState(() => _genre = genre);
    await _loadPanel();
  }

  Future<void> _reloadResults({bool resetRetry = true}) async {
    if (resetRetry) _resultRetry = 0;
    final seq = ++_resultSeq;
    setState(() {
      _loadingResults = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context)
          .api
          .shortFilter(_asQuery());
      if (!mounted || seq != _resultSeq) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingResults = false;
      });
    } catch (e) {
      if (!mounted || seq != _resultSeq) return;
      final delay = worthAutoRetry(e) ? autoRetryDelay(_resultRetry) : null;
      if (delay != null) {
        _resultRetry++;
        await Future<void>.delayed(delay);
        if (!mounted || seq != _resultSeq) return;
        return _reloadResults(resetRetry: false);
      }
      ErrorLog.instance.record('筛选', '结果加载失败：$e', StackTrace.current);
      setState(() {
        _error = e;
        _loadingResults = false;
      });
    }
  }

  /// 服务端 selections 语义是「键 → 值列表」（可多选），UI 单选时每个键给单元素列表。
  Map<String, List<String>> _asQuery() => {
        for (final e in _selections.entries) e.key: [e.value],
      };

  void _select(String key, String value) {
    if (value.isEmpty) {
      _selections.remove(key);
    } else {
      _selections[key] = value;
    }
    // chip 选中态立即刷新，请求本身防抖：连点时只有最后一次真正发出。
    setState(() {});
    _selectDebounce?.cancel();
    _selectDebounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_reloadResults());
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadingResults) return;
    final seq = _resultSeq;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context)
          .api
          .shortFilter(_asQuery(), cursor: _cursor);
      // 期间换过筛选条件：这一页属于旧查询，不能追加。
      if (!mounted || seq != _resultSeq) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (e) {
      ErrorLog.instance.record('筛选', '加载更多失败：$e', StackTrace.current);
    } finally {
      _loadingMore = false;
    }
  }

  /// 一键换一台匿名设备再重拉。
  ///
  /// 这是「匿名访问上限 / 设备被拒」的正规恢复路径：限流不是靠重试能绕过的，
  /// 换设备后服务端会当作新访客重新计算配额。
  Future<void> _resetDeviceAndRetry() async {
    final api = AppScope.read(context).api;
    try {
      await api.resetDevice();
    } catch (e) {
      ErrorLog.instance.record('筛选', '重置设备失败：$e', StackTrace.current);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('重置设备失败，请稍后再试')));
      }
      return;
    }
    if (!mounted) return;
    _panelRetry = 0;
    _resultRetry = 0;
    await _loadPanel();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('筛选'),
        actions: [
          // 体裁切换：真人剧 / 漫剧 / AI 剧。
          PopupMenuButton<String>(
            initialValue: _genre,
            onSelected: _switchGenre,
            itemBuilder: (_) => const [
              PopupMenuItem(value: '', child: Text('全部体裁')),
              PopupMenuItem(value: 'short_play', child: Text('真人剧')),
              PopupMenuItem(value: 'comic_series', child: Text('漫剧')),
              PopupMenuItem(value: 'ai_series', child: Text('AI 剧')),
            ],
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_genreLabel(_genre)),
                  const Icon(Icons.arrow_drop_down),
                ]),
              ),
            ),
          ),
        ],
      ),
      body: _loadingPanel
          ? const SkeletonGrid(columns: 1)
          : _error != null && _rows.isEmpty
              ? ErrorRetryView(
                  error: _error!,
                  onRetry: () => _loadPanel(),
                  onResetDevice: deviceRecoverable(_error!)
                      ? () => _resetDeviceAndRetry()
                      : null,
                )
              : Column(
                  children: [
                    // 筛选行。
                    ConstrainedBox(
                      // minWidth 撑满：SingleChildScrollView 传给 child 的是松约束，
                      // Column 会 shrink-wrap 到最宽 chip 的宽度；chip 少的体裁
                      // （如漫剧）就塌成居中，与短剧的左对齐不一致。
                      constraints: const BoxConstraints(
                        maxHeight: 260,
                        minWidth: double.infinity,
                      ),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final row in _rows) ...[
                              Text(row.name,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              Wrap(
                                spacing: 8,
                                runSpacing: 6,
                                children: [
                                  // 每行都有「全部」：清掉该行条件（缺省行 = 全部）。
                                  // genre 行走体裁切换，避免页头标签与查询不一致。
                                  ChoiceChip(
                                    label: const Text('全部'),
                                    selected:
                                        !_selections.containsKey(row.key),
                                    onSelected: (_) => row.key == 'genre'
                                        ? _switchGenre('')
                                        : _select(row.key, ''),
                                  ),
                                  for (final opt in row.options)
                                    ChoiceChip(
                                      label: Text(opt.name),
                                      selected:
                                          _selections[row.key] == opt.value,
                                      onSelected: (_) => row.key == 'genre'
                                          ? _switchGenre(opt.value)
                                          : _select(row.key, opt.value),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const Divider(height: 1),
                    // 结果流。
                    Expanded(
                      child: LoadView(
                        loading: _loadingResults,
                        error: _error,
                        onRetry: () => _reloadResults(),
                        empty: _items.isEmpty,
                        emptyText: '没有符合筛选的短剧',
                        child: SeriesGrid(
                          controller: _resultScroll,
                          items: _items,
                          hasMore: _hasMore,
                          onLoadMore: _loadMore,
                          onTap: (item) =>
                              openDetail(context, item.id, item.title),
                        ),
                      ),
                    ),
                  ],
                ),
      floatingActionButton: BackToTopFab(controller: _resultScroll),
    );
  }

  String _genreLabel(String genre) => switch (genre) {
        '' => '全部体裁',
        'comic_series' => '漫剧',
        'ai_series' => 'AI 剧',
        _ => '真人剧',
      };
}
