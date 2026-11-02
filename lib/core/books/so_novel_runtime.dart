import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../sources/source_fetch.dart';
import 'book_source_model.dart';
import 'so_novel_func.dart';
import 'so_novel_rule.dart';
import 'so_novel_source.dart';

/// so-novel 方言运行时：search / bookInfo / toc / content（research §2.5，MVP 无分页）。
///
/// 与 legado 的 `BookSourceRuntime` 并列；`@js:` 走注入的 [runJs]（生产 = [SoNovelFunc]，
/// 测试 = 桩），网络复用 `fetchProbe`（GET）+ http（POST），GBK 按 meta 嗅探解码。
class SoNovelRuntime {
  SoNovelRuntime({
    String Function(String code, String input)? runJs,
    this.enforceSsrf = true,
    this.connectTimeout,
    this.readTimeout,
  }) : _runJsOverride = runJs;

  final String Function(String, String)? _runJsOverride;
  final bool enforceSsrf;
  final Duration? connectTimeout;
  final Duration? readTimeout;
  SoNovelFunc? _func;

  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120 Safari/537.36';

  String _runJs(String code, String input) =>
      (_runJsOverride ?? (_func ??= SoNovelFunc()).call)(code, input);

  String _selectorBase(SoRule rule, String? overrideUri) =>
      (overrideUri != null && overrideUri.isNotEmpty)
          ? overrideUri
          : rule.url;

  // ---------------- search ----------------

  Future<List<BookHit>> search(SoRule rule, String keyword) async {
    final s = rule.search;
    if (s == null || s.url.trim().isEmpty || s.result.trim().isEmpty) {
      return const [];
    }
    final url = _buildUrl(s.url, keyword);
    final body = await _request(
      url,
      method: s.method,
      form: s.method.toLowerCase() == 'post'
          ? _buildForm(s.data, keyword)
          : null,
      cookie: s.cookies,
      referer: _hostOf(url),
    );
    final doc = html_parser.parse(
        SoNovelRule.stepsOf(s.result).any((e) => e.lang == 'js')
            ? _runJs(_jsCodeOf(s.result), body)
            : body);
    final base = _selectorBase(rule, s.baseUri);
    final hits = _searchHits(doc, s, base);
    // search.nextPage：分页结果 union（TocParser:69-110 同款收集，顺序补抓，上限 5 页）。
    if (s.nextPage.trim().isNotEmpty) {
      try {
        final extra = await _paginationUrls(url, s.nextPage, doc);
        for (final pageUrl in extra.take(5)) {
          final pageBody = await _request(pageUrl, referer: _hostOf(pageUrl));
          hits.addAll(_searchHits(
              html_parser.parse(pageBody), s, _selectorBase(rule, s.baseUri)));
        }
      } catch (_) {
        // 分页抓取失败不影响第一页结果。
      }
    }
    final seen = <String>{};
    return [
      for (final h in hits)
        if (h.isMeaningful && seen.add(h.bookUrl)) h,
    ];
  }

  List<BookHit> _searchHits(Document doc, SoSearch s, String base) {
    final containers = SoNovelRule.selectList(doc, s.result);
    final nameSel = s.bookName;
    return [
      for (final el in containers)
        if (SoNovelRule.extract(el, nameSel, baseUri: base, runJs: _runJs)
            .trim()
            .isNotEmpty)
          BookHit(
            bookUrl: SoNovelRule.extract(el, nameSel,
                baseUri: base, runJs: _runJs, type: SoContentType.href),
            name: SoNovelRule.extract(el, nameSel, baseUri: base, runJs: _runJs),
            author: SoNovelRule.extract(el, s.author, baseUri: base, runJs: _runJs),
            lastChapter:
                SoNovelRule.extract(el, s.latestChapter, baseUri: base, runJs: _runJs),
            kind: SoNovelRule.extract(el, s.category, baseUri: base, runJs: _runJs),
          ),
    ];
  }

  // ---------------- bookInfo ----------------

  Future<BookMeta> bookInfo(SoRule rule, String bookUrl) async {
    final b = rule.book;
    final body = await _request(bookUrl, referer: _hostOf(bookUrl));
    final doc = html_parser.parse(body);
    final base = bookUrl;
    String f(String sel, {String meta = ''}) {
      if (sel.isNotEmpty) {
        return SoNovelRule.extract(doc, sel, baseUri: base, runJs: _runJs);
      }
      return meta.isEmpty
          ? ''
          : SoNovelRule.extract(doc, 'meta[property="$meta"]',
              baseUri: base, runJs: _runJs);
    }

    return BookMeta(
      name: f(b.bookName, meta: 'og:novel:book_name'),
      author: f(b.author, meta: 'og:novel:author').replaceAll('作者：', ''),
      intro: f(b.intro, meta: 'description')
          .replaceAll(RegExp(r'\s+'), '')
          .trim(),
      coverUrl: b.coverUrl.isNotEmpty
          ? SoNovelRule.extract(doc, '${b.coverUrl}@src',
              baseUri: base, runJs: _runJs)
          : SoNovelRule.extract(doc, 'meta[property="og:image"]@content',
              baseUri: base, runJs: _runJs),
      lastChapter: f(b.latestChapter, meta: 'og:novel:latest_chapter_name'),
    );
  }

