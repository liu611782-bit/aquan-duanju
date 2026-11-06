import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/back_to_top.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import 'filter_screen.dart';
import 'person_screen.dart';
import '../widgets/loading.dart';

/// 榜单页：shortRank 的内容 tab + 榜 tab + 榜单列表（分页）。
class RankingsScreen extends StatefulWidget {
  const RankingsScreen({super.key});

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen>
    with AutomaticKeepAliveClientMixin {
  List<RankContent> _contents = const [];
  String _contentId = '';
  String _boardId = '';
  final _items = <RankItem>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  /// 榜单列表滚动控制器：给「回到顶部」用。
  final ScrollController _listScroll = ScrollController();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _listScroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final first = await api.shortRank();
      if (!mounted) return;
      final contents = first.contents;
      final content = contents.firstWhere(
        (c) => c.selected,
        orElse: () => contents.isNotEmpty ? contents.first : const RankContent(),
      );
      final board = content.boards.firstWhere(
        (b) => b.selected,
        orElse: () => content.boards.isNotEmpty
            ? content.boards.first
            : const RankBoard(),
      );
      setState(() {
        _contents = contents;
        _contentId = content.id;
        _boardId = board.id;
        _items
          ..clear()
          ..addAll(first.items);
        _cursor = first.cursor;
        _hasMore = first.hasMore;
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

  Future<void> _switch(String content, String board) async {
    setState(() {
      _contentId = content;
      _boardId = board;
      _items.clear();
      _loading = true;
    });
    try {
      final page = await AppScope.read(context)
          .api
          .shortRank(content: content, board: board);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
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

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading) return;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context)
          .api
          .shortRank(content: _contentId, board: _boardId, cursor: _cursor);
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
    super.build(context);
    final theme = Theme.of(context);
    final content = _contents.where((c) => c.id == _contentId).firstOrNull;
    return Scaffold(
      appBar: AppBar(
        title: const Text('榜单'),
        actions: [
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: '筛选',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FilterScreen()),
            ),
          ),
        ],
      ),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _reload,
        empty: _items.isEmpty,
        child: Column(
          children: [
            // 内容 tab（全部/真人剧/漫剧……）
            if (_contents.isNotEmpty)
              SizedBox(
                height: 44,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final c in _contents)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(c.name),
                          selected: c.id == _contentId,
                          onSelected: (_) =>
                              _switch(c.id, c.boards.firstOrNull?.id ?? ''),
                        ),
                      ),
                  ],
                ),
              ),
            // 榜 tab（推荐榜/热播榜……）
            if (content != null && content.boards.length > 1)
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final b in content.boards)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: TextButton(
                          onPressed: () => _switch(_contentId, b.id),
                          child: Text(
                            b.name,
                            style: TextStyle(
                              color: b.id == _boardId
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                              fontWeight: b.id == _boardId
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: _listScroll,
                itemCount: _items.length + (_hasMore ? 1 : 0),
                itemBuilder: (context, i) {
                  if (i >= _items.length) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _loadMore());
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                          child: AppLoading.inline()),
                    );
                  }
                  final item = _items[i];
                  return _RankTile(item: item);
                },
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: BackToTopFab(controller: _listScroll),
    );
  }
}

class _RankTile extends StatelessWidget {
  const _RankTile({required this.item});

  final RankItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final change = item.change;
    final changeText = change == null
        ? null
        : switch (change.kind) {
            0 => '新',
            1 => '↑${change.places}',
            2 => '↓${change.places}',
            _ => '-',
          };
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: SizedBox(
        width: 56,
        child: Column(
          children: [
            Text(
              '${item.position > 0 ? item.position : item.rank}',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: item.position <= 3
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outline,
              ),
            ),
            if (changeText != null)
              Text(changeText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: change?.kind == 1
                        ? Colors.red
                        : change?.kind == 2
                            ? Colors.green
                            : theme.colorScheme.outline,
                  )),
          ],
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(item.title,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (item.promoted)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('推广',
                  style: TextStyle(
                      fontSize: 10, color: theme.colorScheme.outline)),
            ),
        ],
      ),
      subtitle: Text(
        [
          if (item.score.isNotEmpty) item.score,
          if (item.episodeCount > 0) '共${item.episodeCount}集',
          if (item.actor.isNotEmpty) item.actor,
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: SizedBox(
        width: 48,
        height: 68,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CoverImage(
              url: item.seriesId.isEmpty && item.avatarUrl.isNotEmpty
                  ? item.avatarUrl
                  : item.coverUrl),
        ),
      ),
      // 演员行的 seriesId 为空、user_id 指向人物主页；剧集行照常进详情。
      onTap: item.seriesId.isNotEmpty
          ? () => openDetail(context, item.seriesId, item.title)
          : item.userId.isNotEmpty
              ? () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => PersonScreen(
                      userId: item.userId,
                      name: item.actor,
                    ),
                  ))
              : null,
    );
  }
}
