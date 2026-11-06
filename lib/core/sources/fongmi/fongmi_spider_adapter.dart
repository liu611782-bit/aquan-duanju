import '../source_adapter.dart';
import '../source_import.dart';
import '../spider_js_adapter.dart';
import '../cms_json_adapter.dart' show parsePlayLines;
import '../normal_title.dart';
import 'fongmi_spider_runtime.dart';

/// .js 爬虫源的**口味分发**适配器：同一 SourceKind.spiderJs 下兼容两种形态——
///
/// - **CatVod 式**（长名 homeContent/categoryContent/… + setResult 捕获）→
///   委托既有 [SpiderJsAdapter]；
/// - **FongMi 式**（短名 home/category/detail/search/play + JSON 字符串返回 +
///   `__JS_SPIDER__` 占位 + 同步 `req`）→ [FongmiSpiderRuntime]（后台 isolate +
///   阻塞 FFI 同步 HTTP，见 syncHttp）。
///
/// 口味在首次取源时按 `__JS_SPIDER__` 标记检测并缓存。
class FongmiSpiderAdapter implements SourceAdapter {
  FongmiSpiderAdapter(this.config) : id = config.id, name = config.name;

  final SourceConfig config;

  @override
  final String id;
  @override
  final String name;

  @override
  SourceCaps get caps => const SourceCaps();

  String? _jsSource;
  bool? _isFongmi;
  SpiderJsAdapter? _catvodDelegate;

  /// 取源并检测口味。
  Future<String> _source() async {
    final cached = _jsSource;
    if (cached != null) return cached;
    Object? lastError;
    for (final api in config.apis) {
      try {
        // 已入库源按用户主动添加处理：运行时取源不过导入期 SSRF 守卫。
        final js =
            await SourceImporter.fetchConfigText(api, enforceSsrf: false);
        if (js.trim().isEmpty) continue;
        _jsSource = js;
        _isFongmi = js.contains('__JS_SPIDER__');
        return js;
      } catch (e) {
        lastError = e;
      }
    }
    throw SourceException(
        SourceExceptionCode.network, 'JS 下载失败: $lastError');
  }

  /// CatVod 口味委托（含口味缓存）。
  Future<SourceAdapter> _delegate() async {
    await _source();
    return _catvodDelegate ??= SpiderJsAdapter(config);
  }

  bool get _isFongmiFlavor => _isFongmi == true;

  // ---------- SourceAdapter ----------

  @override
  Future<List<SourceCategory>> categories() async {
    await _source();
    if (!_isFongmiFlavor) return (await _delegate()).categories();
    // FongMi home(filter) → {class}。
    final home = await _callFongmi('home', [false]);
    final classes = home['class'] ?? home['classes'];
    if (classes is! List) return const [];
    return [
      for (final c in classes)
        if (c is Map)
          SourceCategory(
            id: c['type_id']?.toString() ?? '',
            name: c['type_name']?.toString() ?? '',
          ),
    ];
  }

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    await _source();
    if (!_isFongmiFlavor) return (await _delegate()).list(categoryId: categoryId, page: page);
    final data = await _callFongmi(
        'category', [categoryId ?? '', page, true, const <String, String>{}]);
    return SourcePage(
      items: _seriesListOf(data),
      page: page,
      hasMore: _listOf(data).isNotEmpty && page < 200,
    );
  }

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    if (cancel?.isCancelled ?? false) return;
    await _source();
    if (!_isFongmiFlavor) {
      yield* (await _delegate()).search(query, page: page);
      return;
    }
    try {
      final data = await _callFongmi('search', [query, false]);
      yield SourceHits(items: _seriesListOf(data), page: 1);
      yield const SourceSearchDone();
    } on SourceException catch (e) {
      yield SourceSearchFailed(e.code, e.detail);
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.toString());
    }
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    await _source();
    if (!_isFongmiFlavor) return (await _delegate()).detail(sourceItemId);
    final data = await _callFongmi('detail', [sourceItemId]);
    final list = _listOf(data);
    if (list.isEmpty || list.first is! Map) {
      throw SourceException(
          SourceExceptionCode.searchInvalid, '详情为空 $sourceItemId');
    }
    return _series((list.first as Map).cast<String, dynamic>());
  }

  @override
  Future<String> probePlayable({String? itemId}) async {
    await _source();
    if (!_isFongmiFlavor) return (await _delegate()).probePlayable(itemId: itemId);
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

  /// 播放二次解析（FongMi play(flag, id, vipFlags) → {parse, url}）。
  Future<String> resolvePlayUrl({required String flag, required String id}) async {
    final r = await _callFongmi('play', [flag, id, const <String>[]]);
    final url = r['url']?.toString() ?? '';
    if (url.isEmpty) {
      throw SourceException(
          SourceExceptionCode.playFailed, 'play 未返回地址');
    }
    return url;
  }

  // ---------- 工具 ----------

  Future<Map<String, dynamic>> _callFongmi(
      String method, List<Object?> args) async {
    final js = await _source();
    final ext = <String, dynamic>{
      'stype': 3,
      'skey': config.spiderKey ?? '',
      if (config.ext.isNotEmpty) 'ext': config.ext,
    };
    return FongmiSpiderRuntime.call(
      jsSource: js,
      method: method,
      args: args,
      ext: ext,
      profilePath: config.id,
    );
  }

  List<dynamic> _listOf(Map<String, dynamic> data) {
    final list = data['list'] ?? data['data'];
    return list is List ? list : const [];
  }

  List<UnifiedSeries> _seriesListOf(Map<String, dynamic> data) => [
        for (final v in _listOf(data))
          if (v is Map) _series(v.cast<String, dynamic>()),
      ];

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
      normalizedTitle:
          normalizeTitle(vod['vod_name']?.toString() ?? ''),
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
