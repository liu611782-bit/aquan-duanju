import 'dart:async';

import 'package:flutter/material.dart';

import '../core/error_log.dart';
import '../core/search/query_intent.dart';
import '../core/search/search_fallback.dart';
import '../core/search/suggest_submit.dart';
import '../core/search_dimensions.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'media_hub_screen.dart';
import 'post_detail_screen.dart';

import '../widgets/voice_button.dart';
import '../widgets/loading.dart';

/// 搜索页：热搜首屏 → 输入时联想（300ms 防抖）→ 提交后结果流。
/// 结果流顶部提供内容筛选（综合/真人剧/漫剧/AI 剧），切筛选重新查询。
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery = ''});

  /// 传入时自动以此词发起搜索（详情页标签、AI 入口用）。
  final String initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

/// 内容筛选：value 是 openhongguo 搜索 filters 的取值。
const _searchFilters = <String, String>{
  '': '综合',
  'content_type_short_play': '真人剧',
  'content_type_dynamic_comic': '漫剧',
  'content_type_ai_dynamic_comic': 'AI 剧',
};

/// 「已识别：2024年 · 悬疑 · 评分≥9」提示条，右侧可一键忽略（按原文重搜）。
class _IntentBar extends StatelessWidget {
  const _IntentBar({required this.intent, required this.onClear});

