/// 轻小说文库（Wenku8）页面解析：**纯函数**，不碰网络，全部可单测。
///
/// 站点是 GBK 老站，DOM 结构在多版本间有出入，所以每个字段都做「首选选择器 →
/// 结构兜底」两级，解析不出来就如实返回空/抛异常，绝不伪造字段。
library;

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

import '../book_source_model.dart';

/// 书籍引用：`wenku8://book/<aid>` 或站内 `/book/<aid>.htm`。
class Wenku8BookRef {
  const Wenku8BookRef(this.aid);

  final String aid;

  static final RegExp _scheme = RegExp(r'^wenku8://book/(\d+)');
  static final RegExp _page = RegExp(r'/book/(\d+)\.htm');

  static Wenku8BookRef? tryParse(String url) {
    final m = _scheme.firstMatch(url) ?? _page.firstMatch(url);
    if (m == null) return null;
    return Wenku8BookRef(m.group(1)!);
  }

  String get uri => 'wenku8://book/$aid';
  String get pagePath => '/book/$aid.htm';
}

/// 章节引用：`wenku8://chapter/<aid>/<cid>`（cid 不含 `.htm`）。
class Wenku8ChapterRef {
  const Wenku8ChapterRef(this.aid, this.cid);

  final String aid;
  final String cid;

  static final RegExp _scheme = RegExp(r'^wenku8://chapter/(\d+)/(\d+)');
  static final RegExp _page = RegExp(r'/novel/(\d+)/(\d+)\.htm');

  static Wenku8ChapterRef? tryParse(String url) {
    final m = _scheme.firstMatch(url) ?? _page.firstMatch(url);
    if (m == null) return null;
    return Wenku8ChapterRef(m.group(1)!, m.group(2)!);
  }

  String get uri => 'wenku8://chapter/$aid/$cid';
  String get pagePath => '/novel/$aid/$cid.htm';
}

/// 分类条目（从站点导航解析出的真实分类，不预置猜想的 id 表）。
class Wenku8Class {
  const Wenku8Class({required this.id, required this.name});

  final String id;
  final String name;

  @override
  String toString() => 'Wenku8Class($id, $name)';
}

/// 排行种类（站点 `sort` 参数）。
enum Wenku8Rank {
  visit('allvisit', '总点击'),
  vote('allvote', '总推荐'),
  flower('allflower', '总收藏');

  const Wenku8Rank(this.sort, this.label);

  final String sort;
  final String label;
}

/// 站点结构不符合预期（不是网络问题）。
class Wenku8PageException implements Exception {
  const Wenku8PageException(this.stage, [this.detail = '']);

  final String stage;
  final String detail;

  @override
  String toString() =>
      'Wenku8 站点结构变化：$stage${detail.isEmpty ? '' : '（$detail）'}';
}

