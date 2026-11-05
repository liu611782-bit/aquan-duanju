import 'package:flutter/material.dart';

import '../models/models.dart';
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

  late String _genre = widget.initialGenre;

  @override
  void initState() {
    super.initState();
    _loadPanel();
  }

  Future<void> _loadPanel() async {
    setState(() {
      _loadingPanel = true;
      _error = null;
    });
    try {
      final rows =
          await AppScope.read(context).api.shortFilterPanel(_genre);
      if (!mounted) return;
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
      if (!mounted) return;
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

  Future<void> _reloadResults() async {
    setState(() {
      _loadingResults = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context)
          .api
          .shortFilter(_asQuery());
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loadingResults = false;
      });
    } catch (e) {
      if (!mounted) return;
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
    _reloadResults();
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loadingResults) return;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context)
          .api
          .shortFilter(_asQuery(), cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
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
              ? ErrorRetryView(error: _error!, onRetry: _loadPanel)
              : Column(
                  children: [
                    // 筛选行。
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
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
                        onRetry: _reloadResults,
                        empty: _items.isEmpty,
                        emptyText: '没有符合筛选的短剧',
                        child: SeriesGrid(
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
    );
  }

  String _genreLabel(String genre) => switch (genre) {
        '' => '全部体裁',
        'comic_series' => '漫剧',
        'ai_series' => 'AI 剧',
        _ => '真人剧',
      };
}
