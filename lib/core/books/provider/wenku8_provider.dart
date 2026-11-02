/// 内置 **轻小说文库（Wenku8）** 在线源 provider（第三种方言）。
///
/// 公开页只读：搜索 / 分类 / 排行 / 详情 / 分卷目录 / 正文 / 封面。
/// 不做登录、云书架、书评。站点是 GBK 老站，全部响应经 `decodeMarkupBytes`。
///
/// 与规则源的区别：站点结构固定但改版频繁，这里用「多选择器 + 结构兜底」的
/// 专用解析器（`wenku8_page.dart`），比写一份 legado 规则更抗改版，也不会被
/// 规则引擎的 js 闸门挡住。
library;

import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

import '../../book_markup.dart';
import '../../sources/source_fetch.dart';
import '../../sources/source_import.dart';
import '../book_source_model.dart';
import '../book_source_runtime.dart' show BookSourceException;
import 'book_source_provider.dart';
import 'source_probe.dart';
import 'wenku8_page.dart';

/// 抓取函数（测试注入纯函数，生产走 [fetchProbe]）。
typedef Wenku8Fetch = Future<String> Function(Uri url);

const String kWenku8DefaultBase = 'https://www.wenku8.net';

/// 内置源默认 UA：站点对移动端 UA 更宽容（分卷目录结构一致）。
const String _kWenku8UserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0 Safari/537.36';

class Wenku8Provider implements BookSourceProvider {
  Wenku8Provider({
    this.fetch,
    this.enforceSsrf = true,
    this.baseUrl = kWenku8DefaultBase,
  });

  /// 注入的抓取函数（null = 生产走 [fetchProbe]）。
  final Wenku8Fetch? fetch;
  final bool enforceSsrf;

  /// 未传 `source` 的浏览入口使用的基础地址。
  final String baseUrl;

  @override
  BookSourceFormat get format => BookSourceFormat.wenku8;

  @override
  String get displayName => 'Wenku8';

  @override
  bool get builtin => true;

  /// 内置源**默认停用**：站点 2026 起要求登录 + Cloudflare 校验，未填 Cookie 时
  /// 每次请求只会 403 污染聚合搜索。有账号的用户可启用并填 Cookie/UA。
  @override
  List<BookSource> get builtinSources => const [
        BookSource(
          url: kWenku8DefaultBase,
          name: '轻小说文库（Wenku8）',
          group: '内置 · 需登录',
          enabled: false,
          format: BookSourceFormat.wenku8,
        ),
      ];

  // ------------------------------------------------------------------ 四连

  @override
  Future<List<BookHit>> search(BookSource source, String query,
      {int page = 1}) async {
    final base = _baseOf(source);
    final encoded = _gbkQuery(query);
    final uri = Uri.parse(
      '$base/modules/article/search.php'
      '?searchtype=articlename&searchkey=$encoded&page=$page',
    );
    final html = await _get(uri, source: source);
    return parseWenku8ListPage(html, baseUrl: base);
  }

