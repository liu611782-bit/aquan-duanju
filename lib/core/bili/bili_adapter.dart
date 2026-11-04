import '../sources/normal_title.dart';
import '../sources/source_adapter.dart';
import 'api.dart';
import 'session.dart';

/// B 站源适配器：把「推荐/搜索/视频/番剧」适配成统一 [SourceAdapter]，
/// 详情/播放/历史全部复用 CMS 源那套链路（sourceKey='bili'）。
///
/// 分集 URL 用 `bili://play?…` 自定义协议承载参数（bvid/cid/epId），
/// 真实 DASH 地址在播放时经 [resolvePlay] 现解析（地址有时效，不能缓存）。
class BiliAdapter implements SourceAdapter {
  BiliAdapter(this.session) : _api = BiliApi(session);

  final BiliSession session;
  final BiliApi _api;

  /// 播放器使用的源配置（Referer 必须是 bilibili.com，否则 m4s 拒绝服务）。
  static SourceConfig config() => SourceConfig(
        id: 'bili',
        name: '哔哩哔哩',
        apis: ['https://api.bilibili.com'],
        headers: const {
          'Referer': 'https://www.bilibili.com/',
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                  '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
        },
      );

  @override
  String get id => 'bili';

  @override
  String get name => '哔哩哔哩';

  @override
  SourceCaps get caps => const SourceCaps(filterable: false);

