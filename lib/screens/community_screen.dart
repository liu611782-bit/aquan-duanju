import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'post_detail_screen.dart';
import '../widgets/loading.dart';

/// 社区：热点话题榜 → 用话题词搜「讨论」→ 帖子列表。
///
/// 上游没有无关键词的广场 feed，所以入口只能是「话题」或用户自己搜的词。
class CommunityScreen extends StatefulWidget {
  const CommunityScreen({super.key});

  @override
  State<CommunityScreen> createState() => _CommunityScreenState();
}

class _CommunityScreenState extends State<CommunityScreen> {
  final _controller = TextEditingController();
  final _items = <SeriesSummary>[];

  List<HotTopic> _topics = const [];
  String _query = '';
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _loadTopics();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadTopics() async {
    try {
      final hot = await AppScope.read(context).api.hotSearch();
      if (!mounted) return;
      final topics = <HotTopic>[
        for (final board in hot.boards) ...board.topics,
      ];
      // 兜底词：话题榜为空时也能出内容。
      final query = topics.isNotEmpty ? topics.first.query : '书荒';
      setState(() {
        _topics = topics;
        _query = query;
        _controller.text = query;
      });
      await _reload();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _query = '书荒';
        _controller.text = '书荒';
      });
      await _reload();
    }
  }

  Future<void> _reload() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await AppScope.read(context)
          .api
          .search(_query, tab: '讨论', cursor: '');
      if (!mounted || seq != _seq) return;
      setState(() {
        _items
          ..clear()
          ..addAll(page.items);
        _cursor = page.cursor;
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
      final page = await AppScope.read(context)
          .api
          .search(_query, tab: '讨论', cursor: _cursor);
      if (!mounted || seq != _seq) return;
      setState(() {
        _items.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
      // 触底失败静默。
    } finally {
      _loadingMore = false;
    }
  }

  void _submit(String value) {
    final query = value.trim();
    if (query.isEmpty || query == _query) return;
    setState(() => _query = query);
    _reload();
  }

  void _pickTopic(HotTopic topic) {
    if (topic.query.isEmpty || topic.query == _query) return;
    setState(() {
      _query = topic.query;
      _controller.text = topic.query;
    });
    _reload();
  }

  void _open(SeriesSummary item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PostDetailScreen(postId: item.id, title: item.title),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('社区')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _controller,
              textInputAction: TextInputAction.search,
              onSubmitted: _submit,
              decoration: InputDecoration(
                hintText: '搜你想聊的话题',
                prefixIcon: const Icon(Icons.tag, size: 20),
                isDense: true,
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
          if (_topics.isNotEmpty)
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final topic in _topics)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(topic.title.isEmpty ? topic.query : topic.title),
                        selected: topic.query == _query,
                        onSelected: (_) => _pickTopic(topic),
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
              emptyText: '换个话题词试试',
              child: RefreshIndicator(
                onRefresh: _reload,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  itemCount: _items.length + (_hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
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
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: item.coverUrl.isEmpty
                              ? const Icon(Icons.chat_bubble)
                              : CoverImage(url: item.coverUrl),
                        ),
                      ),
                      subtitle: item.description.isEmpty
                          ? null
                          : Text(item.description,
                              maxLines: 2, overflow: TextOverflow.ellipsis),
                      title: Text(item.title,
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: const Icon(Icons.chevron_right, size: 18),
                      onTap: () => _open(item),
                    );
                  },
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _loading
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
                child: Text(
                  '当前话题：$_query · 共 ${_items.length} 条',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            ),
    );
  }
}