  @override
  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    final ref = Wenku8BookRef.tryParse(bookUrl);
    if (ref == null) {
      throw BookSourceException('不是 Wenku8 书籍地址：$bookUrl');
    }
    final base = _baseOf(source);
    final html = await _get(Uri.parse('$base${ref.pagePath}'), source: source);
    final info = parseWenku8Detail(html, baseUrl: base);
    final chapters = parseWenku8Toc(html, baseUrl: base);
    if (info.name.isEmpty && chapters.isEmpty) {
      throw const Wenku8PageException('详情页', '书名与目录都为空');
    }
    return BookDetailData(
      name: info.name,
      author: info.author,
      intro: info.intro,
      coverUrl: info.coverUrl,
      chapters: chapters,
    );
  }

  @override
  Future<String> content(BookSource source, String chapterUrl) async {
    final ref = Wenku8ChapterRef.tryParse(chapterUrl);
    if (ref == null) {
      throw BookSourceException('不是 Wenku8 章节地址：$chapterUrl');
    }
    final base = _baseOf(source);
    final html = await _get(Uri.parse('$base${ref.pagePath}'), source: source);
    return parseWenku8Content(html);
  }

  @override
  Future<BookSourceCheck> probe(
    BookSource source, {
    String query = kDefaultProbeQuery,
    bool fetchContent = true,
  }) async {
    BookHit? hit;
    try {
      final hits = await search(source, query);
      for (final h in hits) {
        if (h.isMeaningful) {
          hit = h;
          break;
        }
      }
      if (hit == null) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.search,
          reason: '搜索无结果（站点可能改版或需要换镜像域名）',
        );
      }
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.search,
        reason: describeProbeFailure(e),
      );
    }

    var chapterCount = 0;
    List<BookTocItem> chapters;
    try {
      final info = await detail(source, hit.bookUrl);
      chapters = info.chapters;
      chapterCount =
          chapters.where((c) => c.title.isNotEmpty && c.url.isNotEmpty).length;
      if (chapterCount == 0) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.bookInfo,
          reason: '目录为空',
          sampleHit: hit,
        );
      }
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.bookInfo,
        reason: describeProbeFailure(e),
        sampleHit: hit,
      );
    }

    var contentLength = 0;
    if (fetchContent) {
      try {
        final text = await content(
          source,
          chapters.firstWhere((c) => c.url.isNotEmpty).url,
        );
        contentLength = text.trim().length;
        if (contentLength < 30) {
          return BookSourceCheck(
            source: source,
            ok: false,
            stage: BookCheckStage.content,
            reason: '正文过短（$contentLength 字）',
            sampleHit: hit,
            sampleChapterCount: chapterCount,
          );
        }
      } catch (e) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.content,
          reason: describeProbeFailure(e),
          sampleHit: hit,
          sampleChapterCount: chapterCount,
        );
      }
    }
    return BookSourceCheck(
      source: source,
      ok: true,
      sampleHit: hit,
      sampleChapterCount: chapterCount,
      sampleContentLength: contentLength,
    );
  }

  // ------------------------------------------------------------------ 浏览

  /// 站点真实分类（首页导航解析；解析不到返回空表，UI 隐藏分类入口）。
  Future<List<Wenku8Class>> classes({BookSource? source}) async {
    final base = source == null ? baseUrl : _baseOf(source);
    final html = await _get(Uri.parse('$base/index.php'), source: source);
    return parseWenku8Classes(html);
  }

  /// 分类列表。
  Future<List<BookHit>> browseClass(
    String classId, {
    int page = 1,
    BookSource? source,
  }) async {
    final base = source == null ? baseUrl : _baseOf(source);
    final html = await _get(
      Uri.parse(
          '$base/modules/article/articlelist.php?class=$classId&page=$page'),
      source: source,
    );
    return parseWenku8ListPage(html, baseUrl: base);
  }

  /// 排行榜。
  Future<List<BookHit>> browseRank(
    Wenku8Rank rank, {
    int page = 1,
    BookSource? source,
  }) async {
    final base = source == null ? baseUrl : _baseOf(source);
    final html = await _get(
      Uri.parse(
          '$base/modules/article/toplist.php?sort=${rank.sort}&page=$page'),
      source: source,
    );
    return parseWenku8ListPage(html, baseUrl: base);
  }

  // ------------------------------------------------------------------ 内部

  String _baseOf(BookSource source) {
    final raw = source.url.trim();
    if (raw.isEmpty) return baseUrl;
    return raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
  }

  Future<String> _get(Uri uri, {BookSource? source}) async {
    final injected = fetch;
    if (injected != null) return injected(uri);

    final url = uri.toString();
    if (enforceSsrf) SourceImporter.validateImportUrl(url);
    final cookie = (source?.cookie ?? '').trim();
    // Cloudflare 的 cf_clearance 与 UA 绑定：用户填了 UA 就必须用它。
    final ua = (source?.userAgent ?? '').trim();
    final base = source == null ? baseUrl : _baseOf(source);
    final result = await fetchProbe(
      url,
      enforceSsrf: enforceSsrf,
      maxBytes: 2 * 1024 * 1024,
      headers: {
        'User-Agent': ua.isNotEmpty ? ua : _kWenku8UserAgent,
        'Accept':
            'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.6',
        'Referer': '$base/index.php',
        if (cookie.isNotEmpty) 'Cookie': cookie,
      },
      connectTimeout: const Duration(seconds: 8),
      readTimeout: const Duration(seconds: 15),
    );
    if (!result.ok) {
      if (result.statusCode == 403) {
        throw BookSourceException(cookie.isEmpty
            ? 'HTTP 403：站点启用了 Cloudflare 人机校验，普通请求会被拦。'
                '解决办法：浏览器打开站点并通过校验后，把 Cookie 里的 '
                'cf_clearance 与该浏览器的 User-Agent 一起填到'
                '「书源管理 → 轻小说文库 → Cookie」；或把书源地址换成可直连的镜像域名。'
            : 'HTTP 403：Cookie 已失效或与 UA 不匹配。'
                '注意 cf_clearance 同时绑定浏览器 UA 与出口 IP（有效期通常几小时）：'
                '请用同一个浏览器重新复制 Cookie，并把它的 User-Agent 一起填入。');
      }
      throw BookSourceException(result.error.isEmpty ? '请求失败' : result.error);
    }
    final bytes = result.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw const BookSourceException('响应为空');
    }
    return decodeMarkupText(bytes);
  }

  /// 站内搜索按 GBK 编码关键词（UTF-8 关键词会搜不到）。
  static String _gbkQuery(String query) {
    final bytes = gbk.encode(query);
    final buffer = StringBuffer();
    for (final b in bytes) {
      if ((b >= 0x30 && b <= 0x39) ||
          (b >= 0x41 && b <= 0x5A) ||
          (b >= 0x61 && b <= 0x7A) ||
          b == 0x2D ||
          b == 0x5F ||
          b == 0x2E) {
        buffer.writeCharCode(b);
      } else {
        buffer.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return buffer.toString();
  }
}

/// 便捷：把任意字节当 GBK 网页解码（供外部夹具/调试复用）。
String decodeWenku8Bytes(List<int> bytes) =>
    decodeMarkupText(Uint8List.fromList(bytes), contentType: 'text/html; charset=gbk');
