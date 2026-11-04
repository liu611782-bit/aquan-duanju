import 'dart:async';
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'normal_title.dart';
import 'source_adapter.dart';
import 'idn.dart';
import 'source_import.dart';

/// CMS（苹果 CMS V10）源适配器：覆盖 type=1（JSON）与 type=0（XML）。
///
/// 端点自举与容错语义对齐 guoappxxx `provider_maccms_api.go`：
/// - 基址不含 `provide/vod`/`api.php` 时依次探测候选端点，带正/负缓存；
/// - 搜索 `ac=videolist&wd=` 失败回退 `ac=search&wd=`；详情 `ac=detail&ids=`
///   回退 `ac=videolist&ids=`；分类 `ac=list` 无 class 回退扫 videolist 回收；
/// - 响应优先 JSON，`<` 开头按 XML 解析；UTF-8 失败按 GBK。
class CmsJsonAdapter implements SourceAdapter {
  CmsJsonAdapter(this.config, {http.Client? client})
      : id = config.id,
        name = config.name,
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final SourceConfig config;

  @override
  final String id;
  @override
  final String name;

  @override
  SourceCaps get caps => const SourceCaps();

  http.Client _client;

  /// 注入的 client 由调用方管理；自建的才能在取消时 `close(force: true)`。
  final bool _ownsClient;
  bool _clientClosed = false;

  /// 端点自举缓存。
  String? _resolved;
  DateTime? _resolveBlockedUntil;

  static const _timeout = Duration(seconds: 10);

  // ---------- 端点自举 ----------

  Future<String> _endpoint() async {
    if (_resolved != null) return _resolved!;
    final blockedUntil = _resolveBlockedUntil;
    if (blockedUntil != null &&
        DateTime.now().isBefore(blockedUntil) &&
        _resolved == null) {
      throw SourceException(
          SourceExceptionCode.endpointUnresolved, '端点探测冷却中');
    }
    // 多镜像：apis[0] 主地址，其余镜像逐个回退（tvbox withFallback 同语义）。
    for (final base in config.apis) {
      final trimmed = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
      // 基址已带参数或已是指向 vod 接口的完整路径：原样使用。
      if (trimmed.contains('?') ||
          trimmed.contains('provide/vod') ||
          trimmed.contains('api.php')) {
        _resolved = trimmed;
        return _resolved!;
      }
      final candidates = [
        '$trimmed/api.php/provide/vod',
        '$trimmed/api.php/app/vod',
        trimmed,
      ];
      for (final candidate in candidates) {
        try {
          final res = await _get('$candidate?ac=videolist&pg=1',
              timeout: const Duration(seconds: 6));
          if (_looksLikeVod(_parsePayload(_decodeBody(res)))) {
            _resolved = candidate;
            return candidate;
          }
        } on SourceException {
          continue;
        } catch (_) {
          continue;
        }
      }
    }
    // 全部失败：确定性失败缓存 60s，防止每次搜索都把候选打一遍。
    _resolveBlockedUntil = DateTime.now().add(const Duration(seconds: 60));
    throw SourceException(SourceExceptionCode.endpointUnresolved, config.api);
  }

  bool _looksLikeVod(dynamic body) {
    if (body is Map) {
      return body['list'] is List ||
          body['data'] is List ||
          body['class'] is List;
    }
    if (body is XmlDocument) {
      return body.findAllElements('video').isNotEmpty ||
          body.findAllElements('class').isNotEmpty ||
          body.findAllElements('list').isNotEmpty;
    }
    return false;
  }

  // ---------- HTTP ----------

  Future<http.Response> _get(
    String url, {
    Duration? timeout,
    CancelToken? cancel,
  }) async {
    if (cancel?.isCancelled ?? false) {
      throw SourceException(SourceExceptionCode.searchTimeout, '搜索已取消');
    }
    // 取消要真断在途 HTTP：只对自建 client 下手，注入的 client 由调用方管理。
    cancel?.whenCancelled(() {
      if (!_ownsClient) return;
      try {
        _client.close();
        _clientClosed = true;
      } catch (_) {}
    });
    if (_clientClosed) {
      _client = http.Client();
      _clientClosed = false;
    }
    final headers = <String, String>{
      if (!config.headers.containsKey('User-Agent'))
        'User-Agent': SourceImporter.defaultUa,
      ...config.headers,
    };
    final res = await _client
        .get(uriForRequest(url), headers: headers)
        .timeout(timeout ?? _timeout);
    if (res.statusCode < 200 || res.statusCode >= 400) {
      throw SourceException(
          SourceExceptionCode.network, 'HTTP ${res.statusCode} $url');
    }
    return res;
  }