  // ---------------- toc ----------------

  Future<List<BookTocItem>> toc(SoRule rule, String bookUrl) async {
    final t = rule.toc;
    var tocUrl = bookUrl;
    if (t.url.trim().isNotEmpty) {
      final id = _extractId(rule.book.url, bookUrl);
      tocUrl = id != null ? t.url.replaceAll('%s', id) : t.url;
    }
    final firstBody = await _request(tocUrl, referer: _hostOf(tocUrl));
    final firstDoc = html_parser.parse(firstBody);
    // toc.nextPage：分页 URL 收集（option 一次拿全 / 单链接递归），逐页拼接。
    final pageUrls = <String>[tocUrl];
    if (t.nextPage.trim().isNotEmpty) {
      try {
        pageUrls.addAll(await _paginationUrls(tocUrl, t.nextPage, firstDoc));
      } catch (_) {
        // 分页收集失败退化为单页目录。
      }
    }
    final chapters = <BookTocItem>[];
    for (var i = 0; i < pageUrls.length && i < 30; i++) {
      final pageUrl = pageUrls[i];
      final doc = i == 0 ? firstDoc : html_parser.parse(await _request(pageUrl, referer: _hostOf(pageUrl)));
      final pageBase = pageUrl;
      Node scope = doc;
      if (t.list.trim().isNotEmpty) {
        final frag = SoNovelRule.extract(doc, t.list,
            baseUri: pageBase, runJs: _runJs, html: true);
        scope = html_parser.parseFragment(frag);
      }
      final items = SoNovelRule.selectList(scope, t.item);
      var pageChapters = [
        for (final el in items)
          BookTocItem(
            title: el.text.trim(),
            url: el.attributes['href'] != null
                ? _abs(el.attributes['href']!, pageBase)
                : '',
          ),
      ];
      // isDesc 是「页内倒序遍历」（TocParser:169-173），不是整表反转。
      if (t.isDesc) {
        pageChapters = pageChapters.reversed.toList();
      }
      chapters.addAll(pageChapters);
    }
    return chapters;
  }

  // ---------------- content ----------------

  Future<String> content(SoRule rule, String chapterUrl) async {
    final c = rule.chapter;
    // chapter.nextPage：分页正文循环拼接（ChapterParser:100-150）。
    final htmlParts = <String>[];
    final visited = <String>{};
    var currentUrl = chapterUrl;
    while (visited.length < 30 && !visited.contains(currentUrl)) {
      visited.add(currentUrl);
      final body = await _request(currentUrl, referer: _hostOf(currentUrl));
      final doc = html_parser.parse(body);
      htmlParts.add(SoNovelRule.extract(doc, c.content,
          baseUri: currentUrl, runJs: _runJs, html: true));
      if (c.nextPage.trim().isEmpty) break;
      // 下一页链接：选择器取 href（Java ATTR_HREF）；文本用于终止判定。
      final nextText = SoNovelRule.extract(doc, c.nextPage,
          baseUri: currentUrl, runJs: _runJs);
      final nextUrl = SoNovelRule.extract(doc, c.nextPage,
          baseUri: currentUrl, runJs: _runJs, type: SoContentType.href);
      if (nextUrl.isEmpty || nextUrl == currentUrl) break;
      // isLastPage 启发式（ChapterParser:177-188 子集）：按钮文本是「下一章」类
      // 即为章节切换，停止分页（「下一页」不算）。
      if (RegExp(r'下一章|书末页|没有了|已经是最新').hasMatch(nextText)) break;
      if (c.nextChapterLink.trim().isNotEmpty) {
        try {
          if (RegExp(SoNovelRule.selectorOf(c.nextChapterLink)).hasMatch(nextUrl)) {
            break;
          }
        } catch (_) {/* 终止正则非法：忽略 */}
      }
      currentUrl = nextUrl;
    }
    var html = htmlParts.join('\n');
    // filterTag：删除命中标签（逗号分隔）。
    for (final tag in c.filterTag.split(',')) {
      final t = tag.trim();
      if (t.isEmpty) continue;
      html = html.replaceAll(RegExp('<$t[^>]*>[\\s\\S]*?</$t>', caseSensitive: false), '');
    }
    // filterTxt：广告正则（| 分隔）删除。
    for (final pat in c.filterTxt.split('|')) {
      final p = pat.trim();
      if (p.isEmpty) continue;
      try {
        html = html.replaceAll(RegExp(p), '');
      } catch (_) {}
    }
    return _toParagraphs(html, closed: c.paragraphTagClosed, tag: c.paragraphTag);
  }

  // ---------------- 网络 / 工具 ----------------

