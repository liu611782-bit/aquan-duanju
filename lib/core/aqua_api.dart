import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../models/audio.dart';
import '../models/book.dart';
import 'error_log.dart';
import '../models/manga.dart';
import '../models/models.dart';
import '../models/post.dart';
import 'aqua_client.dart';

/// fetchImage 的最小接口，便于缓存层与测试注入假实现；[AquaApi] 实现它。
abstract class AquaImageFetcher {
  Future<AquaImage> fetchImage(String url);
}

/// 漫画页下载并解密的接口（AES-256-GCM 在 core 侧完成）。
abstract class MangaPageFetcher {
  Future<AquaImage> fetchMangaPage(String url, String key);
}

/// fetchImage 的结果：已经是 Flutter 可直接解码的字节（HEIC 已由核心转成
/// JPEG），mime 是对应类型。
class AquaImage {
  const AquaImage(this.bytes, this.mime);

  final Uint8List bytes;
  final String mime;
}

/// 类型化的 API 门面：把 AquaClient 的动态 JSON 调用包成返回模型的方法。
/// 页面只看这一层，不碰信封与 jsonDecode。
class AquaApi implements AquaImageFetcher, MangaPageFetcher {
  AquaApi(this._client);

  final AquaClient _client;

  static final Random _rng = Random();

  /// 下载一张封面图并按需转码（服务端固定返回 HEIC，见核心 image.go）。
  /// 失败抛 AquaException（403 = 签名过期，走裂图占位兜底）。
  @override
  Future<AquaImage> fetchImage(String url) async {
    final r = _map(await _client.call('fetchImage', [url]));
    final data = base64Decode(r['data'] as String? ?? '');
    return AquaImage(data, r['mime'] as String? ?? 'image/jpeg');
  }

  // ---------- 目录 ----------

  /// 发现流（书城频道）。channel 空即推荐。
  Future<AquaPage<SeriesSummary>> discover({String channel = '', String cursor = ''}) async {
    final r = await _client.call('discover', [
      {'channel': channel, 'cursor': cursor},
    ]);
    return AquaPage.fromJson<SeriesSummary>(
        _map(r), SeriesSummary.fromJson);
  }

  /// 搜索。tab 空即综合；filters 收窄综合结果（与游标要一起传）。
  Future<AquaPage<SeriesSummary>> search(
    String query, {
    String cursor = '',
    String tab = '',
    List<String> filters = const [],
    int pageSize = 0,
  }) async {
    final r = await _client.call('search', [
      query,
      {
        'cursor': cursor,
        'tab': tab,
        'filters': filters,
        if (pageSize > 0) 'pageSize': pageSize,
      },
    ]);
    return AquaPage.fromJson<SeriesSummary>(
        _map(r), SeriesSummary.fromJson);
  }

  Future<List<Suggestion>> suggest(String prefix) async {
    final r = await _client.call('suggest', [prefix]);
    return _list(r).map(Suggestion.fromJson).toList();
  }

  Future<HotSearch> hotSearch() async =>
      HotSearch.fromJson(_map(await _client.call('hotSearch')));

  // ---------- 投屏中继（castrelay.go，CENC 加密分集） ----------

  /// 启动局域网解密中继：返回 {session, token, port, url, format, ready}。
  /// [userAgent]/[referer] 透传给 ffmpeg -headers（B 站等 CDN 防盗链必需）。
  Future<Map<String, dynamic>> castRelayStart({
    required String url,
    String backupUrl = '',
    String decKey = '',
    String audioUrl = '',
    String userAgent = '',
    String referer = '',
  }) async {
    final r = await _client.call('castRelayStart', [
      jsonEncode({
        'url': url,
        'backup_url': backupUrl,
        'dec_key': decKey,
        'audio_url': audioUrl,
        'user_agent': userAgent,
        'referer': referer,
      }),
    ]);
    return _map(r);
  }

  /// 启动桌面镜像中继（Windows；ddagrab→HLS）。返回 {session, url, ...}。
  Future<Map<String, dynamic>> castDesktopStart({int fps = 10}) async {
    final r = await _client.call('castDesktopStart', [
      jsonEncode({'fps': fps}),
    ]);
    return _map(r);
  }

  /// 停止并回收桌面镜像会话。
  Future<void> castDesktopStop(String session) async {
    await _client.call('castDesktopStop', [session]);
  }

  /// 停止并回收中继会话。
  Future<void> castRelayStop(String session) async {
    await _client.call('castRelayStop', [session]);
  }

  /// 查询中继状态（诊断用）。
  Future<Map<String, dynamic>> castRelayStatus(String session) async {
    final r = await _client.call('castRelayStatus', [session]);
    return _map(r);
  }

  Future<List<String>> searchCues() async =>
      _list(await _client.call('searchCues')).cast<String>();

