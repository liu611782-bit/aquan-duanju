// 数据模型：与 openhongguo Go SDK 的 JSON 序列化一一对应（下划线风格字段，
// 见根仓库 docs/types.md）。本文件是唯一的手写映射层，服务端字段的语义注释
// 不在这里重复，去 docs/types.md 看。
//
// 所有的 fromJson 都容忍字段缺失（服务端契约由 SDK 保证，这里只做兜底）。
library;

/// 分页结果（Page[T]）。
class AquaPage<T> {
  const AquaPage({required this.items, this.cursor = '', this.hasMore = false});

  final List<T> items;
  final String cursor;
  final bool hasMore;

  bool get isEmpty => items.isEmpty;

  static AquaPage<T> fromJson<T>(
    Map<String, dynamic> json,
    T Function(Map<String, dynamic>) parse,
  ) {
    final rawItems = json['items'] as List<dynamic>? ?? const [];
    return AquaPage<T>(
      items: rawItems.whereType<Map<String, dynamic>>().map(parse).toList(),
      cursor: json['cursor'] as String? ?? '',
      hasMore: json['has_more'] as bool? ?? false,
    );
  }
}

/// 公开目录中的一行：发现流、搜索、筛选、分类的卡片。
class SeriesSummary {
  const SeriesSummary({
    required this.id,
    this.title = '',
    this.description = '',
    this.coverUrl = '',
    this.coverExpiresAt = '',
    this.episodeCount = 0,
    this.author = '',
    this.category = '',
    this.words = 0,
  });

  final String id;
  final String title;
  final String description;
  final String coverUrl;
  final String coverExpiresAt;
  final int episodeCount;
  final String author;
  final String category;
  final int words;

  factory SeriesSummary.fromJson(Map<String, dynamic> json) => SeriesSummary(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        coverExpiresAt: json['cover_expires_at'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        author: json['author'] as String? ?? '',
        category: json['category'] as String? ?? '',
        words: json['words'] as int? ?? 0,
      );
}

/// 详情页的次要信息行（季、分类、演员……）。
class InfoRow {
  const InfoRow({this.kind = 0, this.text = '', this.schema = ''});

  final int kind;
  final String text;
  final String schema;

  factory InfoRow.fromJson(Map<String, dynamic> json) => InfoRow(
        kind: json['kind'] as int? ?? 0,
        text: json['text'] as String? ?? '',
        schema: json['schema'] as String? ?? '',
      );
}

/// 短剧改编自的小说（详情页可链接，本期不展示正文）。
class Novel {
  const Novel({
    this.bookId = '',
    this.title = '',
    this.shortTitle = '',
    this.status = -1,
    this.tags = const [],
    this.reads = 0,
    this.coverUrl = '',
  });

  final String bookId;
  final String title;
  final String shortTitle;
  final int status;
  final List<String> tags;
  final int reads;
  final String coverUrl;

  factory Novel.fromJson(Map<String, dynamic> json) => Novel(
        bookId: json['book_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        shortTitle: json['short_title'] as String? ?? '',
        status: json['status'] as int? ?? -1,
        tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
        reads: json['reads'] as int? ?? 0,
        coverUrl: json['cover_url'] as String? ?? '',
      );
}

/// 一部短剧的详情视图（getSeries / getSeriesBatch）。
class Series extends SeriesSummary {
  const Series({
    required super.id,
    super.title,
    super.description,
    super.coverUrl,
    super.coverExpiresAt,
    super.episodeCount,
    super.author,
    super.category,
    super.words,
    this.status = 0,
    this.payType = 0,
    this.contentType = 0,
    this.platform = 0,
    this.heat = 0,
    this.playCount = 0,
    this.followCount = 0,
    this.diggCount = 0,
    this.createdAt = '',
    this.rightText = '',
    this.subtitles = const [],
    this.isMultiSeason = false,
    this.seasonIndex = 0,
    this.relatedAlbumId = '',
    this.relatedNovelBookId = '',
    this.novel,
    this.rows = const [],
  });

  /// 发布状态：0 更新中 / 1 已完结 / 3 今日更新 / 4 停止更新。
  final int status;
  final int payType;
  final int contentType;
  final int platform;
  final int heat;
  final int playCount;
  final int followCount;
  final int diggCount;
  final String createdAt;
  final String rightText;
  final List<String> subtitles;
  final bool isMultiSeason;
  final int seasonIndex;
  final String relatedAlbumId;
  final String relatedNovelBookId;
  final Novel? novel;
  final List<InfoRow> rows;