  /// 字节 → 文本：UTF-8 优先，失败按 GBK（大量老采集站是 GBK/GB2312）。
  static String _decodeBody(http.Response res) {
    final bytes = res.bodyBytes;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  /// 响应体 → JSON Map 或 XML 文档（`<` 开头按 XML）。
  static dynamic _parsePayload(String body) {
    final text = body.trim();
    if (text.startsWith('<')) {
      try {
        return XmlDocument.parse(text);
      } catch (_) {
        return null;
      }
    }
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _call(String url, {CancelToken? cancel}) async {
    final res = await _get(url, cancel: cancel);
    final payload = _parsePayload(_decodeBody(res));
    if (payload == null) {
      throw SourceException(SourceExceptionCode.searchInvalid, url);
    }
    return payload;
  }

  // ---------- SourceAdapter ----------

  @override
  Future<List<SourceCategory>> categories() async {
    final endpoint = await _endpoint();
    // 短剧源自动标记：分类名含「短剧/微短剧/短视频」（MoonTVPlus duanju 语义）。
    final cats = await _categoriesOf(endpoint);
    config.shortDrama = cats.any((c) =>
        c.name.contains('短剧') || c.name.contains('短视频'));
    return cats;
  }

  Future<List<SourceCategory>> _categoriesOf(String endpoint) async {
    // 先试 ac=list（部分站只在这里给 class）。
    try {
      final payload = await _call('$endpoint?ac=list');
      final classes = _extractClasses(payload);
      if (classes.isNotEmpty) return classes;
    } on SourceException {
      // 回退扫 videolist。
    }
    final classes = <SourceCategory>[];
    final seen = <String>{};
    for (var page = 1; page <= 3; page++) {
      final payload = await _call('$endpoint?ac=videolist&pg=$page');
      for (final c in _extractClasses(payload)) {
        if (seen.add(c.id)) classes.add(c);
      }
      if (classes.isNotEmpty) break;
    }
    return classes;
  }

  List<SourceCategory> _extractClasses(dynamic payload) {
    final out = <SourceCategory>[];
    void add(String? id, String? name) {
      if (id == null || id.isEmpty || name == null || name.isEmpty) return;
      out.add(SourceCategory(id: id, name: name));
    }

    if (payload is Map) {
      final list = payload['class'];
      if (list is List) {
        for (final item in list) {
          if (item is! Map) continue;
          add(item['type_id']?.toString(), item['type_name']?.toString());
        }
      }
    } else if (payload is XmlDocument) {
      for (final node in payload.findAllElements('class')) {
        for (final ty in node.findElements('ty')) {
          add(ty.getAttribute('id'), ty.getAttribute('name'));
        }
      }
    }
    return out;
  }

  /// 分类过滤参数风格（'t' = MacCMS 标准 / 'tid' = 部分采集站变体）。
  /// 首次按 't' 请求，空结果自动换 'tid' 并记忆——两种风格在真实源里并存
  /// （非凡资源忽略 t、要 tid；端到端冒烟抓出）。
  String? _listParam;

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    final endpoint = await _endpoint();
    Future<SourcePage<UnifiedSeries>> fetch(String param) async {
      final params = categoryId == null || categoryId.isEmpty
          ? 'ac=videolist&pg=$page'
          : 'ac=videolist&$param=${Uri.encodeQueryComponent(categoryId)}&pg=$page';
      final payload = await _call('$endpoint?$params');
      return SourcePage(
        items: _itemsOf(payload),
        page: page,
        hasMore: _pageInfoOf(payload, page),
      );
    }

    if (categoryId == null || categoryId.isEmpty) return fetch('t');
    final preferred = _listParam ?? 't';
    final page1 = await fetch(preferred);
    if (page1.items.isNotEmpty || _listParam != null || page != 1) {
      return page1;
    }
    final other = preferred == 't' ? 'tid' : 't';
    final retry = await fetch(other);
    if (retry.items.isNotEmpty) {
      _listParam = other;
      return retry;
    }
    return page1;
  }

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    try {
      final endpoint = await _endpoint();
      if (cancel?.isCancelled ?? false) return;
      final encoded = Uri.encodeQueryComponent(query);
      // 三种口径真实并存：标准 videolist、老站 search、以及「只吃 wd/pg」的源。
      final attempts = <String>[
        '$endpoint?ac=videolist&wd=$encoded&pg=$page',
        '$endpoint?ac=search&wd=$encoded&pg=$page',
        '$endpoint?wd=$encoded&pg=$page',
      ];
      SourcePage<UnifiedSeries>? result;
      SourceException? lastError;
      for (final url in attempts) {
        if (cancel?.isCancelled ?? false) return;
        try {
          final payload = await _call(url, cancel: cancel);
          final items = _itemsOf(payload);
          // 空结果继续换下一种口径：有的站对错误参数返回 200 + 空列表。
          if (items.isEmpty && page <= 1) continue;
          result = SourcePage(
              items: items, page: page, hasMore: _pageInfoOf(payload, page));
          break;
        } on SourceException catch (e) {
          lastError = e;
        }
      }
      if (result == null) {
        if (lastError != null) throw lastError;
        result = SourcePage(
            items: const <UnifiedSeries>[], page: page, hasMore: false);
      }
      if (result.items.isEmpty && page > 1) {
        yield const SourceSearchDone();
        return;
      }
      yield SourceHits(
          items: result.items, page: page, hasMore: result.hasMore);
      yield const SourceSearchDone();
    } on SourceException catch (e) {
      yield SourceSearchFailed(e.code, e.detail);
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.toString());
    }
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    final endpoint = await _endpoint();
    final id = Uri.encodeQueryComponent(sourceItemId);
    dynamic payload;
    try {
      payload = await _call('$endpoint?ac=detail&ids=$id');
    } on SourceException {
      // 少数老站只认单数参数 `id`。
      try {
        payload = await _call('$endpoint?ac=detail&id=$id');
      } on SourceException {
        payload = await _call('$endpoint?ac=videolist&ids=$id');
      }
    }
    final items = _itemsOf(payload);
    if (items.isEmpty) {
      throw SourceException(SourceExceptionCode.searchInvalid, '详情为空 $sourceItemId');
    }
    return items.first;
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