/// 列表页（搜索 / 分类 / 排行共用）：一行一本。
///
/// 结构（多版本兼容）：
/// `#content table tr` 里出现 `a[href*="/book/"]` 即视为书目行；
/// 作者取书名单元之后的第一个短文本单元；最新章节取 `a[href*="/novel/"]`。
List<BookHit> parseWenku8ListPage(String html, {required String baseUrl}) {
  final doc = html_parser.parse(html);
  final scope = _scopeContaining(doc, '/book/') ?? doc.documentElement;
  if (scope == null) return const [];

  final hits = <BookHit>[];
  final seen = <String>{};

  for (final row in scope.querySelectorAll('tr')) {
    final link = row.querySelector('a[href*="/book/"]');
    if (link == null) continue;
    final ref = Wenku8BookRef.tryParse(link.attributes['href'] ?? '');
    if (ref == null || !seen.add(ref.aid)) continue;

    final name = _clean(link.text);
    if (name.isEmpty) continue;

    final cells = row.querySelectorAll('td');
    var author = '';
    for (final cell in cells) {
      if (cell.querySelector('a[href*="/book/"]') != null) continue;
      final text = _clean(cell.text);
      if (text.isEmpty) continue;
      // 跳过纯数字/日期/「最新章节」这类非作者列。
      if (RegExp(r'^\d+$').hasMatch(text)) continue;
      if (RegExp(r'^\d{4}[-/]\d{1,2}').hasMatch(text)) continue;
      if (text.length > 30) continue;
      author = text;
      break;
    }

    final lastLink = row.querySelector('a[href*="/novel/"]');
    hits.add(BookHit(
      bookUrl: ref.uri,
      name: name,
      author: author,
      lastChapter: lastLink == null ? '' : _clean(lastLink.text),
    ));
  }

  // 兜底：没有表格结构时按「书名链接」直取（站点改版后仍能出结果）。
  if (hits.isEmpty) {
    for (final link in scope.querySelectorAll('a[href*="/book/"]')) {
      final ref = Wenku8BookRef.tryParse(link.attributes['href'] ?? '');
      if (ref == null || !seen.add(ref.aid)) continue;
      final name = _clean(link.text);
      if (name.isEmpty) continue;
      hits.add(BookHit(bookUrl: ref.uri, name: name));
    }
  }
  return hits;
}

/// 详情页：书名 / 作者 / 封面 / 简介（目录另取 [parseWenku8Toc]）。
BookDetailData parseWenku8Detail(String html, {required String baseUrl}) {
  final doc = html_parser.parse(html);

  // 书名：`#title` 是干净的；退化到 `<title>` 时去掉站名后缀（书名里的 `-` 要保留）。
  var name = _clean(
    (doc.querySelector('#title') ?? doc.querySelector('h1'))?.text ?? '',
  );
  if (name.isEmpty) {
    final raw = _clean(doc.querySelector('title')?.text ?? '');
    name = raw
        .replaceFirst(RegExp(r'\s*[-_]\s*轻小说文库.*$'), '')
        .replaceFirst(RegExp(r'\s*[-_]\s*Wenku8.*$', caseSensitive: false), '')
        .trim();
    if (name.isEmpty) name = raw;
  }

  final infoText = _clean(doc.querySelector('#info')?.text ?? '');
  final authorMatch = RegExp(r'作\s*者[:：]?\s*([^\s|/]+)').firstMatch(
        '${doc.querySelector('#info')?.text ?? ''} ${doc.querySelector('#content')?.text ?? ''}',
      );
  var author = authorMatch?.group(1)?.trim() ?? '';
  if (author.isEmpty && infoText.isNotEmpty) {
    author = infoText.split(RegExp(r'\s+')).firstWhere(
          (t) => t.isNotEmpty && !t.contains('作者') && t.length <= 20,
          orElse: () => '',
        );
  }
  author = _clean(author);

  final intro = _clean(
    doc.querySelector('#intro')?.text ??
        doc.querySelector('div.intro')?.text ??
        '',
  );

  var coverUrl = '';
  for (final img in doc.querySelectorAll('img')) {
    final src = img.attributes['src'] ?? '';
    if (!src.contains('/image/')) continue;
    coverUrl = _absolute(baseUrl, src);
    break;
  }

  return BookDetailData(
    name: name,
    author: author,
    intro: intro,
    coverUrl: coverUrl,
  );
}