  Future<NewReleasePage> newReleases({String date = '', String cursor = ''}) async {
    final r = await _client.call('newReleases', [
      {'date': date, 'cursor': cursor},
    ]);
    return NewReleasePage.fromJson(_map(r));
  }

  // ---------- 剧集 ----------

  Future<Series> getSeries(String id) async =>
      Series.fromJson(_map(await _client.call('getSeries', [id])));

  Future<List<SeriesDetail>> getSeriesBatch(List<String> ids) async {
    final r = await _client.call('getSeriesBatch', [ids]);
    return _list(r).map(SeriesDetail.fromJson).toList();
  }

  Future<AquaPage<Episode>> listEpisodes(String seriesId, {String cursor = '', int pageSize = 0}) async {
    final r = await _client.call('listEpisodes', [
      seriesId,
      {'cursor': cursor, if (pageSize > 0) 'pageSize': pageSize},
    ]);
    return AquaPage.fromJson<Episode>(_map(r), Episode.fromJson);
  }

  Future<Album> seasons(String seriesId) async =>
      Album.fromJson(_map(await _client.call('seasons', [seriesId])));

  Future<Recommend> seriesRecommend(String seriesId) async =>
      Recommend.fromJson(_map(await _client.call('seriesRecommend', [seriesId])));

  // ---------- 播放 ----------

  /// 解析播放地址；加密剧集自动带 contentKey（解密交给播放器）。
  Future<PlaybackResult> resolvePlayback(String episodeId) async =>
      PlaybackResult.fromJson(_map(await _client.call('resolvePlayback', [episodeId])));

  // ---------- 榜单与筛选 ----------

  Future<ShortRanking> shortRank({String content = '', String board = '', String cursor = ''}) async {
    final r = await _client.call('shortRank', [
      {'content': content, 'board': board, 'cursor': cursor},
    ]);
    return ShortRanking.fromJson(_map(r));
  }

  Future<List<FilterRow>> shortFilterPanel(String genre) async {
    final r = await _client.call('shortFilterPanel', [genre]);
    return _list(r).map(FilterRow.fromJson).toList();
  }

  Future<ShortFilterPage> shortFilter(
    Map<String, List<String>> selections, {
    String cursor = '',
  }) async {
    final r = await _client.call('shortFilter', [
      {'selections': selections, 'cursor': cursor},
    ]);
    return ShortFilterPage.fromJson(_map(r));
  }

  Future<List<RankContent>> shortRankContents() async {
    final first = await shortRank();
    return first.contents;
  }

  Future<Ranking> ranking(String activityId, String listId) async =>
      Ranking.fromJson(_map(await _client.call('ranking', [activityId, listId])));

  Future<Ranking> rankRows(String cellId, int offset) async =>
      Ranking.fromJson(_map(await _client.call('rankRows', [cellId, offset])));

  Future<List<RankList>> rankGroups() async {
    final r = await _client.call('rankGroups');
    return _list(r).map(RankList.fromJson).toList();
  }

  // ---------- 分类 ----------

  Future<List<String>> categories(String categoryId) async {
    // categories 返回 CategoryPage（分类本身的列表）；详情页分类用的不多，
    // 这里透传 items 的标题。
    final r = await _client.call('categories', [categoryId]);
    final page = CategoryPage.fromJson(_map(r));
    return page.items.map((s) => s.title).toList();
  }

  /// 分类前页：分类瓦片 + 受众标签页（全部 / 男生 / 女生）。
  ///
  /// tab 传 '1' 男频、'0' 女频、空即全部（core 侧按 1 处理）。
  Future<CategoryPage> categoryTiles({String tab = '1'}) async {
    final r = await _client.call('categories', [tab]);
    return CategoryPage.fromJson(_map(r));
  }

  Future<CategoryPage> categoryLanding(
    String categoryId, {
    String tab = '',
    Map<String, String> filters = const {},
    String cursor = '',
  }) async {
    final r = await _client.call('categoryLanding', [
      categoryId,
      {'tab': tab, 'filters': filters, 'cursor': cursor},
    ]);
    return CategoryPage.fromJson(_map(r));
  }

  // ---------- 人物 ----------

  Future<Person> person(String userId) async =>
      Person.fromJson(_map(await _client.call('person', [userId])));

  Future<WorkPage> personWorks(String userId, {String cursor = ''}) async {
    final r = await _client.call('personWorks', [userId, cursor]);
    return WorkPage.fromJson(_map(r));
  }

  // ---------- 阅读 ----------

  /// 书籍详情（小说频道）。
  Future<BookDetail> bookDetail(String bookId) async =>
      BookDetail.fromJson(_map(await _client.call('bookDetail', [bookId])));

  /// 整本章节目录（不分页）。
  Future<BookDirectory> bookDirectory(String bookId) async =>
      BookDirectory.fromJson(_map(await _client.call('bookDirectory', [bookId])));