  // ---------- 条目解析 ----------

  List<UnifiedSeries> _itemsOf(dynamic payload) {
    final out = <UnifiedSeries>[];
    void addFrom(Map vod) {
      final id = vod['vod_id']?.toString() ?? '';
      if (id.isEmpty) return;
      final lines = parsePlayLines(
        vod['vod_play_from']?.toString() ?? '',
        vod['vod_play_url']?.toString() ?? '',
        baseUrl: config.api,
      );
      out.add(UnifiedSeries(
        sourceKey: id == '' ? '' : config.id,
        sourceItemId: id,
        title: vod['vod_name']?.toString() ?? '',
        normalizedTitle: normalizeTitle(vod['vod_name']?.toString() ?? ''),
        year: vod['vod_year']?.toString() ?? '',
        // vod_pic 常见相对路径（/upload/...）或协议相对（//host/...）：
        // 不补全的话该源封面全挂（索尼影视类源的主诉）。
        coverUrl: _absoluteCover(vod['vod_pic']?.toString() ?? '', config.api),
        remarks: vod['vod_remarks']?.toString() ?? '',
        description: _stripHtml(vod['vod_content']?.toString() ?? ''),
        lines: lines,
        headers: config.headers,
      ));
    }

    if (payload is Map) {
      final list = payload['list'] ?? payload['data'];
      if (list is List) {
        for (final item in list) {
          if (item is Map) addFrom(item);
        }
      }
    } else if (payload is XmlDocument) {
      for (final video in payload.findAllElements('video')) {
        String? text(String tag) => video.findElements(tag).firstOrNull?.innerText;
        final id = text('id');
        if (id == null || id.isEmpty) continue;
        final dds = <PlayLine>[];
        final dl = video.findElements('dl').firstOrNull;
        if (dl != null) {
          final names = <String>[];
          final blocks = <String>[];
          for (final dd in dl.findElements('dd')) {
            names.add(dd.getAttribute('flag') ?? '');
            blocks.add(dd.innerText);
          }
          dds.addAll(parsePlayLines(names.join(r'$$$'), blocks.join(r'$$$'),
              baseUrl: config.api));
        }
        out.add(UnifiedSeries(
          sourceKey: config.id,
          sourceItemId: id,
          title: text('name') ?? '',
          normalizedTitle: normalizeTitle(text('name') ?? ''),
          year: text('year') ?? '',
          coverUrl: text('pic') ?? '',
          remarks: text('note') ?? '',
          description: _stripHtml(text('des') ?? ''),
          lines: dds,
          headers: config.headers,
        ));
      }
    }
    return out;
  }

  bool _pageInfoOf(dynamic payload, int page) {
    if (payload is Map) {
      final pagecount = payload['pagecount'];
      if (pagecount is num) return page < pagecount;
      final total = payload['total'];
      if (total is num) return page * 20 < total;
    }
    return false;
  }

