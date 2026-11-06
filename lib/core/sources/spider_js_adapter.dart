import 'dart:async';

import 'cms_json_adapter.dart' show parsePlayLines;
import 'normal_title.dart';
import 'source_adapter.dart';
import 'source_import.dart';
import 'spider_js_runtime.dart';

/// .js 爬虫源适配器：CatVod 五接口（home/category/detail/search/play）
/// 经 [SpiderJsRuntime] 执行，结果统一映射成 [UnifiedSeries]。
class SpiderJsAdapter implements SourceAdapter {
  SpiderJsAdapter(this.config) : id = config.id, name = config.name;

  final SourceConfig config;

  @override
  final String id;
  @override
  final String name;

  @override
  SourceCaps get caps => const SourceCaps();

  String? _jsSource;

  /// 下载并缓存 JS 源码（apis[0]；失败尝试镜像）。
  Future<String> _source() async {
    final cached = _jsSource;
    if (cached != null) return cached;
    Object? lastError;
    for (final api in config.apis) {
      try {
        // 已入库源按用户主动添加处理：运行时取源不过导入期 SSRF 守卫。
        final js = await SourceImporter.fetchConfigText(api, enforceSsrf: false);
        if (js.trim().isEmpty) continue;
        _jsSource = js;
        return js;
      } catch (e) {
        lastError = e;
      }
    }
    throw SourceException(SourceExceptionCode.network,
        'JS 下载失败: $lastError');
  }

  /// CatVod init(cfg)：`{api, skey, ext}`，ext 为 sites[].ext 原文。
  Map<String, dynamic> get _initCfg => {
        'api': config.api,
        'skey': config.spiderKey ?? '',
        'ext': config.ext,
      };

  Future<Map<String, dynamic>> _call(
      List<String> fnNames, List<Object?> args) async {
    final js = await _source();
    Object? lastError;
    var lastCode = SourceExceptionCode.searchInvalid;
    for (final fn in fnNames) {
      try {
        final r = await SpiderJsRuntime.instance
            .call(js, fn, args, initCfg: _initCfg);
        if (r.isNotEmpty) return r;
      } on SpiderLoadException catch (e) {
        // 脚本没加载起来：重试有意义，且不是「结果非法」。
        lastError = e;
        lastCode = SourceExceptionCode.parseFailed;
        break;
      } on SpiderTimeoutException catch (e) {
        lastError = e;
        lastCode = SourceExceptionCode.searchTimeout;
        break;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) {
      throw SourceException(lastCode, 'spider 调用失败: $lastError');
    }
    return const {};
  }

  // ---------- SourceAdapter ----------

  @override
  Future<List<SourceCategory>> categories() async {
    // CatVod home(filter)：filter=false；结果里 class/classes 都是分类。
    final home = await _call(['homeContent', 'home'], [false]);
    final classes = home['class'] ?? home['classes'];
    if (classes is! List) return const [];
    return [
      for (final c in classes)
        if (c is Map)
          SourceCategory(
            id: c['type_id']?.toString() ?? '',
            name: c['type_name']?.toString() ?? '',
          )
    ];
  }

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    final tid = categoryId ?? '';
    final data = await _call(['categoryContent', 'category'],
        [tid, page, true, const <String, String>{}]);
    final list = data['list'] ?? data['data'] ?? data['videos'];
    final items = <UnifiedSeries>[];
    if (list is List) {
      for (final v in list) {
        if (v is Map) items.add(_series(v.cast<String, dynamic>()));
      }
    }
    return SourcePage(
      items: items,
      page: page,
      hasMore: list is List && list.isNotEmpty && page < 200,
    );
  }

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    try {
      final data = await _call(
          ['searchContent', 'search'], [query, false]);
      final list = data['list'] ?? data['data'];
      yield SourceHits(
        items: [
          if (list is List)
            for (final v in list)
              if (v is Map) _series(v.cast<String, dynamic>())
        ],
        page: 1,
      );
      yield const SourceSearchDone();
    } on SourceException catch (e) {
      yield SourceSearchFailed(e.code, e.detail);
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.toString());
    }
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    final data = await _call(['detailContent', 'detail'], [
      [sourceItemId],
    ]);
    final list = data['list'] ?? data['data'];
    if (list is! List || list.isEmpty || list.first is! Map) {
      throw SourceException(
          SourceExceptionCode.searchInvalid, '详情为空 $sourceItemId');
    }
    return _series((list.first as Map).cast<String, dynamic>());
  }

  @override
  Future<String> probePlayable({String? itemId}) async {
    String? id = itemId;
    if (id == null) {
      final cats = await categories();
      if (cats.isEmpty) return '';
      final page = await list(categoryId: cats.first.id, page: 1);
      if (page.items.isEmpty) return '';
      id = page.items.first.sourceItemId;
    }
    final series = await detail(id);
    final line = series.defaultLine;
    return line == null || line.episodes.isEmpty ? '' : line.episodes.first.url;
  }

  /// 播放二次解析（CatVod playerContent）：spider 源的分集 url 常是令牌，
  /// 真实播放地址要经 `playerContent(flag, id, vipFlags)` 现解析。
  /// 返回结果里的 `url`；无 url/失败抛 [SourceException]（调用方决定回退直连）。
  Future<String> resolvePlayUrl({required String flag, required String id}) async {
    final r = await _call(
        ['playerContent', 'play'], [flag, id, const <String>[]]);
    final url = r['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw SourceException(
          SourceExceptionCode.playFailed, 'playerContent 未返回地址');
    }
    return url;
  }

  /// 测试辅助：跑一次 home 并返回原始结果对象（验证 init 回显）。
  Future<Map<String, dynamic>> homeRawForTest() =>
      _call(['homeContent', 'home'], [false]);

  /// VodItem → UnifiedSeries：播放串解析复用 CMS 的 `$$$/#/$` 实现。
  UnifiedSeries _series(Map<String, dynamic> vod) {
    final vodId = vod['vod_id']?.toString() ?? '';
    final playFrom = vod['vod_play_from']?.toString() ?? '';
    final playUrl = vod['vod_play_url']?.toString() ?? '';
    final lines = playUrl.isEmpty
        ? <PlayLine>[]
        : parsePlayLines(playFrom, playUrl, baseUrl: config.api);
    return UnifiedSeries(
      sourceKey: config.id,
      sourceItemId: vodId,
      title: vod['vod_name']?.toString() ?? '',
      normalizedTitle: normalizeTitle(vod['vod_name']?.toString() ?? ''),
      year: vod['vod_year']?.toString() ?? '',
      coverUrl: vod['vod_pic']?.toString() ?? '',
      remarks: vod['vod_remarks']?.toString() ?? '',
      description:
          (vod['vod_content']?.toString() ?? '').replaceAll(RegExp(r'<[^>]+>'), ''),
      lines: lines,
      headers: config.headers,
    );
  }
}