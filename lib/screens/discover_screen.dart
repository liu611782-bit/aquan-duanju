import 'package:flutter/material.dart';

import '../core/aqua_error.dart';
import '../core/discover_channels.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/reading_rail.dart';
import 'book_aggregation_screen.dart';
import 'book_category_screen.dart';
import 'book_detail_screen.dart';
import 'community_screen.dart';
import 'detail_screen.dart';
import 'filter_screen.dart';
import 'media_hub_screen.dart';
import 'releases_screen.dart';
import 'search_screen.dart';
import 'venera_manga_screen.dart';

/// 发现页：内容类型条 + 类型内频道条 + 多列网格（分页加载）。
///
/// 两级导航：
/// - 一级 [kContentTypes] 常驻在滚动区之外，加载/错误态下也能换类型；
/// - 二级只在当前类型的频道数 > 1 时出现（目前只有短剧有 4 个）。
/// 频道的数据源（书城频道 / 短剧榜单）由 `lib/core/discover_channels.dart`
/// 的 [DiscoverChannel.source] 决定。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with AutomaticKeepAliveClientMixin {
  final _items = <SeriesSummary>[];
  final _badges = <String, String>{};

  /// [channelKey] → (榜单内容 id, 榜单 id)。榜单目录由服务端下发，选定一次就
  /// 固定；翻页必须带同一组值，否则游标无法续接。
  final _rankTargets = <String, ({String content, String board})>{};

  /// 类型名 → 该类型上次选中的频道，切走再切回不重置。
  final _lastChannelByType = <String, DiscoverChannel>{};

  ContentType _type = kDefaultContentType;
  DiscoverChannel _channel = kDefaultChannel;

  String _cursor = '';
  bool _hasMore = false;

  /// 已展示过的条目 id：服务端游标边界重复时不再追加。
  final Set<String> _seenIds = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  /// 每次加载自增，只有最新一次的结果能落地：连续切类型/频道时先发起的响应
  /// 不会覆盖后发起的那次。
  int _seq = 0;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload({bool allowFallback = true}) async {
    final seq = ++_seq;
    final type = _type;
    final channel = _channel;
    setState(() {
      _loading = true;
      _error = null;
      // 换类型时上一个类型的触底请求还在飞，别让它挡住新类型的加载更多。
      _loadingMore = false;
    });
    try {
      final page = await _fetchPage(type, channel, '');
      if (!mounted || seq != _seq) return;
      setState(() {
        _seenIds.clear();
        _items
          ..clear()
          ..addAll(_dedupe(page.items));
        _badges
          ..clear()
          ..addAll(page.badges);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // 榜单降级提示只在这次结果真正落地时弹，避免切走后弹出过期提示。
      final notice = page.notice;
      if (notice != null) _snack(notice);
    } catch (e) {
      if (!mounted || seq != _seq) return;
      if (channel.source == DiscoverSource.ranking) {
        // 榜单目录可能已被服务端下线：丢掉缓存，下次进入重新解析榜名，
        // 否则本会话会一直拿着失效的 board id 失败。
        _rankTargets.remove(channelKey(type, channel));
      }
      if (allowFallback && !(type == kDefaultContentType &&
          channel == kDefaultChannel)) {
        // 非默认组合拉不动时退回短剧/推荐，不让用户停在错误页。
        // 同时忘掉这个类型上次选的频道，避免下次切回来又自动选中失败的频道。
        _lastChannelByType.remove(type.name);
        _lastChannelByType[kDefaultContentType.name] = kDefaultChannel;
        setState(() {
          _type = kDefaultContentType;
          _channel = kDefaultChannel;
        });
        _snack('${_friendly(e)}，已切回推荐');
        await _reload(allowFallback: false);
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore || _loading || _error != null) return;
    final seq = _seq;
    final type = _type;
    final channel = _channel;
    _loadingMore = true;
    try {
      final page = await _fetchPage(type, channel, _cursor);
      if (!mounted || seq != _seq) return;
      final fresh = _dedupe(page.items);
      setState(() {
        if (fresh.isEmpty && page.items.isNotEmpty) {
          // 整页都是已展示过的条目：游标没前进，判定到底，别再空转。
          _hasMore = false;
        } else {
          _items.addAll(fresh);
          _hasMore = page.hasMore;
        }
        _badges.addAll(page.badges);
        _cursor = page.cursor;
      });
    } catch (_) {
      // 触底加载失败静默，下次触底再试。榜单目录可能已失效，丢掉缓存让
      // 下拉刷新/切回时重新解析榜名，不要整会话沿用旧 board id。
      if (channel.source == DiscoverSource.ranking) {
        _rankTargets.remove(channelKey(type, channel));
      }
    } finally {
      // 只有这一代请求才有资格解锁：被切类型顶掉的旧请求不能把新请求的
      // 翻页锁清掉，否则会重复追加同一页。
      if (seq == _seq) _loadingMore = false;
    }
  }

  /// 过滤掉已经展示过的条目（保持首次出现顺序）。
  List<SeriesSummary> _dedupe(List<SeriesSummary> items) {
    final out = <SeriesSummary>[];
    for (final item in items) {
      if (item.id.isEmpty) {
        out.add(item);
        continue;
      }
      if (_seenIds.add(item.id)) out.add(item);
    }
    return out;
  }

  /// 按频道来源取一页，两个数据源都归一化成 [_ChannelPage]。
  Future<_ChannelPage> _fetchPage(
      ContentType type, DiscoverChannel channel, String cursor) async {
    final api = AppScope.read(context).api;
    if (channel.source == DiscoverSource.feed) {
      final page = await api.discover(channel: channel.value, cursor: cursor);
      return _ChannelPage(
        items: page.items,
        cursor: page.cursor,
        hasMore: page.hasMore,
      );
    }

    final key = channelKey(type, channel);
    final target = _rankTargets[key];
    var ranking = await api.shortRank(
      content: target?.content ?? kShortRankContentAll,
      board: target?.board ?? '',
      cursor: cursor,
    );
    String? notice;
    // 只有首页（无游标）才解析榜单目录：翻页必须沿用游标里的榜单，否则会把
    // 第一页再追加一次。
    if (target == null && cursor.isEmpty) {
      // 第一次进入这个频道：用服务端下发的目录选榜。
      final content = primaryRankContent(ranking.contents);
      final boards = content?.boards ?? const <RankBoard>[];
      final matched = matchBoard(boards, channel.boardKeywords);
      final board = matched ?? defaultBoard(boards);
      final contentId = content?.id ?? kShortRankContentAll;
      if (board == null) {
        // 目录缺失时直接展示服务端默认榜，翻页仍可续接游标。
        return _ChannelPage(
          items: rankItemsToSummaries(ranking.items),
          badges: rankBadges(ranking.items),
          cursor: ranking.cursor,
          hasMore: ranking.hasMore,
        );
      }
      _rankTargets[key] = (content: contentId, board: board.id);
      if (matched == null && channel.boardKeywords.isNotEmpty) {
        notice = '当前榜单暂无「${channel.name}」榜，已展示默认榜';
      }
      if (ranking.board != board.id) {
        // 首屏给的是默认榜，换成匹配到的榜重拉第一页。
        ranking = await api.shortRank(content: contentId, board: board.id);
      }
    }
    return _ChannelPage(
      items: rankItemsToSummaries(ranking.items),
      badges: rankBadges(ranking.items),
      notice: notice,
      cursor: ranking.cursor,
      hasMore: ranking.hasMore,
    );
  }

  void _selectType(ContentType type) {
    if (_type == type) return;
    _lastChannelByType[_type.name] = _channel;
    setState(() {
      _type = type;
      _channel = _lastChannelByType[type.name] ?? type.channels.first;
    });
    _reload();
  }

  void _selectChannel(DiscoverChannel channel) {
    if (_channel == channel) return;
    _lastChannelByType[_type.name] = channel;
    setState(() => _channel = channel);
    _reload();
  }

  void _open(SeriesSummary item) {
    switch (_type.kind) {
      case ContentKind.video:
        openDetail(context, item.id, item.title);
      case ContentKind.community:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => const CommunityScreen(),
        ));
      case ContentKind.book:
      case ContentKind.manga:
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BookDetailScreen(
            bookId: item.id,
            title: item.title,
            coverUrl: item.coverUrl,
            manga: _type.kind == ContentKind.manga,
          ),
        ));
    }
  }

  String _friendly(Object error) =>
      error is AquaException ? error.friendlyText : '出了点小问题';

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// 统一 IA：每个 tag 两张入口卡——「XX聚合」+「按分类找XX」。
  /// 影视三 tab 共用影视聚合（TVBox 源内容覆盖短剧/漫剧/电影）。
  List<Widget> _entriesFor(ContentType type) {
    Widget card(IconData icon, String title, String subtitle, VoidCallback onTap) =>
        _EntryCard(icon: icon, title: title, subtitle: subtitle, onTap: onTap);
    switch (type.name) {
      case '短剧':
      case '漫剧':
      case '电影':
        final genre = switch (type.name) {
          '短剧' => 'short_play',
          '漫剧' => 'comic_series',
          _ => 'movie',
        };
        return [
          card(Icons.live_tv, '影视聚合', 'TVBox / 采集站源聚合搜索与观看',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const MediaHubScreen()))),
          card(Icons.category_outlined, '按分类找${type.name}',
              '体裁、年代、主题、排序筛选',
              () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => FilterScreen(initialGenre: genre)))),
        ];
      case '小说':
        return [
          card(Icons.auto_stories, '小说聚合',
              'legado 书源聚合搜索与阅读（导入书源后可用）',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BookAggregationScreen()))),
          card(Icons.category_outlined, '按分类找书', '玄幻、言情、都市、悬疑……',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const BookCategoryScreen()))),
        ];
      case '漫画':
        return [
          card(Icons.auto_stories, '漫画聚合',
              '多漫画源浏览与阅读（拷贝/包子/漫画柜…可切换）',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VeneraMangaScreen()))),
          card(Icons.category_outlined, '按分类找漫画',
              '源内分类：恋爱、古风、悬疑、生活……',
              () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const VeneraMangaScreen()))),
        ];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        actions: [
          IconButton(
            icon: const Icon(Icons.event),
            tooltip: '上新',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ReleasesScreen()),
            ),
          ),
          IconButton(
            tooltip: '社区',
            icon: const Icon(Icons.chat_bubble),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const CommunityScreen(),
            )),
          ),
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () => showSearchScreen(context),
          ),
        ],
      ),
      body: Column(
        children: [
          // 固定不滚动：骨架屏/错误页时类型条仍然可用。
          _ContentTypeBar(selected: _type, onSelect: _selectType),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _reload,
              empty: _items.isEmpty,
              // 能力未接入的类型，空态直接说清楚原因。
              emptyText:
                  _type.notice.isNotEmpty ? _type.notice : '${_type.name}暂无内容',
              child: RefreshIndicator(
                onRefresh: _reload,
                child: CustomScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // 统一 IA：每个 tag 两张入口卡——「XX聚合」+「按分类找XX」。
                    for (final entry in _entriesFor(_type))
                      SliverToBoxAdapter(child: entry),
                    // 继续观看只在影视类 tab；「最近在读」按小说/漫画分域
                    // （各 tag 的历史记录互不混排）。
                    if (_type.kind == ContentKind.video)
                      const SliverToBoxAdapter(child: _ContinueRail()),
                    if (_type.kind == ContentKind.book)
                      const SliverToBoxAdapter(child: ReadingRail(manga: false)),
                    if (_type.kind == ContentKind.manga)
                      const SliverToBoxAdapter(child: ReadingRail(manga: true)),
                    if (_type.channels.length > 1)
                      SliverToBoxAdapter(
                        child: _ChannelBar(
                          type: _type,
                          selected: _channel,
                          onSelect: _selectChannel,
                        ),
                      ),
                    if (_type.notice.isNotEmpty)
                      SliverToBoxAdapter(child: _NoticeBar(text: _type.notice)),
                    SliverFillRemaining(
                      hasScrollBody: true,
                      child: SeriesGrid(
                        items: _items,
                        hasMore: _hasMore,
                        onLoadMore: _loadMore,
                        badgeOf: (item) => _badges[item.id],
                        onTap: _open,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 统一入口卡：发现页每个 tag 的「XX聚合」/「按分类找XX」共用这一张卡。
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: theme.textTheme.titleMedium),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ContentTypeBar extends StatelessWidget {
  const _ContentTypeBar({required this.selected, required this.onSelect});

  final ContentType selected;
  final ValueChanged<ContentType> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 底色交给 Material：InkWell 的水波纹画在 Material 上，用不透明 Container
    // 当底会把波纹盖掉。
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        height: 48,
        decoration: BoxDecoration(
          border: Border(
            bottom:
                BorderSide(color: theme.colorScheme.surfaceContainerHighest),
          ),
        ),
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [
            for (final type in kContentTypes)
              _TypeTab(
                type: type,
                selected: type == selected,
                onTap: () => onSelect(type),
              ),
          ],
        ),
      ),
    );
  }
}