  /// 漫画一话的图片清单（含整话共用的解密密钥）。
  Future<MangaChapterPages> chapterPages(String itemId) async =>
      MangaChapterPages.fromJson(
          _map(await _client.call('chapterPages', [itemId])));

  /// 下载并解密一页漫画图。key 为空表示未加密。
  @override
  Future<AquaImage> fetchMangaPage(String url, String key) async {
    final r = _map(await _client.call('fetchMangaPage', [url, key]));
    final data = base64Decode(r['data'] as String? ?? '');
    return AquaImage(data, r['mime'] as String? ?? 'image/jpeg');
  }


  /// 社区帖子详情（正文块 + 互动数据）。
  Future<CommunityPost> postDetail(String postId) async =>
      CommunityPost.fromJson(_map(await _client.call('postDetail', [postId])));

  /// 一本书可用的音色（智能朗读 / 真人讲书）。
  /// 音轨类接口只对番茄书有效（bookId/itemId 必须是纯数字）。
  /// 非数字时记录**调用栈**并短路，避免把 URL 章节 id 发给 Go 侧。
  static final RegExp _numericId = RegExp(r'^\d+$');

  void _guardAudioIds(String what, String bookId, String itemId) {
    if (_numericId.hasMatch(bookId.trim()) &&
        (itemId.isEmpty || _numericId.hasMatch(itemId.trim()))) {
      return;
    }
    ErrorLog.instance.record(
      '音轨调用被拦截：$what bookId=$bookId itemId=$itemId',
      StackTrace.current,
    );
    throw const NoOfficialTrackException();
  }

  Future<AudioTones> audioTones(String bookId) async {
    _guardAudioIds('audioTones', bookId, '');
    return AudioTones.fromJson(_map(await _client.call('audioTones', [bookId])));
  }

  /// 取一条音轨的播放地址与内容密钥。
  Future<AudioTrack> audioPlay(
      String bookId, String itemId, int toneId) async {
    _guardAudioIds('audioPlay', bookId, itemId);
    return AudioTrack.fromJson(
        _map(await _client.call('audioPlay', [bookId, itemId, '$toneId'])));
  }

  /// 取音轨并落盘到本地（core 用阅读客户端请求头下载，避开 CDN 的 403）。
  Future<AudioStream> audioStream(
      String bookId, String itemId, int toneId) async {
    _guardAudioIds('audioStream', bookId, itemId);
    return AudioStream.fromJson(
        _map(await _client.call('audioStream', [bookId, itemId, '$toneId'])));
  }

  /// 音频时间点（段落 ↔ 毫秒），用于把阅读位置对齐到听书位置。
  Future<AudioTimepoints> audioTimepoints(
      String bookId, String itemId, int toneId) async {
    _guardAudioIds('audioTimepoints', bookId, itemId);
    return AudioTimepoints.fromJson(_map(
        await _client.call('audioTimepoints', [bookId, itemId, '$toneId'])));
  }

  /// 设备的内容密钥（首次调用会注册并落盘 sidecar）。
  Future<String> secretKey() async =>
      (await _client.call('secretKey')) as String? ?? '';

  /// 取一章正文并解密；书籍尚未开放或解密失败时抛 AquaException。
  Future<String> chapterText(String itemId) async {
    final r = _map(await _client.call('chapterText', [itemId]));
    return r['text'] as String? ?? '';
  }

  // ---------- 设备 ----------

  Future<void> resetDevice() => _client.call('resetDevice');

  /// 随机取一部剧的 id：从发现流随机页开始翻。随机播放 feed 的候选来源之一。
  Future<List<SeriesSummary>> randomCandidates({int pages = 2}) async {
    final out = <SeriesSummary>[];
    var cursor = '';
    for (var i = 0; i < pages; i++) {
      final page = await discover(cursor: cursor);
      out.addAll(page.items);
      if (!page.hasMore || page.cursor.isEmpty) break;
      cursor = page.cursor;
    }
    out.shuffle(_rng);
    return out;
  }

  Map<String, dynamic> _map(dynamic v) =>
      v is Map<String, dynamic> ? v : <String, dynamic>{};

  List<Map<String, dynamic>> _list(dynamic v) =>
      (v as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
}

/// 一部短剧的相关推荐单元（seriesRecommend）。
class Recommend {
  const Recommend({this.cellTitle = '', this.items = const []});

  final String cellTitle;
  final List<SeriesSummary> items;

  factory Recommend.fromJson(Map<String, dynamic> json) => Recommend(
        cellTitle: json['cell_title'] as String? ?? '',
        items: (json['items'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(SeriesSummary.fromJson)
            .toList(),
      );
}

/// 非番茄书请求官方音轨（无音轨可用）。
///
/// UI 应降级为本地朗读，不要当错误弹红字；[toString] 就是给用户看的一句话。
class NoOfficialTrackException implements Exception {
  const NoOfficialTrackException();

  @override
  String toString() => '这本书没有官方音轨（非番茄书），已改用本地朗读';
}