  final QueryIntent intent;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '已识别：${intent.summary}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ),
          IconButton(
            tooltip: '忽略识别结果',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close, size: 16),
            onPressed: onClear,
          ),
        ],
      ),
    );
  }
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;

  HotSearch? _hot;
  List<Suggestion> _suggestions = const [];
  final _results = <SeriesSummary>[];
  String _cursor = '';
  bool _hasMore = false;

  /// 本次搜索解析出的结构化意图（给结果页顶部展示用）。
  QueryIntent? _intent;

  /// 原词空结果、按退化词出结果时的提示（「未找到 X，已按 Y 检索」）。
  String? _degradedNote;
  bool _searching = false;
  bool _loadingHot = true;
  Object? _error;
  String _submitted = '';
  String _filter = '';

  /// 内容（作品）/ 讨论（帖子）两个维度。
  SearchDimension _dimension = SearchDimension.content;

  /// 请求序号：维度/筛选连点时，只有最后一次请求的结果能落地。
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadHot();
    if (widget.initialQuery.trim().isNotEmpty) {
      _controller.text = widget.initialQuery;
      // 首帧后自动提交，让输入框的初始值走完整搜索流程。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _submit(widget.initialQuery);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _loadHot() async {
    try {
      final hot = await AppScope.read(context).api.hotSearch();
      if (!mounted) return;
      setState(() {
        _hot = hot;
        _loadingHot = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loadingHot = false;
      });
    }
  }

  /// 联想失败状态（只在翻转时记日志，防止逐字输入刷屏）。
  bool _suggestFailed = false;

  void _onChanged(String text) {
    _debounce?.cancel();
    if (text.trim().isEmpty) {
      setState(() => _suggestions = const []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final list = await AppScope.read(context).api.suggest(text.trim());
        if (!mounted) return;
        setState(() => _suggestions = list.take(10).toList());
        if (_suggestFailed) {
          _suggestFailed = false;
        }
      } catch (e, st) {
        // 联想消失曾经无解释（匿名配额满时 suggest 一并失败）。失败只记
        // 一次直到恢复；错误面板的「立即重置」是真正的解法。
        if (!_suggestFailed) {
          _suggestFailed = true;
          ErrorLog.instance.record('搜索联想', e, st);
        }
      }
    });
  }

  Future<void> _submit(String query) async {
    final raw = query.trim();
    if (raw.isEmpty) return;
    // 自然语言先拆意图：`2024年9分以上的悬疑剧` → 关键词「悬疑剧」。
    // 纯条件句（如「韩剧」）关键词会为空，此时用原文兜底，避免搜空。
    final intent = QueryIntent.parse(raw);
    // 条件下转成搜索词（服务端没有年份/评分独立筛选字段）。
    final terms = intent.searchTerms;
    final q = terms.isNotEmpty ? terms : raw;
    _focus.unfocus();
    final seq = ++_seq;
    // 异步间隙前取好引用，避免 BuildContext 跨 await。
    final scope = AppScope.read(context);
    // 历史记原文，方便用户原样复现。
    try {
      await scope.searches.record(raw);
    } catch (_) {}
    setState(() {
      _intent = intent;
      _submitted = q;
      _degradedNote = null;
      _searching = true;
      _results.clear();
      _suggestions = const [];
      _error = null;
    });
    try {
      // 两层兜底（根因见 search_fallback.dart 头注）：综合检索完整剧名
      // 可能只给衍生季不含本体（无精确命中 → 频道检索补充），也可能为空
      // （→ 去尾退化重试）；出补充/退化结果时提示实际检索口径。
      final outcome = await searchWithDegradedRetry(
        (term) => scope.api.search(term,
            tab: _dimension.tab,
            filters: _dimension.filtersFor(
                _filter.isEmpty ? const [] : [_filter])),
        q,
        // 频道补充：综合检索对完整剧名可能只给衍生季不含本体（实测
        // 「万妖图录传」本体在漫剧频道结果里），无精确命中时补一次。
        supplementary: _dimension.allowsFilters
            ? (term) => scope.api.search(term, filters: const ['comic'])
            : null,
        onError: (e, st) =>
            ErrorLog.instance.record('漫剧搜索', '退化重试失败（原词 $q）：$e', st),
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _results.addAll(outcome.page.items);
        _cursor = outcome.page.cursor;
        _hasMore = outcome.page.hasMore;
        // 翻页沿用实际命中的检索词，保证结果集一致。
        _submitted = outcome.query;
        _degradedNote = outcome.degraded
            ? '未找到「$q」，已按「${outcome.query}」检索'
            : outcome.supplemented
                ? '已并入频道检索结果'
                : null;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _error = e;
        _searching = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_searching || !_hasMore || _submitted.isEmpty) return;
    final seq = _seq;
    _searching = true;
    try {
      final page = await AppScope.read(context).api.search(
        _submitted,
        cursor: _cursor,
        // 服务端要求游标与筛选一起传，翻页沿用当前筛选。
        tab: _dimension.tab,
        filters:
            _dimension.filtersFor(_filter.isEmpty ? const [] : [_filter]),
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        // 服务端的翻页结果自带与上一页的重叠（与 ohg 分页语义一致），
        // 按 ID 去重后追加。
        final seen = {for (final r in _results) r.id};
        for (final item in page.items) {
          if (!seen.contains(item.id)) {
            seen.add(item.id);
            _results.add(item);
          }
        }
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      // 只有发起这一代请求的才能解锁，否则旧请求会把新一代的锁清掉。
      if (seq == _seq) _searching = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 8,
        title: TextField(
          controller: _controller,
          focusNode: _focus,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onChanged: _onChanged,
          onSubmitted: _submit,
          decoration: InputDecoration(
            hintText: '搜索短剧、演员',
            prefixIcon: const Icon(Icons.search),
            prefixIconColor: theme.colorScheme.outline,
            suffixIcon: VoiceSearchButton(
              onText: (text) {
                _controller.text = text;
                _submit(text);
              },
            ),
            isDense: true,
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(24),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_submitted.isNotEmpty) {
      if (_searching && _results.isEmpty) return const SkeletonGrid();
      if (_error != null) {
        return ErrorRetryView(error: _error!, onRetry: () => _submit(_submitted));
      }
      if (_results.isEmpty) {
        return LoadView(
          loading: false,
          error: null,
          onRetry: null,
          empty: true,
          emptyText: _dimension == SearchDimension.discussion
              ? '没有找到相关讨论'
              : '没有找到相关短剧',
          child: const SizedBox(),
        );
      }
      return Column(
        children: [
          _buildFilterBar(context),
          if (_intent != null && _intent!.summary.isNotEmpty)
            _IntentBar(
              intent: _intent!,
              onClear: () {
                final raw = _intent!.raw;
                setState(() => _intent = null);
                _submit(raw);
              },
            ),
          if (_degradedNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _degradedNote!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary),
                ),
              ),
            ),
          Expanded(
            child: _dimension == SearchDimension.discussion
                ? _buildDiscussionList(context)
                : SeriesGrid(
                    items: _results,
                    hasMore: _hasMore,
                    onLoadMore: _loadMore,
                    onTap: (item) => openDetail(context, item.id, item.title),
                  ),
          ),
        ],
      );
    }

    // 未提交：联想优先，否则热搜首屏。
    if (_suggestions.isNotEmpty) {
      return ListView.builder(
        itemCount: _suggestions.length,
        itemBuilder: (context, i) {
          final s = _suggestions[i];
          return ListTile(
            leading: const Icon(Icons.search, size: 20),
            title: Text(s.text, maxLines: 1, overflow: TextOverflow.ellipsis),
            onTap: () {
              _controller.text = s.text;
              // keyword 可能是内容 ID（纯数字，SDK 解析缺口，见
              // suggest_submit.dart）——把 ID 当搜索词服务端检索不到。
              _submit(suggestSubmitText(s));
            },
          );
        },
      );
    }

    if (_loadingHot) {
      return const SkeletonGrid(columns: 1);
    }
    if (_hot == null) {
      return ErrorRetryView(
          error: _error ?? StateError('hot search'), onRetry: _loadHot);
    }
    return _HotView(
      hot: _hot!,
      header: _historyHeader(context),
      // 话题属于社区：点话题直接看讨论，而不是作品搜索。
      onTopic: (q) {
        setState(() => _dimension = SearchDimension.discussion);
        _controller.text = q;
        _submit(q);
      },
      onSeries: (item) => openDetail(context, item.seriesId, item.title),
    );
  }

  /// 维度条 + 内容筛选行：内容维度可叠加筛选，讨论维度不显示筛选。
  Widget _buildFilterBar(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final dimension in SearchDimension.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(dimension.label),
                selected: _dimension == dimension,
                onSelected: (_) {
                  if (_dimension == dimension) return;
                  setState(() => _dimension = dimension);
                  // 维度变了，结果与游标都要重来。
                  if (_submitted.isNotEmpty) _submit(_submitted);
                },
              ),
            ),
          if (_dimension.allowsFilters) ...[
            const SizedBox(width: 8),
            for (final e in _searchFilters.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(e.value),
                  selected: _filter == e.key,
                  onSelected: (_) {
                    if (_filter == e.key) return;
                    setState(() => _filter = e.key);
                    _submit(_submitted);
                  },
                ),
              ),
            // 第三方源聚合搜索入口：跳影视聚合页并带上当前关键词。
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ActionChip(
                avatar: const Icon(Icons.video_library_outlined, size: 18),
                label: const Text('源'),
                tooltip: '在导入的影视源中搜索',
                onPressed: () {
                  Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MediaHubScreen(
                        initialQuery:
                            _submitted.isEmpty ? null : _submitted),
                  ));
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 讨论维度的结果列表：帖子没有封面（上游只有 post_id + title），用行式列表。
  Widget _buildDiscussionList(BuildContext context) {
    final theme = Theme.of(context);
    final itemCount = _results.length + (_hasMore ? 1 : 0);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: itemCount,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= _results.length) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _loadMore());
          return const Padding(
            padding: EdgeInsets.all(16),
            child: Center(
              child: AppLoading.inline(),
            ),
          );
        }
        final item = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: 48,
              height: 48,
              child: item.coverUrl.isEmpty
                  ? Icon(Icons.chat_bubble, color: theme.colorScheme.primary)
                  : CoverImage(url: item.coverUrl),
            ),
          ),
          title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: item.description.isEmpty
              ? null
              : Text(item.description, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: const Icon(Icons.chevron_right, size: 18),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                PostDetailScreen(postId: item.id, title: item.title),
          )),
        );
      },
    );
  }

  /// 搜索历史区：没有历史时不占位；单删 / 清空实时生效。
  List<Widget> _historyHeader(BuildContext context) {
    final store = AppScope.read(context).searches;
    if (store.queries.isEmpty) return const [];
    return [
      ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final queries = store.queries;
          if (queries.isEmpty) return const SizedBox.shrink();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(child: sectionTitle(context, '搜索历史')),
                  IconButton(
                    tooltip: '清空搜索历史',
                    icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                    onPressed: store.clear,
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final q in queries)
                    InputChip(
                      label: Text(q,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onPressed: () {
                        _controller.text = q;
                        _submit(q);
                      },
                      onDeleted: () => store.remove(q),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    ];
  }
}

class _HotView extends StatelessWidget {
  const _HotView({
    required this.hot,
    required this.onTopic,
    required this.onSeries,
    this.header = const [],
  });

  final HotSearch hot;

  /// 话题词 → 讨论维度搜索。
  final void Function(String) onTopic;
  final void Function(HotItem) onSeries;

  /// 插在热搜内容之前的区块（搜索历史）。
  final List<Widget> header;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final children = <Widget>[];
    if (hot.guesses.isNotEmpty) {
      children.add(sectionTitle(context, '猜你想搜'));
      children.add(Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final g in hot.guesses.take(8))
            ActionChip(
              label: Text(g.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => onSeries(g),
            ),
        ],
      ));
    }
    for (final board in hot.boards) {
      children.add(sectionTitle(context, board.name));
      if (board.topics.isNotEmpty) {
        children.add(Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final t in board.topics)
              ActionChip(
                label: Text('#${t.title}'),
                onPressed: () => onTopic(t.query),
              ),
          ],
        ));
      }
      if (board.items.isNotEmpty) {
        children.add(Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              for (final item in board.items)
                ListTile(
                  dense: true,
                  leading: SizedBox(
                    width: 28,
                    child: Text(
                      '${item.position}',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: item.position <= 3
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  title: Text(item.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: item.heat.isEmpty
                      ? null
                      : Text(item.heat, style: theme.textTheme.bodySmall),
                  trailing: item.tag.isEmpty
                      ? null
                      : Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(item.tag, style: theme.textTheme.bodySmall),
                        ),
                  onTap: () => onSeries(item),
                ),
            ],
          ),
        ));
      }
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        for (final w in [...header, ...children]) ...[w, const SizedBox(height: 16)],
      ],
    );
  }
}

Widget sectionTitle(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(text,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold)),
    );

/// 搜索页入口（发现页 / 主壳 AppBar 调用）；[query] 传入时自动搜索。
void showSearchScreen(BuildContext context, {String? query}) {
  Navigator.of(context).push(
    MaterialPageRoute(
        builder: (_) => SearchScreen(initialQuery: query ?? '')),
  );
}
