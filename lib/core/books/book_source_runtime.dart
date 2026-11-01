import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sources/source_fetch.dart';
import '../sources/source_import.dart';
import '../error_log.dart';
import 'book_rule.dart';
import 'book_source_model.dart';
import 'legado_js/legado_js_engine.dart';

/// 书源运行时：search / bookInfo / toc / content 四连。
///
/// GET 走 [fetchProbe]（复用超时/限流/SSRF 防护）；POST 需要 body，
/// 自行发起但同样先过 `SourceImporter.validateImportUrl` 的 SSRF 校验。
/// 含 js 规则的源按需走 [LegadoJsEngine]（缓存/cookie 会话按源隔离）。
class BookSourceRuntime {
  BookSourceRuntime({
    this.connectTimeout,
    this.readTimeout,
    this.enforceSsrf = true,
    LegadoJsEngine? jsEngine,
  }) : _jsEngineOverride = jsEngine;

  final Duration? connectTimeout;
  final Duration? readTimeout;

  /// 生产必须开（书源服务器不允许指向本机）；本地 HTTP 夹具测试传 false。
  final bool enforceSsrf;

  final LegadoJsEngine? _jsEngineOverride;
  LegadoJsEngine? _jsEngine;
  LegadoJsEngine get _engine =>
      _jsEngine ??= _jsEngineOverride ??
          LegadoJsEngine(enforceSsrf: enforceSsrf);

  /// js 会话状态（cache/cookie jar），按源隔离——聚合搜索并发跑多源不能串台。
  final _sessionCache = <String, Map<String, String>>{};
  final _sessionCookies = <String, Map<String, String>>{};

  JsRuleRunner _runnerFor(
    BookSource source, {
    Object? key,
    Object? page,
    Map<String, Object?> book = const {},
    Map<String, Object?> chapter = const {},
  }) =>
      _JsRunner(this, source,
          key: key, page: page, book: book, chapter: chapter);

  /// 搜索：关键词 → 一页书条目。
  Future<List<BookHit>> search(
    BookSource source,
    String query, {
    int page = 1,
  }) async {
    if (source.searchUrl.trim().isEmpty) {
      throw BookSourceException('源没有配置搜索地址');
    }
    final runner = _runnerFor(source, key: query, page: page);
    final (rawUrl, options) = await BookRule.parseSearchUrlAsync(
      source.searchUrl,
      key: query,
      page: page,
      js: runner,
      baseUrl: source.url,
    );
    // legado 很多源的 searchUrl 是相对路径：按 bookSourceUrl 补全（js 产出的
    // 绝对地址原样透传）。
    final url = _resolveAgainst(rawUrl, source.url);
    final body = BookRule.fillUrl(options.body, key: query, page: page);
    final text = await _request(
      url,
      method: options.method,
      body: options.isPost ? body : null,
      headers: options.headers,
    );
    return _parseHits(source, text, baseUrl: url, runner: runner);
  }

  Future<List<BookHit>> _parseHits(
    BookSource source,
    String text, {
    String baseUrl = '',
    JsRuleRunner? runner,
  }) async {
    final rule = source.ruleSearch;
    if (rule.bookList.trim().isEmpty) {
      throw BookSourceException('源没有配置搜索列表规则');
    }
    final page = _autoDecode(text);
    final nodes = await BookRule.evalListAsync(page, rule.bookList, js: runner);
    final hits = <BookHit>[];
    for (final node in nodes) {
      hits.add(BookHit(
        bookUrl: await BookRule.evalStringAsync(node, rule.bookUrl,
            baseUrl: baseUrl, js: runner),
        name: await BookRule.evalStringAsync(node, rule.name, js: runner),
        author:
            await BookRule.evalStringAsync(node, rule.author, js: runner),
        coverUrl: await BookRule.evalStringAsync(node, rule.coverUrl,
            baseUrl: baseUrl, js: runner),
        intro: await BookRule.evalStringAsync(node, rule.intro, js: runner),
        kind: await BookRule.evalStringAsync(node, rule.kind, js: runner),
        lastChapter: await BookRule.evalStringAsync(node, rule.lastChapter,
            js: runner),
      ));
    }
    return hits;
  }

  /// 详情 + 目录：bookUrl → 书信息（含目录）。
  Future<BookInfo> bookInfo(BookSource source, String bookUrl) async {
    final base = _resolveAgainst(bookUrl, source.url);
    final text = await _request(base);
    final page = _autoDecode(text);
    final rule = source.ruleBookInfo;
    final runner = _runnerFor(source, book: {'bookUrl': bookUrl});
    final info = BookInfo(
      name: await BookRule.evalStringAsync(page, rule.name, js: runner),
      author: await BookRule.evalStringAsync(page, rule.author, js: runner),
      coverUrl: await BookRule.evalStringAsync(page, rule.coverUrl,
          baseUrl: base, js: runner),
      intro: await BookRule.evalStringAsync(page, rule.intro, js: runner),
      tocUrl: rule.tocUrl.trim().isEmpty
          ? base
          : await BookRule.evalStringAsync(page, rule.tocUrl,
              baseUrl: base, js: runner),
    );
    info.chapters = await toc(source, info.tocUrl);
    return info;
  }

