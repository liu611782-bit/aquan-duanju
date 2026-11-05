import '../models/models.dart';

/// 频道的数据来源。
enum DiscoverSource {
  /// 书城频道：走 `AquaApi.discover`。[DiscoverChannel.value] 必须是 Go core
  /// 的 `ResolveDiscoverChannel` 认得的名字，否则 core 回 UNKNOWN，页面只剩
  /// 「出了点小问题，请稍后再试」。
  feed,

  /// 短剧榜单：走 `AquaApi.shortRank`，按榜名关键字选榜。
  ranking,
}

/// 二级：内容类型下的一个频道。
class DiscoverChannel {
  const DiscoverChannel({
    required this.name,
    this.value = '',
    this.source = DiscoverSource.feed,
    this.boardKeywords = const [],
  });

  /// chip 文案；类型下只有这一个频道时整行不渲染。
  final String name;

  /// [DiscoverSource.feed] 时传给 `discover` 的 channel 值；榜单频道留空，
  /// 它不会被传给 `discover`。
  final String value;

  final DiscoverSource source;

  /// [DiscoverSource.ranking] 时按顺序尝试的榜名关键字。
  final List<String> boardKeywords;
}

/// 卡片点开后的行为。
enum ContentKind {
  /// 视频：进剧集详情/播放。
  video,

  /// 书籍：进书籍详情与阅读器。
  book,

  /// 漫画：进书籍详情与图片阅读器。
  manga,

  /// 社区：进话题广场与帖子详情。
  community,
}

/// 一级：发现页的内容类型。
///
/// 点开行为由类型决定，与并列频道无关。
class ContentType {
  const ContentType({
    required this.name,
    required this.channels,
    this.kind = ContentKind.video,
    this.notice = '',
  });

  /// 类型条文案。
  final String name;

  /// 类型内的频道；长度 1 时二级行隐藏。
  final List<DiscoverChannel> channels;

  final ContentKind kind;

  /// 非空时在列表顶部显示一条说明，用于能力尚未接入的类型。
  final String notice;
}

/// 短剧榜单的「全部」内容 id（空字符串在 SDK 里也会归一成它）。
const String kShortRankContentAll = 'all';

/// 短剧的默认频道（书城推荐，也是全局失败回退目标）。
const DiscoverChannel kShortPlayRecommend = DiscoverChannel(name: '推荐');

/// 短剧的频道：推荐 + 三个榜单频道。
///
/// `新剧/热剧/爆款好剧` 在 Go core 没有书城 tab 映射，所以必须走
/// [DiscoverSource.ranking] 且 [DiscoverChannel.value] 留空，否则会打到
/// `unknown discover channel` 那条 UNKNOWN 路径上。
const List<DiscoverChannel> _shortPlayChannels = <DiscoverChannel>[
  kShortPlayRecommend,
  DiscoverChannel(
    name: '新剧',
    source: DiscoverSource.ranking,
    boardKeywords: ['新剧', '上新', '最新'],
  ),
  DiscoverChannel(
    name: '热剧',
    source: DiscoverSource.ranking,
    boardKeywords: ['热播', '热搜', '热度'],
  ),
  DiscoverChannel(
    name: '爆款好剧',
    source: DiscoverSource.ranking,
    boardKeywords: ['爆款', '推荐'],
  ),
];

/// 默认类型：短剧。
const ContentType kShortPlayType = ContentType(
  name: '短剧',
  channels: _shortPlayChannels,
);