  /// 演员行的文本（InfoKind=33），没有则为空。
  String get actorLine {
    for (final r in rows) {
      if (r.kind == 33) return r.text;
    }
    return '';
  }

  factory Series.fromJson(Map<String, dynamic> json) => Series(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        coverExpiresAt: json['cover_expires_at'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        author: json['author'] as String? ?? '',
        category: json['category'] as String? ?? '',
        words: json['words'] as int? ?? 0,
        status: json['status'] as int? ?? 0,
        payType: json['pay_type'] as int? ?? 0,
        contentType: json['content_type'] as int? ?? 0,
        platform: json['platform'] as int? ?? 0,
        heat: json['heat'] as int? ?? 0,
        playCount: json['play_count'] as int? ?? 0,
        followCount: json['follow_count'] as int? ?? 0,
        diggCount: json['digg_count'] as int? ?? 0,
        createdAt: json['created_at'] as String? ?? '',
        rightText: json['right_text'] as String? ?? '',
        subtitles:
            (json['subtitles'] as List<dynamic>? ?? const []).cast<String>(),
        isMultiSeason: json['is_multi_season'] as bool? ?? false,
        seasonIndex: json['season_index'] as int? ?? 0,
        relatedAlbumId: json['related_album_id'] as String? ?? '',
        relatedNovelBookId: json['related_novel_book_id'] as String? ?? '',
        novel: json['novel'] is Map<String, dynamic>
            ? Novel.fromJson(json['novel'] as Map<String, dynamic>)
            : null,
        rows: (json['rows'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(InfoRow.fromJson)
            .toList(),
      );
}

/// 一个公开列出的分集。number 从 1 开始。
class Episode {
  const Episode({
    required this.id,
    this.seriesId = '',
    this.number = 0,
    this.title = '',
    this.playable = true,
    this.vertical = false,
    this.isNew = false,
    this.coverUrl = '',
    this.contentType = 0,
  });

  final String id;
  final String seriesId;
  final int number;
  final String title;
  final bool playable;
  final bool vertical;
  final bool isNew;
  final String coverUrl;
  final int contentType;

  factory Episode.fromJson(Map<String, dynamic> json) => Episode(
        id: json['id'] as String? ?? '',
        seriesId: json['series_id'] as String? ?? '',
        number: json['number'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        playable: json['playable'] as bool? ?? true,
        vertical: json['vertical'] as bool? ?? false,
        isNew: json['is_new'] as bool? ?? false,
        coverUrl: json['cover_url'] as String? ?? '',
        contentType: json['content_type'] as int? ?? 0,
      );
}

/// 批量读取返回的一部剧及其分集。
class SeriesDetail {
  const SeriesDetail({this.series, this.episodes = const []});

  final Series? series;
  final List<Episode> episodes;

  factory SeriesDetail.fromJson(Map<String, dynamic> json) => SeriesDetail(
        series: json['series'] is Map<String, dynamic>
            ? Series.fromJson(json['series'] as Map<String, dynamic>)
            : null,
        episodes: (json['episodes'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Episode.fromJson)
            .toList(),
      );
}

/// 媒体模型中的一个表示形式。
class VideoStream {
  const VideoStream({
    this.definition = '',
    this.quality = '',
    this.codec = '',
    this.width = 0,
    this.height = 0,
    this.bitrate = 0,
    this.size = 0,
    this.url = '',
    this.backupUrl = '',
    this.hls = false,
    this.dash = false,
    this.protected = false,
    this.encryption = '',
  });

  final String definition;
  final String quality;
  final String codec;
  final int width;
  final int height;
  final int bitrate;
  final int size;
  final String url;
  final String backupUrl;
  final bool hls;
  final bool dash;
  final bool protected;
  final String encryption;

  factory VideoStream.fromJson(Map<String, dynamic> json) => VideoStream(
        definition: json['definition'] as String? ?? '',
        quality: json['quality'] as String? ?? '',
        codec: json['codec'] as String? ?? '',
        width: json['width'] as int? ?? 0,
        height: json['height'] as int? ?? 0,
        bitrate: json['bitrate'] as int? ?? 0,
        size: json['size'] as int? ?? 0,
        url: json['url'] as String? ?? '',
        backupUrl: json['backup_url'] as String? ?? '',
        hls: json['hls'] as bool? ?? false,
        dash: json['dash'] as bool? ?? false,
        protected: json['protected'] as bool? ?? false,
        encryption: json['encryption'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {
        'definition': definition,
        'quality': quality,
        'codec': codec,
        'width': width,
        'height': height,
        'bitrate': bitrate,
        'size': size,
        'url': url,
        'backup_url': backupUrl,
        'hls': hls,
        'dash': dash,
        'protected': protected,
        'encryption': encryption,
      };
}

/// 已解析的播放模型。KeyMaterial 不跨 FFI；加密剧集用 contentKey。
class Playback {
  const Playback({
    this.episodeId = '',
    this.videoId = '',
    this.mediaType = '',
    this.durationSeconds = 0,
    this.expiresAt = 0,
    this.protected = false,
    this.streams = const [],
    this.audioUrl = '',
  });

  final String episodeId;
  final String videoId;
  final String mediaType;
  final int durationSeconds;
  final int expiresAt;
  final bool protected;
  final List<VideoStream> streams;
  final String audioUrl;

  factory Playback.fromJson(Map<String, dynamic> json) => Playback(
        episodeId: json['episode_id'] as String? ?? '',
        videoId: json['video_id'] as String? ?? '',
        mediaType: json['media_type'] as String? ?? '',
        durationSeconds: json['duration_seconds'] as int? ?? 0,
        expiresAt: json['expires_at'] as int? ?? 0,
        protected: json['protected'] as bool? ?? false,
        streams: (json['streams'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(VideoStream.fromJson)
            .toList(),
        audioUrl: json['audio_url'] as String? ?? '',
      );
}

/// CENC 内容密钥（ClearKey/ffmpeg -decryption_key 形式的 hex）。
class ContentKey {
  const ContentKey({this.key = '', this.version = ''});

  final String key;
  final String version;

  factory ContentKey.fromJson(Map<String, dynamic> json) => ContentKey(
        key: json['key'] as String? ?? '',
        version: json['version'] as String? ?? '',
      );
}

/// resolvePlayback 的完整结果：播放模型 + 解密密钥（如适用）。
class PlaybackResult {
  const PlaybackResult({required this.playback, this.contentKey});

  final Playback playback;
  final ContentKey? contentKey;

  factory PlaybackResult.fromJson(Map<String, dynamic> json) =>
      PlaybackResult(
        playback: Playback.fromJson(
          json['playback'] as Map<String, dynamic>? ?? const {},
        ),
        contentKey: json['contentKey'] is Map<String, dynamic>
            ? ContentKey.fromJson(json['contentKey'] as Map<String, dynamic>)
            : null,
      );
}

/// 一条搜索建议。
class Suggestion {
  const Suggestion({this.text = '', this.keyword = '', this.kind = 0});

  final String text;
  final String keyword;
  final int kind;

  factory Suggestion.fromJson(Map<String, dynamic> json) => Suggestion(
        text: json['text'] as String? ?? '',
        keyword: json['keyword'] as String? ?? '',
        kind: json['kind'] as int? ?? 0,
      );
}

/// 热榜上的一部作品。
class HotItem {
  const HotItem({
    this.position = 0,
    this.seriesId = '',
    this.title = '',
    this.coverUrl = '',
    this.episodeCount = 0,
    this.searchScore = '',
    this.heat = '',
    this.tag = '',
  });

  final int position;
  final String seriesId;
  final String title;
  final String coverUrl;
  final int episodeCount;
  final String searchScore;
  final String heat;
  final String tag;

  factory HotItem.fromJson(Map<String, dynamic> json) => HotItem(
        position: json['position'] as int? ?? 0,
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        searchScore: json['search_score'] as String? ?? '',
        heat: json['heat'] as String? ?? '',
        tag: json['tag'] as String? ?? '',
      );
}

/// 热点话题榜的一项。
class HotTopic {
  const HotTopic({
    this.id = '',
    this.title = '',
    this.query = '',
    this.heat = '',
  });

  final String id;
  final String title;
  final String query;
  final String heat;

  factory HotTopic.fromJson(Map<String, dynamic> json) => HotTopic(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        query: json['query'] as String? ?? '',
        heat: json['heat'] as String? ?? '',
      );
}

/// 一个热榜。作品榜填 items，话题榜填 topics。
class HotBoard {
  const HotBoard({this.name = '', this.items = const [], this.topics = const []});

  final String name;
  final List<HotItem> items;
  final List<HotTopic> topics;

  factory HotBoard.fromJson(Map<String, dynamic> json) => HotBoard(
        name: json['name'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HotItem.fromJson)
            .toList(),
        topics: (json['topics'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HotTopic.fromJson)
            .toList(),
      );
}

/// 搜索页首屏：猜你想搜 + 热榜。
class HotSearch {
  const HotSearch({this.guesses = const [], this.boards = const []});

  final List<HotItem> guesses;
  final List<HotBoard> boards;

  factory HotSearch.fromJson(Map<String, dynamic> json) => HotSearch(
        guesses: (json['guesses'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HotItem.fromJson)
            .toList(),
        boards: (json['boards'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(HotBoard.fromJson)
            .toList(),
      );
}

/// 分类页上的一个可选值。
class FilterOption {
  const FilterOption({this.name = '', this.value = ''});

  final String name;
  final String value;

  factory FilterOption.fromJson(Map<String, dynamic> json) => FilterOption(
        name: json['name'] as String? ?? '',
        value: json['value'] as String? ?? '',
      );
}

/// 一个筛选维度（状态、排序、子分类、篇幅）。
class FilterGroup {
  const FilterGroup({this.key = '', this.options = const []});

  final String key;
  final List<FilterOption> options;

  factory FilterGroup.fromJson(Map<String, dynamic> json) => FilterGroup(
        key: json['key'] as String? ?? '',
        options: (json['options'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FilterOption.fromJson)
            .toList(),
      );
}

/// 分类瓦片（分类前页给出的一类书）。
class CategoryTile {
  const CategoryTile({
    this.categoryId = '',
    this.name = '',
    this.picUrl = '',
  });

  final String categoryId;
  final String name;
  final String picUrl;

  factory CategoryTile.fromJson(Map<String, dynamic> json) {
    var picUrl = json['pic_url'] as String? ?? '';
    // 服务端偶发协议相对路径（`//host/...`），直接喂给图片组件会当相对路径失败。
    if (picUrl.startsWith('//')) picUrl = 'https:$picUrl';
    return CategoryTile(
      categoryId: json['category_id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      picUrl: picUrl,
    );
  }
}

/// 分类落地页及其筛选项。
class CategoryPage {
  const CategoryPage({
    this.categoryId = '',
    this.categoryName = '',
    this.description = '',
    this.filters = const [],
    this.tabs = const [],
    this.tiles = const [],
    this.defaultTab = 0,
    this.items = const [],
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final String categoryId;
  final String categoryName;
  final String description;
  final List<FilterGroup> filters;
  final List<FilterOption> tabs;

  /// 分类前页的分类瓦片。
  final List<CategoryTile> tiles;
  final int defaultTab;
  final List<SeriesSummary> items;
  final bool hasMore;
  final int nextOffset;

  factory CategoryPage.fromJson(Map<String, dynamic> json) => CategoryPage(
        categoryId: json['category_id'] as String? ?? '',
        categoryName: json['category_name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        filters: (json['filters'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FilterGroup.fromJson)
            .toList(),
        tabs: (json['tabs'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FilterOption.fromJson)
            .toList(),
        tiles: (json['tiles'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CategoryTile.fromJson)
            .where((t) => t.categoryId.isNotEmpty && t.name.isNotEmpty)
            .toList(),
        defaultTab: json['default_tab'] as int? ?? 0,
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SeriesSummary.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        nextOffset: json['next_offset'] as int? ?? 0,
      );
}

/// 短剧筛选页的一个选择行。
class FilterRow {
  const FilterRow({this.key = '', this.name = '', this.options = const []});

  final String key;
  final String name;
  final List<FilterOption> options;

  factory FilterRow.fromJson(Map<String, dynamic> json) => FilterRow(
        key: json['key'] as String? ?? '',
        name: json['name'] as String? ?? '',
        options: (json['options'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(FilterOption.fromJson)
            .toList(),
      );
}

/// 筛选页的一页结果。
class ShortFilterPage {
  const ShortFilterPage({this.items = const [], this.hasMore = false, this.cursor = ''});

  final List<SeriesSummary> items;
  final bool hasMore;
  final String cursor;

  factory ShortFilterPage.fromJson(Map<String, dynamic> json) =>
      ShortFilterPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SeriesSummary.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        cursor: json['cursor'] as String? ?? '',
      );
}

/// 榜单行的变动。
class RankChange {
  const RankChange({this.kind = 3, this.places = 0});

  final int kind;
  final int places;

  factory RankChange.fromJson(Map<String, dynamic> json) => RankChange(
        kind: json['kind'] as int? ?? 3,
        places: json['places'] as int? ?? 0,
      );
}

/// 榜单的一行。
class RankItem {
  const RankItem({
    this.rank = 0,
    this.actor = '',
    this.seriesId = '',
    this.title = '',
    this.coverUrl = '',
    this.score = '',
    this.episodeCount = 0,
    this.position = 0,
    this.promoted = false,
    this.actorId = '',
    this.userId = '',
    this.avatarUrl = '',
    this.intro = '',
    this.details = const [],
    this.change,
  });

  final int rank;
  final String actor;
  final String seriesId;
  final String title;
  final String coverUrl;
  final String score;
  final int episodeCount;
  final int position;
  final bool promoted;
  final String actorId;
  final String userId;
  final String avatarUrl;
  final String intro;
  final List<String> details;
  final RankChange? change;

  factory RankItem.fromJson(Map<String, dynamic> json) => RankItem(
        rank: json['rank'] as int? ?? 0,
        actor: json['actor'] as String? ?? '',
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        score: json['score'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        position: json['position'] as int? ?? 0,
        promoted: json['promoted'] as bool? ?? false,
        actorId: json['actor_id'] as String? ?? '',
        userId: json['user_id'] as String? ?? '',
        avatarUrl: json['avatar_url'] as String? ?? '',
        intro: json['intro'] as String? ?? '',
        details: (json['details'] as List<dynamic>? ?? const []).cast<String>(),
        change: json['change'] is Map<String, dynamic>
            ? RankChange.fromJson(json['change'] as Map<String, dynamic>)
            : null,
      );
}

/// 短剧榜单页的一个内容（全部、真人剧、漫剧……）及其各个榜。
class RankContent {
  const RankContent({
    this.id = '',
    this.name = '',
    this.selected = false,
    this.boards = const [],
  });

  final String id;
  final String name;
  final bool selected;
  final List<RankBoard> boards;

  factory RankContent.fromJson(Map<String, dynamic> json) => RankContent(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        selected: json['selected'] as bool? ?? false,
        boards: (json['boards'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RankBoard.fromJson)
            .toList(),
      );
}

/// 某个榜单内容下的一个榜（推荐榜、热播榜……）。
class RankBoard {
  const RankBoard({this.id = '', this.name = '', this.selected = false});

  final String id;
  final String name;
  final bool selected;

  factory RankBoard.fromJson(Map<String, dynamic> json) => RankBoard(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        selected: json['selected'] as bool? ?? false,
      );
}

/// 短剧榜单的一页（shortRank）。
class ShortRanking {
  const ShortRanking({
    this.contents = const [],
    this.content = '',
    this.board = '',
    this.items = const [],
    this.hasMore = false,
    this.cursor = '',
  });

  final List<RankContent> contents;
  final String content;
  final String board;
  final List<RankItem> items;
  final bool hasMore;
  final String cursor;

  factory ShortRanking.fromJson(Map<String, dynamic> json) => ShortRanking(
        contents: (json['contents'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RankContent.fromJson)
            .toList(),
        content: json['content'] as String? ?? '',
        board: json['board'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RankItem.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        cursor: json['cursor'] as String? ?? '',
      );
}

/// 活动榜单的一个频道（ranking）。
class RankList {
  const RankList({this.id = '', this.name = '', this.type = 0, this.size = 0});

  final String id;
  final String name;
  final int type;
  final int size;

  factory RankList.fromJson(Map<String, dynamic> json) => RankList(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        type: json['type'] as int? ?? 0,
        size: json['size'] as int? ?? 0,
      );
}

/// 一个活动榜单页。
class Ranking {
  const Ranking({
    this.listName = '',
    this.lists = const [],
    this.items = const [],
    this.hasMore = false,
    this.nextOffset = 0,
  });

  final String listName;
  final List<RankList> lists;
  final List<RankItem> items;
  final bool hasMore;
  final int nextOffset;

  factory Ranking.fromJson(Map<String, dynamic> json) => Ranking(
        listName: json['list_name'] as String? ?? '',
        lists: (json['lists'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RankList.fromJson)
            .toList(),
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RankItem.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        nextOffset: json['next_offset'] as int? ?? 0,
      );
}

/// 演员或角色的主页。
class Person {
  const Person({
    this.userId = '',
    this.name = '',
    this.description = '',
    this.avatarUrl = '',
    this.tags = const [],
    this.labels = const [],
    this.followers = 0,
    this.likes = 0,
  });

  final String userId;
  final String name;
  final String description;
  final String avatarUrl;
  final List<String> tags;
  final List<String> labels;
  final int followers;
  final int likes;

  factory Person.fromJson(Map<String, dynamic> json) => Person(
        userId: json['user_id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        avatarUrl: json['avatar_url'] as String? ?? '',
        tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
        labels: (json['labels'] as List<dynamic>? ?? const []).cast<String>(),
        followers: json['followers'] as int? ?? 0,
        likes: json['likes'] as int? ?? 0,
      );
}

/// 某人出演的一部短剧。
class Work {
  const Work({
    this.seriesId = '',
    this.title = '',
    this.description = '',
    this.coverUrl = '',
    this.episodeCount = 0,
    this.tags = const [],
    this.heat = 0,
    this.plays = 0,
  });

  final String seriesId;
  final String title;
  final String description;
  final String coverUrl;
  final int episodeCount;
  final List<String> tags;
  final int heat;
  final int plays;

  factory Work.fromJson(Map<String, dynamic> json) => Work(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        tags: (json['tags'] as List<dynamic>? ?? const []).cast<String>(),
        heat: json['heat'] as int? ?? 0,
        plays: json['plays'] as int? ?? 0,
      );
}

/// 某人作品的一页。
class WorkPage {
  const WorkPage({this.items = const [], this.hasMore = false, this.cursor = ''});

  final List<Work> items;
  final bool hasMore;
  final String cursor;

  factory WorkPage.fromJson(Map<String, dynamic> json) => WorkPage(
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Work.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        cursor: json['cursor'] as String? ?? '',
      );
}

/// 合集中的一项（季）。
class Season {
  const Season({
    this.seriesId = '',
    this.title = '',
    this.index = 0,
    this.coverUrl = '',
    this.episodeCount = 0,
    this.status = 0,
  });

  final String seriesId;
  final String title;
  final int index;
  final String coverUrl;
  final int episodeCount;
  final int status;

  factory Season.fromJson(Map<String, dynamic> json) => Season(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        index: json['index'] as int? ?? 0,
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        status: json['status'] as int? ?? 0,
      );
}

/// 多季的合集。
class Album {
  const Album({
    this.id = '',
    this.title = '',
    this.description = '',
    this.coverUrl = '',
    this.seasonCount = 0,
    this.seasons = const [],
  });

  final String id;
  final String title;
  final String description;
  final String coverUrl;
  final int seasonCount;
  final List<Season> seasons;

  factory Album.fromJson(Map<String, dynamic> json) => Album(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        seasonCount: json['season_count'] as int? ?? 0,
        seasons: (json['seasons'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Season.fromJson)
            .toList(),
      );
}

/// 上新日历中的一部作品。
class NewRelease {
  const NewRelease({
    this.seriesId = '',
    this.title = '',
    this.description = '',
    this.coverUrl = '',
    this.episodeCount = 0,
    this.online = false,
    this.publishAt = '',
    this.categories = const [],
    this.heat = '',
    this.note = '',
  });

  final String seriesId;
  final String title;
  final String description;
  final String coverUrl;
  final int episodeCount;
  final bool online;
  final String publishAt;
  final List<String> categories;
  final String heat;
  final String note;

  factory NewRelease.fromJson(Map<String, dynamic> json) => NewRelease(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        description: json['description'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        online: json['online'] as bool? ?? false,
        publishAt: json['publish_at'] as String? ?? '',
        categories:
            (json['categories'] as List<dynamic>? ?? const []).cast<String>(),
        heat: json['heat'] as String? ?? '',
        note: json['note'] as String? ?? '',
      );
}

/// 上新日历中的一天。
class NewReleasePage {
  const NewReleasePage({
    this.date = '',
    this.dates = const [],
    this.items = const [],
    this.hasMore = false,
    this.cursor = '',
  });

  final String date;
  final List<String> dates;
  final List<NewRelease> items;
  final bool hasMore;
  final String cursor;

  factory NewReleasePage.fromJson(Map<String, dynamic> json) =>
      NewReleasePage(
        date: json['date'] as String? ?? '',
        dates: (json['dates'] as List<dynamic>? ?? const []).cast<String>(),
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(NewRelease.fromJson)
            .toList(),
        hasMore: json['has_more'] as bool? ?? false,
        cursor: json['cursor'] as String? ?? '',
      );
}