  /// 目录：目录页 → 章节列表。
  Future<List<BookTocItem>> toc(BookSource source, String tocUrl) async {
    final base = _resolveAgainst(tocUrl, source.url);
    final text = await _request(base);
    final page = _autoDecode(text);
    final rule = source.ruleToc;
    if (rule.chapterList.trim().isEmpty) {
      throw BookSourceException('源没有配置目录规则');
    }
    final runner = _runnerFor(source, book: {'bookUrl': tocUrl});
    final nodes =
        await BookRule.evalListAsync(page, rule.chapterList, js: runner);
    final items = <BookTocItem>[];
    for (final node in nodes) {
      items.add(BookTocItem(
        title: await BookRule.evalStringAsync(node, rule.chapterName,
            js: runner),
        url: await BookRule.evalStringAsync(node, rule.chapterUrl,
            baseUrl: base, js: runner),
        isVolume: (await BookRule.evalStringAsync(node, rule.isVolume,
                js: runner))
            .isNotEmpty,
      ));
    }
    return items;
  }

  /// 正文：章节地址 → 章节文本（带 `##` 清洗）。
  Future<String> content(BookSource source, String chapterUrl) async {
    final base = _resolveAgainst(chapterUrl, source.url);
    final text = await _request(base);
    final page = _autoDecode(text);
    final rule = source.ruleContent;
    if (rule.content.trim().isEmpty) {
      throw BookSourceException('源没有配置正文规则');
    }
    final (expr, clean) = BookRule.splitClean(rule.content);
    final value = await BookRule.evalStringAsync(
      page,
      expr,
      baseUrl: base,
      js: _runnerFor(source, chapter: {'url': chapterUrl}),
    );
    return BookRule.applyClean(value, clean);
  }

  /// 相对地址按书源 base（`bookSourceUrl`）补全；已是绝对地址原样返回。
  /// legado 的 searchUrl / 字段规则常给相对路径，不补全会被 SSRF 判非法地址。
  static String _resolveAgainst(String url, String base) {
    if (url.isEmpty) return url;
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.hasScheme && parsed.host.isNotEmpty) {
      return url;
    }
    final b = Uri.tryParse(base);
    if (b == null || !b.hasScheme) return url;
    return b.resolve(url).toString();
  }

  /// 正文规则 `##` 清洗尾缀拆分已收敛到 [BookRule.splitClean]。

  /// 页面解码：JSON 首先尝试；否则保留原始文本（HTML 规则求值自己 parse）。
  static Object _autoDecode(String text) {
    final trimmed = text.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonDecode(text);
      } catch (_) {/* 落回 HTML */}
    }
    return text;
  }

  Future<String> _request(
    String url, {
    String method = 'GET',
    String? body,
    Map<String, String> headers = const {},
  }) async {
    // 书源服务器同样不允许指向本机（SSRF 契约与影视源一致）。
    if (enforceSsrf) SourceImporter.validateImportUrl(url);
    if (method.toUpperCase() == 'POST') {
      final response = await http
          .post(
            Uri.parse(url),
            body: body,
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
              ...headers,
            },
          )
          .timeout(readTimeout ?? const Duration(seconds: 10));
      if (response.statusCode >= 400) {
        throw BookSourceException('HTTP ${response.statusCode}');
      }
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    }
    final result = await fetchProbe(
      url,
      connectTimeout: connectTimeout ?? const Duration(milliseconds: 6000),
      readTimeout: readTimeout ?? const Duration(seconds: 8),
      maxBytes: 4 * 1024 * 1024,
      // 与本类的开关保持一致：本地夹具测试也要能打回环地址。
      enforceSsrf: enforceSsrf,
    );
    if (!result.ok) {
      throw BookSourceException(
          result.error.isEmpty ? '请求失败' : result.error);
    }
    final bytes = result.bytes;
    if (bytes == null || bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 书详情（含目录）。
class BookInfo {
  BookInfo({
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.tocUrl = '',
  });

  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String tocUrl;
  List<BookTocItem> chapters = const [];
}

/// 书源层异常（UI 只显示 message，不抛原始堆栈）。
class BookSourceException implements Exception {
  const BookSourceException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// js 规则求值 runner：绑定一个源 + 一次链路调用的 bindings，桥到
/// [LegadoJsEngine]；cache/cookie 会话按源隔离（聚合搜索并发不串台）。
class _JsRunner implements JsRuleRunner {
  _JsRunner(
    this._rt,
    this._source, {
    this.key,
    this.page,
    this.book = const {},
    this.chapter = const {},
  });

  final BookSourceRuntime _rt;
  final BookSource _source;
  final Object? key;
  final Object? page;
  final Map<String, Object?> book;
  final Map<String, Object?> chapter;

  @override
  Future<Object?> evalJs(
    String code, {
    Object? result,
    String baseUrl = '',
    Map<String, Object?> extra = const {},
  }) async {
    final engine = _rt._engine;
    final cache = _rt._sessionCache.putIfAbsent(_source.url, () => {});
    final cookies = _rt._sessionCookies.putIfAbsent(_source.url, () => {});
    final res = await engine.eval(
      code,
      bindings: {
        'result': '$result',
        'baseUrl': baseUrl,
        'key': key,
        'page': page,
        'book': book,
        'chapter': chapter,
        'sourceKey': _source.url,
        ...extra,
      },
      jsLib: _source.jsLib,
      cacheIn: Map.unmodifiable(cache),
      cookieIn: Map.unmodifiable(cookies),
    );
    // cacheOut/cookieOut 是入参快照的完整最新态：整体回写会话。
    cache
      ..clear()
      ..addAll(res.cacheOut);
    cookies
      ..clear()
      ..addAll(res.cookieOut);
    for (final line in res.logs) {
      ErrorLog.instance.record('书源 js', '${_source.name}：$line');
    }
    return res.value;
  }
}