/// 发现页的内容类型，顺序即类型条顺序。
///
/// 不变式：除短剧首项外，`channels.single.value == name`（类型名就是书城
/// 频道名）。新增类型的顺序要与 `channel.go` 里的映射核对过再登记。
const List<ContentType> kContentTypes = <ContentType>[
  kShortPlayType,
  ContentType(
    name: '漫剧',
    channels: [DiscoverChannel(name: '推荐', value: '漫剧')],
  ),
  ContentType(
    name: '电影',
    channels: [DiscoverChannel(name: '推荐', value: '电影')],
  ),
  ContentType(
    name: '小说',
    channels: [DiscoverChannel(name: '推荐', value: '小说')],
    kind: ContentKind.book,
  ),
  // 听书（tab_type 5）已下线：专辑与曲目都能取到，但播放地址接口 novelfm 按
  // 应用家族校验 aid，本设备是 hongguo 家族，实测三种参数组合均为
  // 403 invalid aid / 400，无法播放。实现已从仓库移除（历史提交 fb94da0）。
  // 漫画 tab 已从发现页下线（2026-11-05）：进入后整窗黑屏且无法返回。
  // Venera 源 / 阅读器链路待单独排查；代码保留，修好后把上面的 ContentType
  // 加回即可恢复入口（发现页 `_entriesFor('漫画')` 的入口卡也一并复活）。
  // 社区不再作为「内容类型」：tab_type 33 下发的是书籍流，放进类型条会让人以为
  // 「社区」是一类小说。社区是独立板块（话题 → 帖子 → 帖子详情），入口在发现页
  // 顶栏（社区图标），帖子数据来自「讨论」搜索（tab_type 31），
  // 见 research-community-feed。
];

const ContentType kDefaultContentType = kShortPlayType;
const DiscoverChannel kDefaultChannel = kShortPlayRecommend;

/// 榜单 board 缓存的键。`推荐` 在多个类型下都存在，必须带类型前缀。
String channelKey(ContentType type, DiscoverChannel channel) =>
    '${type.name}/${channel.name}';

/// 短剧榜单的内容目录：优先「全部」，其次服务端选中项，再次第一项。
RankContent? primaryRankContent(List<RankContent> contents) {
  for (final content in contents) {
    if (content.id == kShortRankContentAll) return content;
  }
  for (final content in contents) {
    if (content.selected) return content;
  }
  return contents.isEmpty ? null : contents.first;
}

/// 按 [keywords] 的顺序在榜名里找第一个命中的榜；都没命中返回 null。
///
/// 榜名和榜 id 都由服务端下发，所以按名字匹配而不是写死 id：服务端换榜后
/// 只会走默认榜降级，不会整块失效。
RankBoard? matchBoard(List<RankBoard> boards, List<String> keywords) {
  for (final keyword in keywords) {
    if (keyword.trim().isEmpty) continue;
    for (final board in boards) {
      if (board.id.isNotEmpty && board.name.contains(keyword)) return board;
    }
  }
  return null;
}

/// 服务端给的默认榜：`selected` 优先，否则第一个有 id 的榜。
RankBoard? defaultBoard(List<RankBoard> boards) {
  for (final board in boards) {
    if (board.id.isNotEmpty && board.selected) return board;
  }
  for (final board in boards) {
    if (board.id.isNotEmpty) return board;
  }
  return null;
}

/// 榜单行转成发现页的卡片模型；没有 `series_id` 的行（演员行）丢弃。
List<SeriesSummary> rankItemsToSummaries(List<RankItem> items) {
  final out = <SeriesSummary>[];
  for (final item in items) {
    final id = item.seriesId.trim();
    if (id.isEmpty) continue;
    out.add(SeriesSummary(
      id: id,
      title: item.title,
      coverUrl: item.coverUrl,
      episodeCount: item.episodeCount,
    ));
  }
  return out;
}

/// 剧集 id → 名次角标文案。
///
/// 只认 `position`，**不读 `recommend_info.rank`**：服务端对同一页的多行都会
/// 下发 `rank: 1`（实测两个相邻卡片同时是「第1」），用它必然重复。
/// `position` 是解析器按返回顺序生成的 `len(items)+1`，页内唯一且递增。
///
/// 另外两条约束：
/// - `position` 是**页内**序号，下一页从 1 重来，所以翻页必须由调用方把已加载
///   的原始条目数作为 [offset] 传进来，否则第二页又从「第1」开始；
/// - `promoted` 行（「平台推荐」）不显示名次，但它**仍占一个 position**，
///   所以 [offset] 要按包含它的原始条目数累加，不能用去重后的展示条目数。
Map<String, String> rankBadges(List<RankItem> items, {int offset = 0}) {
  final out = <String, String>{};
  for (final item in items) {
    final id = item.seriesId.trim();
    if (id.isEmpty || item.promoted) continue;
    final pagePlace = item.position;
    if (pagePlace <= 0) continue;
    out[id] = '第${pagePlace + offset}';
  }
  return out;
}