  @override
  Future<List<SourceCategory>> categories() async => const [
        SourceCategory(id: 'rcmd', name: '推荐'),
        SourceCategory(id: 'bangumi', name: '番剧·影视'),
      ];

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    if (categoryId == 'bangumi') {
      // 番剧频道：没有免登录列表接口，走热门 season 关键词搜索占位；
      // MVP 先返回空，引导用搜索。
      return SourcePage(items: const [], page: page);
    }
    final feed = await _api.homeFeed(freshIndex: page);
    return SourcePage(
      items: [
        for (final card in feed)
          UnifiedSeries(
            sourceKey: 'bili',
            sourceItemId: 'v:${card.bvid}',
            title: card.title,
            normalizedTitle: normalizeTitle(card.title),
            coverUrl: card.coverUrl,
            remarks: [card.durationLabel, if (card.upName.isNotEmpty) 'UP：${card.upName}']
                .where((s) => s.isNotEmpty)
                .join(' · '),
            lines: [],
            headers: config().headers,
          ),
      ],
      page: page,
      hasMore: feed.isNotEmpty,
    );
  }

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    try {
      final items = await _api.search(query);
      yield SourceHits(
        items: [
          for (final item in items)
            UnifiedSeries(
              sourceKey: 'bili',
              sourceItemId:
                  item.kind == BiliItemKind.season ? 'ss:${item.id}' : 'v:${item.id}',
              title: item.title,
              normalizedTitle: normalizeTitle(item.title),
              coverUrl: item.coverUrl,
              remarks: item.subTitle,
              headers: config().headers,
            ),
        ],
        page: 1,
      );
      yield const SourceSearchDone();
    } on BiliException catch (e) {
      yield SourceSearchFailed(
          e.code == -412
              ? SourceExceptionCode.searchTimeout
              : SourceExceptionCode.network,
          e.toString());
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.toString());
    }
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    if (sourceItemId.startsWith('ss:')) {
      final season = await _api.season(seasonId: sourceItemId.substring(3));
      return UnifiedSeries(
        sourceKey: 'bili',
        sourceItemId: sourceItemId,
        title: season.title,
        normalizedTitle: normalizeTitle(season.title),
        coverUrl: season.coverUrl,
        remarks: '番剧 · 共${season.episodes.length}集',
        description: season.description,
        lines: [
          if (season.episodes.isNotEmpty)
            PlayLine(
              name: '正片',
              episodes: [
                for (final ep in season.episodes)
                  UnifiedEpisode(
                    title: ep.title.isEmpty ? '第${ep.index}集' : ep.title,
                    url: 'bili://play?ep=${ep.epId}&cid=${ep.cid}',
                    index: ep.index == 0 ? season.episodes.indexOf(ep) + 1 : ep.index,
                  ),
              ],
            ),
        ],
        headers: config().headers,
      );
    }
    final bvid =
        sourceItemId.startsWith('v:') ? sourceItemId.substring(2) : sourceItemId;
    final detail = await _api.videoDetail(bvid);
    return UnifiedSeries(
      sourceKey: 'bili',
      sourceItemId: sourceItemId,
      title: detail.title,
      normalizedTitle: normalizeTitle(detail.title),
      coverUrl: detail.coverUrl,
      remarks: detail.pages.length > 1 ? '共${detail.pages.length}P' : 'UP：${detail.upName}',
      description: detail.description,
      lines: [
        PlayLine(
          name: '分P',
          episodes: [
            for (final p in detail.pages)
              UnifiedEpisode(
                title: p.title.isEmpty ? '第${p.index}P' : p.title,
                url: 'bili://play?bvid=${detail.bvid}&cid=${p.cid}',
                index: p.index,
              ),
          ],
        ),
      ],
      headers: config().headers,
    );
  }

  @override
  Future<String> probePlayable({String? itemId}) async => '';

  /// 播放时解析真实 DASH 地址（[BiliPlayUrls.isPreview] 时给出受限提示）。
  Future<BiliResolvedPlay> resolvePlay(String episodeUrl) async {
    final params = Uri.parse(episodeUrl).queryParameters;
    if (params.containsKey('ep')) {
      final play = await _api.playUrls(
        cid: params['cid'] ?? '',
        epId: params['ep'],
        isPgc: true,
      );
      return _toResolved(play);
    }
    final play = await _api.playUrls(
      cid: params['cid'] ?? '',
      bvid: params['bvid'] ?? '',
    );
    return _toResolved(play);
  }

  BiliResolvedPlay _toResolved(BiliPlayUrls play) {
    if (!play.isPlayable) {
      throw SourceException(SourceExceptionCode.playFailed,
          play.previewHint ?? '无可用播放地址');
    }
    // 非 DASH 兜底（durl 直链，自带音轨）。
    if (play.videos.isEmpty) {
      return BiliResolvedPlay(
        videoUrl: play.durlFirstUrl ?? '',
        isPreview: play.isPreview,
        previewHint: play.previewHint,
      );
    }
    final video = play.videos.first;
    // 音轨取最高带宽；mpv audio-files 挂载（BiliSail 同方案）。
    final audio = play.audios.isEmpty ? null : play.audios.first;
    return BiliResolvedPlay(
      videoUrl: video.url,
      audioUrl: audio?.url,
      isPreview: play.isPreview,
      previewHint: play.previewHint,
    );
  }

  /// 发送弹幕：从分集 URL 参数取 bvid/cid。
  Future<void> sendDanmaku(String episodeUrl, String msg) async {
    final params = Uri.parse(episodeUrl).queryParameters;
    await _api.sendDanmaku(
      bvid: params['bvid'] ?? '',
      cid: params['cid'] ?? '',
      msg: msg,
    );
  }

  /// 弹幕：按 cid 拉取（playurl 后才知道 cid，从分集 URL 参数里取）。
  Future<List<DanmakuItem>> loadDanmaku(String episodeUrl) async {
    final cid = Uri.parse(episodeUrl).queryParameters['cid'] ?? '';
    if (cid.isEmpty) return const [];
    return _api.danmaku(cid);
  }
}

/// 播放时解析出的真实地址。
class BiliResolvedPlay {
  const BiliResolvedPlay({
    required this.videoUrl,
    this.audioUrl,
    this.isPreview = false,
    this.previewHint,
  });
  final String videoUrl;
  final String? audioUrl;
  final bool isPreview;
  final String? previewHint;
}