  static String _stripHtml(String raw) =>
      raw.replaceAll(RegExp(r'<[^>]+>'), '').trim();
}

/// `vod_play_url` 解析（纯函数，tvbox PlaybackParser 同语义）：
/// `$$$` 分线路 → `#` 分集 → `lastIndexOf('$')` 分「标题$URL」；
/// 只保留 http(s) 直链，兼容 Markdown 包裹；线路 ≤4、每线路 ≤240 集。
List<PlayLine> parsePlayLines(String fromRaw, String urlRaw,
    {String baseUrl = ''}) {
  if (urlRaw.trim().isEmpty) return const [];
  final names = fromRaw.split(r'$$$');
  final blocks = urlRaw.split(r'$$$');
  final lines = <PlayLine>[];
    for (var i = 0; i < blocks.length && lines.length < _kMaxLines; i++) {
      final lineName = i < names.length && names[i].trim().isNotEmpty
          ? names[i].trim()
          : '线路${i + 1}';
      final episodes = <UnifiedEpisode>[];
      for (final seg in blocks[i].split('#')) {
        if (episodes.length >= _kMaxEpisodes) break;
        final cleaned = seg.trim();
        if (cleaned.isEmpty) continue;
        final sep = cleaned.lastIndexOf(r'$');
        String title;
        String url;
        if (sep <= 0 || sep == cleaned.length - 1) {
          title = '第${episodes.length + 1}集';
          url = cleaned;
        } else {
          title = cleaned.substring(0, sep).trim();
          url = cleaned.substring(sep + 1).trim();
        }
        // URL 部分做 Markdown 包裹剥离与 \/、\r\n 归一（切分后再清洗，
        // 否则「第1集$(https://…)」里的括号会挡住 lastIndexOf 的判定）。
        url = _stripMarkdown(_unslash(url));
        if (url.isEmpty) continue;
        // 相对播放地址（/play/xxx）按源 api 域名补全：不补则整条线路
        // 被 http 前缀检查丢弃（「有 25 集却无可播分集」的根因之一）。
        if (!url.startsWith('http://') && !url.startsWith('https://')) {
          if (baseUrl.isEmpty) continue;
          try {
            final base = Uri.tryParse(baseUrl);
            if (base == null || !base.hasScheme) continue;
            url = base.resolve(url.startsWith('//')
                ? '${base.scheme}:$url'
                : url).toString();
          } catch (_) {
            continue;
          }
        }
        episodes.add(UnifiedEpisode(
            title: title.isEmpty ? '第${episodes.length + 1}集' : title,
            url: url,
            index: episodes.length + 1));
      }
      if (episodes.isNotEmpty) {
        lines.add(PlayLine(name: lineName, episodes: episodes));
      }
    }
  // 默认线路 = 集数最多；并列时 m3u8 > mp4 > 其它（排序稳定，defaultLine 取第一个）。
  int rank(PlayLine l) {
    final first = l.episodes.first.url.toLowerCase();
    final bonus = first.contains('.m3u8')
        ? 50
        : first.contains('.mp4')
            ? 20
            : 0;
    return l.episodes.length * 1000 + bonus;
  }

  lines.sort((a, b) => rank(b).compareTo(rank(a)));
  return lines;
}

const int _kMaxLines = 4;
const int _kMaxEpisodes = 240;

/// 兼容 `(https://…)`、`[https://…]`、`([https://…])` 的多层 Markdown 包裹。
String _stripMarkdown(String seg) {
  var s = seg.trim();
  final wrapped = RegExp(r'^[\(\[（【]\s*(.+?)\s*[\)\]）】]$');
  while (true) {
    final m = wrapped.firstMatch(s);
    if (m == null) break;
    s = m.group(1)!;
  }
  return s.trim();
}

/// 兼容 `\/` 与 `\r\n` 归一。
String _unslash(String url) =>
    url.replaceAll(r'\/', '/').replaceAll('\r', '').replaceAll('\n', '');


/// 封面相对路径补全：`/path` 与 `//host/path` 以源 api 域名为基准。
String _absoluteCover(String raw, String api) {
  if (raw.isEmpty || raw.startsWith('http://') || raw.startsWith('https://')) {
    return raw;
  }
  try {
    if (raw.startsWith('//')) return 'https:$raw';
    final base = Uri.tryParse(api);
    if (base == null || !base.hasScheme) return raw;
    return base.resolve(raw).toString();
  } catch (_) {
    return raw;
  }
}