  Future<String> _request(
    String url, {
    String method = 'get',
    String? form,
    String? cookie,
    String? referer,
  }) async {
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      if (referer != null && referer.isNotEmpty) 'Referer': referer,
      if (cookie != null && cookie.isNotEmpty) 'Cookie': cookie,
    };
    if (method.toLowerCase() == 'post' && form != null) {
      final res = await http
          .post(Uri.parse(url), headers: {...headers,
            'Content-Type': 'application/x-www-form-urlencoded'}, body: form)
          .timeout(readTimeout ?? const Duration(seconds: 15));
      if (res.statusCode >= 400) {
        throw SoNovelException('HTTP ${res.statusCode}');
      }
      return _decode(res.bodyBytes);
    }
    final result = await fetchProbe(
      url,
      headers: headers,
      enforceSsrf: enforceSsrf,
      connectTimeout: connectTimeout ?? const Duration(seconds: 8),
      readTimeout: readTimeout ?? const Duration(seconds: 15),
      maxBytes: 4 * 1024 * 1024,
    );
    if (!result.ok || result.bytes == null) {
      throw SoNovelException(result.error.isEmpty ? '请求失败' : result.error);
    }
    return _decode(result.bytes!);
  }

  String _decode(List<int> bytes) {
    final head = String.fromCharCodes(
        bytes.take(2048).map((b) => b < 128 ? b : 32));
    final cs = RegExp(r'charset=["\x27]?\s*([a-zA-Z0-9-]+)')
        .firstMatch(head)
        ?.group(1)
        ?.toLowerCase();
    if (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030') {
      try {
        return gbk.decode(bytes);
      } catch (_) {}
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  String _buildUrl(String template, String keyword) {
    if (template.contains('@js:')) return _runJs(_jsCodeOf(template), keyword);
    return template.replaceAll('%s', Uri.encodeComponent(keyword));
  }

  String _buildForm(String data, String keyword) {
    // 宽松 `{k: %s, k2: v}`：把 %s 填 keyword（不 URL 编码，交给 http body 编码）。
    return data.replaceAll('%s', keyword);
  }

  String _jsCodeOf(String query) {
    final steps = SoNovelRule.stepsOf(query);
    final js = steps.where((s) => s.lang == 'js').toList();
    return js.isEmpty ? '' : js.first.code;
  }

  String? _extractId(String urlRegex, String bookUrl) {
    if (urlRegex.trim().isEmpty) return null;
    try {
      final m = RegExp(SoNovelRule.selectorOf(urlRegex)).firstMatch(bookUrl);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }

  String _hostOf(String url) {
    final u = Uri.tryParse(url);
    if (u == null || !u.hasScheme) return '';
    return '${u.scheme}://${u.host}';
  }

  String _abs(String href, String base) {
    final b = Uri.tryParse(base);
    if (b == null) return href;
    return b.resolve(href).toString();
  }

  /// 分页 URL 收集（TocParser:69-110 语义）：多个 `<option>`(value)/`<a>`(href)
  /// 一次拿全；单个则递归「下一页」，visited 防环，上限 50 轮。
  Future<List<String>> _paginationUrls(
      String firstUrl, String selector, Document firstDoc) async {
    final urls = <String>[];
    var currentDoc = firstDoc;
    var currentUrl = firstUrl;
    var rounds = 0;
    while (rounds++ < 50) {
      final els = SoNovelRule.selectList(currentDoc, selector);
      if (els.isEmpty) break;
      final found = <String>[];
      for (final el in els) {
        final v = el.attributes['value'] ?? el.attributes['href'] ?? '';
        if (v.trim().isEmpty) continue;
        final abs = _abs(v, currentUrl);
        if (abs.isNotEmpty && abs != currentUrl && !urls.contains(abs)) {
          found.add(abs);
        }
      }
      if (found.length >= 2) {
        // 一次性拿全（下拉 option / 多页码 <a>）。
        urls.addAll(found);
        break;
      }
      if (found.length == 1) {
        final next = found.first;
        if (next == firstUrl || urls.contains(next)) break;
        urls.add(next);
        currentDoc =
            html_parser.parse(await _request(next, referer: _hostOf(next)));
        currentUrl = next;
        continue;
      }
      break;
    }
    return urls;
  }

  String _toParagraphs(String html,
      {required bool closed, required String tag}) {
    var text = html
        .replaceAll(RegExp('<br\\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp('</p>', caseSensitive: false), '\n')
        .replaceAll(RegExp('<[^>]+>'), '')
        .replaceAll('&nbsp;', ' ');
    if (!closed && tag.trim().isNotEmpty) {
      try {
        text = text.replaceAll(RegExp(tag), '\n');
      } catch (_) {}
    }
    return text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .join('\n');
  }
}

/// bookInfo 的轻量返回（聚合层再映射到 UI）。
class BookMeta {
  const BookMeta({
    this.name = '',
    this.author = '',
    this.intro = '',
    this.coverUrl = '',
    this.lastChapter = '',
  });
  final String name;
  final String author;
  final String intro;
  final String coverUrl;
  final String lastChapter;
}

/// so-novel 运行时异常（网络/解析）。
class SoNovelException implements Exception {
  SoNovelException(this.message);
  final String message;
  @override
  String toString() => message;
}
