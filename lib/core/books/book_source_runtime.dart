import 'dart:convert';

import 'package:http/http.dart' as http;

import '../sources/source_fetch.dart';
import '../sources/source_import.dart';
import 'book_rule.dart';
import 'book_source_model.dart';

/// 书源运行时：search / bookInfo / toc / content 四连。
///
/// GET 走 [fetchProbe]（复用超时/限流/SSRF 防护）；POST 需要 body，
/// 自行发起但同样先过 `SourceImporter.validateImportUrl` 的 SSRF 校验。
class BookSourceRuntime {
  BookSourceRuntime({
    this.connectTimeout,
    this.readTimeout,
    this.enforceSsrf = true,
  });

  final Duration? connectTimeout;
  final Duration? readTimeout;

  /// 生产必须开（书源服务器不允许指向本机）；本地 HTTP 夹具测试传 false。
  final bool enforceSsrf;

  /// 搜索：关键词 → 一页书条目。
  Future<List<BookHit>> search(
    BookSource source,
    String query, {
    int page = 1,
  }) async {
    if (source.searchUrl.trim().isEmpty) {
      throw BookSourceException('源没有配置搜索地址');
    }
    final (rawUrl, options) = BookRule.parseSearchUrl(source.searchUrl);
    // legado 很多源的 searchUrl 是相对路径（如 `/modules/article/search.php`），
    // 必须按 bookSourceUrl 补成绝对地址，否则被 SSRF 判「非法地址」→ 直接搜不到。
    final url = _resolveAgainst(
        BookRule.fillUrl(rawUrl, key: query, page: page), source.url);
    final body = BookRule.fillUrl(options.body, key: query, page: page);
    final text = await _request(
      url,
      method: options.method,
      body: options.isPost ? body : null,
      headers: options.headers,
    );
    return _parseHits(source, text, baseUrl: url);
  }

  List<BookHit> _parseHits(
    BookSource source,
    String text, {
    String baseUrl = '',
  }) {
    final rule = source.ruleSearch;
    if (rule.bookList.trim().isEmpty) {
      throw BookSourceException('源没有配置搜索列表规则');
    }
    final page = _autoDecode(text);
    final nodes = BookRule.evalList(page, rule.bookList);
    return [
      for (final node in nodes)
        BookHit(
          bookUrl: BookRule.evalString(node, rule.bookUrl, baseUrl: baseUrl),
          name: BookRule.evalString(node, rule.name),
          author: BookRule.evalString(node, rule.author),
          coverUrl: BookRule.evalString(node, rule.coverUrl),
          intro: BookRule.evalString(node, rule.intro),
          kind: BookRule.evalString(node, rule.kind),
          lastChapter: BookRule.evalString(node, rule.lastChapter),
        ),
    ];
  }

  /// 详情 + 目录：bookUrl → 书信息（含目录）。
  Future<BookInfo> bookInfo(BookSource source, String bookUrl) async {
    final base = _resolveAgainst(bookUrl, source.url);
    final text = await _request(base);
    final page = _autoDecode(text);
    final rule = source.ruleBookInfo;
    final info = BookInfo(
      name: BookRule.evalString(page, rule.name),
      author: BookRule.evalString(page, rule.author),
      coverUrl: BookRule.evalString(page, rule.coverUrl, baseUrl: base),
      intro: BookRule.evalString(page, rule.intro),
      tocUrl: rule.tocUrl.trim().isEmpty
          ? base
          : BookRule.evalString(page, rule.tocUrl, baseUrl: base),
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
    final nodes = BookRule.evalList(page, rule.chapterList);
    return [
      for (final node in nodes)
        BookTocItem(
          title: BookRule.evalString(node, rule.chapterName),
          url: BookRule.evalString(node, rule.chapterUrl, baseUrl: base),
          isVolume: BookRule.evalString(node, rule.isVolume).isNotEmpty,
        ),
    ];
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
    final (expr, clean) = _splitContentRule(rule.content);
    final value = BookRule.evalString(page, expr, baseUrl: base);
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

  /// 正文规则同样支持 `##` 清洗尾缀。
  static (String, (String, String)?) _splitContentRule(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) return (rule.trim(), null);
    final expr = rule.substring(0, idx).trim();
    final rest = rule.substring(idx + 2);
    final sep = rest.indexOf('##');
    if (sep < 0) return (expr, (rest, ''));
    return (expr, (rest.substring(0, sep), rest.substring(sep + 2)));
  }

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