/// 目录页：`tr.vc` 为卷、`tr.cc` 为章；兜底按「含 `/novel/` 链接」识别章节。
///
/// 卷作为 `isVolume: true` 的条目保留在原位置（阅读器目录面板据此分组）。
List<BookTocItem> parseWenku8Toc(String html, {required String baseUrl}) {
  final doc = html_parser.parse(html);
  // 详情页有多个 `#content`（简介那个在前），必须选**含章节链接**的那个。
  final scope = _scopeContaining(doc, '/novel/') ?? doc.documentElement;
  if (scope == null) return const [];

  final items = <BookTocItem>[];
  final seen = <String>{};

  void addChapter(Element link) {
    final ref = Wenku8ChapterRef.tryParse(link.attributes['href'] ?? '');
    if (ref == null || !seen.add(ref.cid)) return;
    final title = _clean(link.text);
    if (title.isEmpty) return;
    items.add(BookTocItem(title: title, url: ref.uri));
  }

  for (final row in scope.querySelectorAll('tr')) {
    final className = row.attributes['class'] ?? '';
    if (className.contains('vc')) {
      final title = _clean(row.text);
      if (title.isNotEmpty) {
        items.add(BookTocItem(title: title, url: '', isVolume: true));
      }
      continue;
    }
    final links = row.querySelectorAll('a[href*="/novel/"]');
    for (final link in links) {
      addChapter(link);
    }
  }

  if (items.where((i) => !i.isVolume).isEmpty) {
    for (final link in scope.querySelectorAll('a[href*="/novel/"]')) {
      addChapter(link);
    }
  }
  return items;
}

/// 正文页：标题 + 正文纯文本（保留段落换行）。
String parseWenku8Content(String html) {
  final doc = html_parser.parse(html);
  final title = _clean(doc.querySelector('#title')?.text ?? '');

  // 正文容器：多个 `#content` 时取文本最长的那个（外层包导航/表格）。
  Element? best;
  var bestLength = 0;
  for (final el in doc.querySelectorAll('#content')) {
    final len = el.text.trim().length;
    if (len > bestLength) {
      best = el;
      bestLength = len;
    }
  }
  final container = best ?? doc.body;
  if (container == null) throw const Wenku8PageException('正文页', '缺少 body');

  final clone = container.clone(true);
  for (final el in clone.querySelectorAll(
    'script, style, ins, iframe, table, div[id^=ad], div.ad, '
    'div[class*=advert], a',
  )) {
    el.remove();
  }
  // 正文里的 `#title` 已单独取过，避免重复。
  clone.querySelector('#title')?.remove();

  final text = _clean(clone.innerHtml
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'"));

  final body = text.trim();
  if (body.isEmpty) {
    throw const Wenku8PageException('正文页', '正文为空');
  }
  return title.isEmpty ? body : '$title\n\n$body';
}

/// 从首页导航解析真实分类（`articlelist.php?class=N`）。
List<Wenku8Class> parseWenku8Classes(String html) {
  final doc = html_parser.parse(html);
  final out = <Wenku8Class>[];
  final seen = <String>{};
  for (final link in doc.querySelectorAll('a[href*="articlelist.php"]')) {
    final href = link.attributes['href'] ?? '';
    final m = RegExp(r'class=(\d+)').firstMatch(href);
    if (m == null) continue;
    final id = m.group(1)!;
    final name = _clean(link.text);
    if (name.isEmpty || !seen.add(id)) continue;
    out.add(Wenku8Class(id: id, name: name));
  }
  return out;
}

/// 选「包含指定链接片段」的 `#content` 容器；都没有则返回 null（调用方回退整页）。
Element? _scopeContaining(Document doc, String hrefFragment) {
  for (final el in doc.querySelectorAll('#content')) {
    if (el.querySelector('a[href*="$hrefFragment"]') != null) return el;
  }
  if (doc.querySelector('a[href*="$hrefFragment"]') != null) {
    return doc.documentElement;
  }
  return null;
}

String _clean(String raw) => raw
    .replaceAll('\u00A0', ' ')
    .replaceAll(RegExp(r'[\t\r]+'), ' ')
    .replaceAll(RegExp(r' {2,}'), ' ')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .join('\n')
    .trim();

String _absolute(String baseUrl, String href) {
  final uri = Uri.tryParse(href);
  if (uri == null) return href;
  if (uri.hasScheme) return href;
  return Uri.parse(baseUrl).resolveUri(uri).toString();
}
