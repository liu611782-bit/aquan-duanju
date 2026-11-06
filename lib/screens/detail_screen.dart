import 'dart:async';

import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/season_number.dart';
import '../models/models.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/back_to_top.dart';
import '../widgets/download_sheet.dart';
import '../widgets/skeleton.dart';
import '../widgets/tv_scope.dart';
import 'player_screen.dart';
import 'search_screen.dart';

/// 详情页：封面头部 + 操作行 + 剧集网格 + 相关推荐。
class DetailScreen extends StatefulWidget {
  const DetailScreen({
    super.key,
    required this.seriesId,
    this.title = '',
    this.autoplay = false,
    this.startEpisode = 0,
  });

  final String seriesId;
  final String title;

  /// AI / 命令行要求「直接开播」时置真：详情加载完立刻进播放器，
  /// 有观看历史就从上次那一集那一秒续播。
  final bool autoplay;

  /// 配合 autoplay：从指定集数开播（AI「看第 N 集」），0 表示智能续播。
  final int startEpisode;

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  Series? _series;
  final _episodes = <Episode>[];
  String _episodeCursor = '';
  bool _episodeHasMore = false;
  Recommend? _recommend;
  bool _loading = true;
  bool _loadingMoreEpisodes = false;
  Object? _error;
  bool _descExpanded = false;
  Album? _album;
  bool _didAutoplay = false;

  /// 同名搜索结果（标题去自身去重后的条目）；null = 未加载/加载中。
  List<SeriesSummary>? _sameName;

  /// 详情页主滚动控制器：给「回到顶部」用。
  final ScrollController _pageScroll = ScrollController();