class _TypeTab extends StatelessWidget {
  const _TypeTab({
    required this.type,
    required this.selected,
    required this.onTap,
  });

  final ContentType type;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = selected
        ? theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.outline);
    return Semantics(
      selected: selected,
      button: true,
      label: type.name,
      onTap: onTap, // excludeSemantics 会丢掉子树的点击动作，这里显式补上。
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    type.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 150),
                width: selected ? 20 : 0,
                height: 3,
                decoration: BoxDecoration(
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 二级：当前类型下的频道。只有 `channels.length > 1` 时才挂载。
class _ChannelBar extends StatelessWidget {
  const _ChannelBar({
    required this.type,
    required this.selected,
    required this.onSelect,
  });

  final ContentType type;
  final DiscoverChannel selected;
  final ValueChanged<DiscoverChannel> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final channel in type.channels)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(channel.name),
                selected: channel == selected,
                onSelected: (_) => onSelect(channel),
              ),
            ),
        ],
      ),
    );
  }
}

/// 能力尚未接入的类型在列表顶部的说明条。
class _NoticeBar extends StatelessWidget {
  const _NoticeBar({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个频道当前页的归一化结果：书城频道没有名次，榜单频道有名次。
class _ChannelPage {
  const _ChannelPage({
    required this.items,
    this.badges = const {},
    this.notice,
    this.cursor = '',
    this.hasMore = false,
  });

  final List<SeriesSummary> items;
  final Map<String, String> badges;

  /// 这次结果的轻提示（如榜单降级），由调用方在结果落地时弹出。
  final String? notice;
  final String cursor;
  final bool hasMore;
}

/// 「继续观看」：最近没看完的剧横排，点了直接续播到上次那一集那一秒。
/// 「继续观看」：最近没看完的剧横排，点了直接续播到上次那一集那一秒。
/// 看完的（finished）不出现；看完入口在「我的 → 观看历史」。
class _ContinueRail extends StatelessWidget {
  const _ContinueRail();

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.read(context);
    return ListenableBuilder(
      listenable: scope.history,
      builder: (context, _) {
        // position==0 也算：用户显式跳集的「意图记录」（history-jump-episode）
        // 落盘时就在 0 秒，过滤掉会让这部剧从「继续观看」里整个消失。
        final entries = scope.history.entries
            .where((e) => !e.finished)
            .take(10)
            .toList();
        if (entries.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text('继续观看',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 172,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  children: [
                    for (final e in entries) _ContinueCard(entry: e),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry});

  final HistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => DetailScreen(
          seriesId: entry.seriesId,
          title: entry.title,
          autoplay: true,
        ),
      )),
      child: SizedBox(
        width: 104,
        child: Padding(
          padding: const EdgeInsets.only(right: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: SizedBox(
                      width: 104,
                      height: 140,
                      child: CoverImage(url: entry.coverUrl),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        entry.episodes > 0
                            ? '第${entry.episode}/${entry.episodes}集'
                            : '第${entry.episode}集',
                        style: const TextStyle(
                            color: Colors.white, fontSize: 10),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(entry.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}