  /// 标题含「第X季/部」「合集」记号的结果 → 同名系列；其余 → 同名单剧。
  static final RegExp _seasonMark =
      RegExp(r'第\s*[0-9一二三四五六七八九十]+\s*[季部]|[（(]\s*第?[0-9一二三四五六七八九十]+\s*[季部]\s*[)）]|合集');

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _pageScroll.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final scope = AppScope.read(context);
      final api = scope.api;
      final series = await api.getSeries(widget.seriesId);
      final epPage = await api.listEpisodes(widget.seriesId);
      Recommend? recommend;
      try {
        recommend = await api.seriesRecommend(widget.seriesId);
      } catch (_) {/* 相关推荐失败不打断详情 */}
      Album? album;
      if (series.isMultiSeason && series.relatedAlbumId.isNotEmpty) {
        try {
          album = await api.seasons(widget.seriesId);
        } catch (_) {}
      }
      await scope.history.ensureLoaded();
      await scope.follows.ensureLoaded();
      if (!mounted) return;
      // 追剧的剧打开过详情即视为已看到更新，追平记录并清除提醒。
      await scope.follows.ackUpdate(widget.seriesId, series.episodeCount);
      setState(() {
        _series = series;
        _episodes
          ..clear()
          ..addAll(epPage.items);
        _episodeCursor = epPage.cursor;
        _episodeHasMore = epPage.hasMore;
        _recommend = recommend;
        _album = album;
        _loading = false;
      });
      // 同名系列不阻塞详情首帧：失败静默（入口随之隐藏）。
      unawaited(_loadSameName(series.title));
      if (widget.autoplay && !_didAutoplay && _episodes.isNotEmpty) {
        _didAutoplay = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          var (ep, start) = _resumeTarget();
          if (widget.startEpisode > 0) {
            final idx =
                _episodes.indexWhere((e) => e.number == widget.startEpisode);
            if (idx >= 0) {
              ep = _episodes[idx];
              start = Duration.zero;
            }
          }
          _play(ep, start);
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMoreEpisodes() async {
    if (_loadingMoreEpisodes || !_episodeHasMore) return;
    _loadingMoreEpisodes = true;
    try {
      final page = await AppScope.read(context)
          .api
          .listEpisodes(widget.seriesId, cursor: _episodeCursor);
      if (!mounted) return;
      setState(() {
        _episodes.addAll(page.items);
        _episodeCursor = page.cursor;
        _episodeHasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMoreEpisodes = false;
    }
  }

  /// 从哪一集开始播：有历史且未看完则续播。
  ///
  /// 集数一律跟历史走（含 position==0 的「用户显式跳集」意图记录）；
  /// 位置太小时从该集开头，而不是退回第 1 集。
  (Episode, Duration) _resumeTarget() {
    final scope = AppScope.read(context);
    final h = scope.history.get(widget.seriesId);
    if (h != null && !h.finished) {
      Episode target;
      try {
        target = _episodes.firstWhere((e) => e.number == h.episode);
      } catch (_) {
        target = _episodes.first;
      }
      if (h.position > 5) {
        return (target, Duration(seconds: h.position.floor()));
      }
      return (target, Duration.zero);
    }
    return (_episodes.first, Duration.zero);
  }

  void _play(Episode ep, Duration start) {
    final series = _series;
    if (series == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlayerScreen(
        series: series,
        episodes: _episodes,
        startIndex: _episodes.indexOf(ep),
        startAt: start,
      ),
    ));
  }

  /// 电视横屏才分栏：竖屏/手机仍然走单列，避免信息被挤成两窄条。
  bool _isTvSplit(BuildContext context) {
    if (!TvScope.isTvOf(context)) return false;
    final size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  Widget _buildTvSplit(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 4,
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    BackButton(onPressed: () => Navigator.pop(context)),
                    Expanded(
                      child: Text(
                        _series?.title ?? widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                _header(context),
                _sameNameSection(context),
                if (_recommend != null && _recommend!.items.isNotEmpty)
                  _recommendSection(context),
              ],
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          flex: 6,
          child: CustomScrollView(
            controller: _pageScroll,
            slivers: [
              SliverToBoxAdapter(child: _episodeSection(context)),
              if (_album != null && _album!.seasons.length > 1)
                SliverToBoxAdapter(child: _seasonsSection(context)),
              const SliverToBoxAdapter(child: SizedBox(height: 32)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final series = _series;
    return Scaffold(
      body: _loading
          ? const SkeletonView(layout: SkeletonLayout.detail)
          : _error != null
              ? ErrorRetryView(error: _error!, onRetry: _reload)
              : SafeArea(
                  // 电视横屏左右分栏：左侧信息/同名/推荐，右侧选集与季。
                  // 单列布局在 16:9 大屏上要滚很久才能看到剧集。
                  child: _isTvSplit(context)
                      ? _buildTvSplit(context)
                      : CustomScrollView(
                          controller: _pageScroll,
                          slivers: [
                            SliverAppBar(
                              pinned: true,
                              title: Text(series?.title ?? widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                              leading: BackButton(
                                  onPressed: () => Navigator.pop(context)),
                            ),
                            SliverToBoxAdapter(child: _header(context)),
                            SliverToBoxAdapter(child: _episodeSection(context)),
                            if (_album != null && _album!.seasons.length > 1)
                              SliverToBoxAdapter(child: _seasonsSection(context)),
                            SliverToBoxAdapter(child: _sameNameSection(context)),
                            if (_recommend != null &&
                                _recommend!.items.isNotEmpty)
                              SliverToBoxAdapter(
                                  child: _recommendSection(context)),
                            const SliverToBoxAdapter(
                                child: SizedBox(height: 32)),
                          ],
                        ),
                ),
      // 详情页已经有「继续播放」FAB，不能抢占插槽：回顶按钮排在它上方。
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          BackToTopFab(controller: _pageScroll),
          if (!_loading && _error == null && _episodes.isNotEmpty) ...[
            const SizedBox(height: 12),
            FloatingActionButton.extended(
              onPressed: () {
                final (ep, start) = _resumeTarget();
                _play(ep, start);
              },
              icon: const Icon(Icons.play_arrow),
              // Builder 不监听 store：从播放页 back 回来时 State 还活着，
              // 历史已变（如刚跳到第 9 集）但文案停在旧值，点击与显示不一致。
              label: ListenableBuilder(
                listenable: AppScope.read(context).history,
                builder: (context, _) {
                  final h = AppScope.read(context).history.get(widget.seriesId);
                  // 有未看完记录就报集数（含 position==0 的跳集意图记录），
                  // 跟 _resumeTarget 的选集逻辑保持同一个真相。
                  final ep = (h != null && !h.finished)
                      ? '继续播放 第${h.episode}集'
                      : '立即播放';
                  return Text(ep);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 详情行的标签（InfoKind=3，服务端自带搜索 schema），可点跳搜索。
  List<String> _tags(Series series) => [
        for (final r in series.rows)
          if (r.kind == 3 && r.text.isNotEmpty) r.text,
      ];

  /// 同名搜索：以当前标题为关键词取一页结果，去掉自身后归两组
  /// （标题带季/部/合集记号 → 系列；其余 → 单剧）。
  Future<void> _loadSameName(String title) async {
    try {
      final page = await AppScope.read(context)
          .api
          .search(title, pageSize: 30);
      if (!mounted) return;
      final selfId = widget.seriesId;
      final items = page.items
          .where((s) => s.id != selfId && s.title.trim().isNotEmpty)
          .toList();
      setState(() => _sameName = items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _sameName = const []);
    }
  }

  /// 「同名系列」分区：季与合集 / 同名系列 / 同名单剧三组。
  Widget _sameNameSection(BuildContext context) {
    final theme = Theme.of(context);
    final items = _sameName;
    if (items == null) return const SizedBox.shrink();
    // 「季与合集」只由 album 提供（同一合集即同一作者）。这里既不再重复渲染
    // 该分组，也要剔除合集内已有条目，只留真正的其他作品。
    //
    // 搜索结果不返回 author 字段，无法按作者做严格过滤；合集成员关系是
    // 「同作者」在当前数据下唯一可信的依据。
    final albumIds = <String>{
      for (final s in _album?.seasons ?? const <Season>[]) s.seriesId,
    };
    final others = [
      for (final s in items)
        if (s.id != widget.seriesId && !albumIds.contains(s.id)) s,
    ];
    final series = [
      for (final s in others)
        if (_seasonMark.hasMatch(s.title) || _seasonMark.hasMatch(s.description))
          s,
    ];
    final singles = [
      for (final s in others)
        if (!_seasonMark.hasMatch(s.title) &&
            !_seasonMark.hasMatch(s.description))
          s,
    ];
    if (series.isEmpty && singles.isEmpty) {
      return const SizedBox.shrink();
    }
    Widget group(String label, List<Widget> tiles) => tiles.isEmpty
        ? const SizedBox.shrink()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              Text(label, style: theme.textTheme.titleSmall),
              ...tiles,
            ],
          );

    List<Widget> tileList(List<SeriesSummary> list) => [
          for (final s in list)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 44,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CoverImage(url: s.coverUrl),
                ),
              ),
              title: Text(s.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                  s.id == widget.seriesId
                      ? '当前'
                      : s.episodeCount > 0
                          ? '共${s.episodeCount}集'
                          : s.category,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              onTap: s.id == widget.seriesId
                  ? null
                  : () => openDetail(context, s.id, s.title),
            ),
        ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('同名系列',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          group('同名系列', tileList(series)),
          group('同名单剧', tileList(singles)),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {    final theme = Theme.of(context);
    final series = _series!;
    final scope = AppScope.read(context);
    final following = scope.follows.isFollowing(series.id);
    final heat = series.heat > 0 ? '${formatCount(series.heat)}热度' : '';
    final meta = [
      if (series.episodeCount > 0)
        series.status == 1 ? '全${series.episodeCount}集' : '更新至${series.episodeCount}集',
      heat,
      if (series.playCount > 0) '${formatCount(series.playCount)}播放',
    ].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 108,
              height: 152,
              child: CoverImage(url: series.coverUrl),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(series.title,
                    style: theme.textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.bold)),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(meta,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ],
                if (series.actorLine.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text('演员：${series.actorLine}',
                      style: theme.textTheme.bodySmall),
                ],
                if (_tags(series).isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final tag in _tags(series))
                        ActionChip(
                          label: Text(tag,
                              style: theme.textTheme.bodySmall),
                          visualDensity: VisualDensity.compact,
                          tooltip: '搜索「$tag」',
                          onPressed: () =>
                              showSearchScreen(context, query: tag),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    FilledButton.tonalIcon(
                      onPressed: () async {
                        await scope.follows.toggle(
                          seriesId: series.id,
                          title: series.title,
                          coverUrl: series.coverUrl,
                          episodeCount: series.episodeCount,
                        );
                        if (context.mounted) setState(() {});
                      },
                      icon: Icon(following
                          ? Icons.favorite
                          : Icons.favorite_border),
                      label: Text(following ? '已追' : '追剧'),
                    ),
                    const SizedBox(width: 8),
                    // 离线缓存：面板里选范围、看进度、可取消。
                    FilledButton.tonalIcon(
                      onPressed: () => _showDownloadSheet(context),
                      icon: const Icon(Icons.download_outlined),
                      label: const Text('缓存'),
                    ),
                    const SizedBox(width: 8),
                    if (scope.follows.get(series.id) != null)
                      _FollowStateMenu(entry: scope.follows.get(series.id)!),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _episodeSection(BuildContext context) {
    final theme = Theme.of(context);
    final series = _series!;
    final desc = series.description;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (desc.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() => _descExpanded = !_descExpanded),
              child: Text(
                desc,
                maxLines: _descExpanded ? null : 2,
                overflow: _descExpanded ? null : TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (series.rows.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final r in series.rows)
                  if (r.kind == 3 || r.kind == 9 || r.kind == 40)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(r.text, style: theme.textTheme.bodySmall),
                    ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Text('选集',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_episodeHasMore)
                TextButton(
                  onPressed: _loadMoreEpisodes,
                  child: const Text('加载更多'),
                ),
            ],
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: AppScope.read(context).downloads,
            builder: (context, _) => GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 110,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 1.6,
            ),
            itemCount: _episodes.length,
            itemBuilder: (context, i) {
              final ep = _episodes[i];
              return Builder(builder: (context) {
                final scope = AppScope.read(context);
                final h = scope.history.get(widget.seriesId);
                final watched = h != null &&
                    (h.finished || h.episode > ep.number);
                final downloaded = scope.downloads.store.has(ep.id);
                return InkWell(
                  onTap: ep.playable ? () => _play(ep, Duration.zero) : null,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: watched
                          ? theme.colorScheme.surfaceContainerHigh
                          : theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Text(
                          ep.number.toString(),
                          style: TextStyle(
                            color: watched
                                ? theme.colorScheme.outline
                                : theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (downloaded)
                          Positioned(
                            right: 4,
                            top: 4,
                            child: Icon(Icons.download_done,
                                size: 14,
                                color: theme.colorScheme.primary),
                          ),
                      ],
                    ),
                  ),
                );
              });
            },
          ),
        ),
        ],
      ),
    );
  }

  /// 离线缓存面板（共享组件，详情页与播放器选集抽屉共用）。
  void _showDownloadSheet(BuildContext context) {
    showDownloadSheet(
      context,
      series: _series!,
      episodes: _episodes,
    );
  }

  Widget _seasonsSection(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('季与合集',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          for (final (i, s) in _album!.seasons.indexed)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: SizedBox(
                width: 44,
                height: 60,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CoverImage(url: s.coverUrl),
                ),
              ),
              // 上游 season_index 缺失时为 0，直接打印会出现「0. 万妖图录传」。
              title: Text(
                  seasonTitleLabel(
                      index: s.index, title: s.title, position: i),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(s.seriesId == widget.seriesId
                  ? '当前季'
                  : '共${s.episodeCount}集'),
              onTap: s.seriesId == widget.seriesId
                  ? null
                  : () => openDetail(context, s.seriesId, s.title),
            ),
        ],
      ),
    );
  }

  Widget _recommendSection(BuildContext context) {
    final theme = Theme.of(context);
    final rec = _recommend!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(rec.cellTitle.isEmpty ? '相关推荐' : rec.cellTitle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          SizedBox(
            height: 200,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: rec.items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final item = rec.items[i];
                return SizedBox(
                  width: 96,
                  child: SeriesCard(
                    item: item,
                    onTap: () => openDetail(context, item.id, item.title),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _FollowStateMenu extends StatelessWidget {
  const _FollowStateMenu({required this.entry});

  final FollowEntry entry;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<FollowState>(
      initialValue: entry.state,
      onSelected: (state) async {
        // 状态只存在本地内存（_followState 简化）：写回 store。
        final scope = AppScope.read(context);
        await scope.follows.follow(
          seriesId: entry.seriesId,
          title: entry.title,
          coverUrl: entry.coverUrl,
          episodeCount: entry.episodeCount,
          state: state,
        );
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: FollowState.want, child: Text('想看')),
        PopupMenuItem(value: FollowState.watching, child: Text('在看')),
        PopupMenuItem(value: FollowState.watched, child: Text('已看')),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Text('· ${switch (entry.state) {
          FollowState.want => '想看',
          FollowState.watching => '在看',
          FollowState.watched => '已看',
        }}',
            style: Theme.of(context).textTheme.bodyMedium),
      ),
    );
  }
}

/// 详情页入口（统一从这里打开，便于以后加埋点/转场）。
void openDetail(BuildContext context, String seriesId, String title) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => DetailScreen(seriesId: seriesId, title: title),
  ));
}
