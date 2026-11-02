/// RSS / Atom 解析与抓取（纯函数解析 + 单一网络出口）。
library;

import 'dart:convert';

import 'package:xml/xml.dart';

import '../books/book_rule.dart';
import '../sources/source_fetch.dart';
import '../sources/source_import.dart';
import 'rss_models.dart';

/// 抓取并解析一个订阅源。
Future<List<RssArticle>> fetchRssFeed(
  RssSource source, {
  bool enforceSsrf = true,
  Duration connectTimeout = const Duration(seconds: 10),
  Duration readTimeout = const Duration(seconds: 20),
}) async {
  if (enforceSsrf) SourceImporter.validateImportUrl(source.url);
  final result = await fetchProbe(
    source.url,
    enforceSsrf: enforceSsrf,
    maxBytes: 4 * 1024 * 1024,
    connectTimeout: connectTimeout,
    readTimeout: readTimeout,
  );
  if (!result.ok || result.bytes == null) {
    throw RssException('抓取失败：${result.error.isEmpty ? '无响应' : result.error}');
  }
  final text = utf8.decode(result.bytes!, allowMalformed: true);
  if (source.isRuleBased) return parseRuleBasedArticles(source, text);
  return parseRssArticles(text);
}

/// 网页规则订阅源（legado `ruleArticles`）：抓列表页 → 逐条取标题/链接/正文。
///
/// 复用书源的规则求值器（CSS / XPath / JSON 都支持），不引入第二套解析。
List<RssArticle> parseRuleBasedArticles(RssSource source, String page) {
  final nodes = BookRule.evalList(page, source.ruleArticles);
  if (nodes.isEmpty) {
    throw const RssException('规则没有匹配到条目（页面结构可能变了）');
  }
  final out = <RssArticle>[];
  for (final node in nodes) {
    final title = _eval(node, source.ruleTitle);
    final link = _absolute(source.url, _eval(node, source.ruleLink));
    final content = _eval(node, source.ruleContent);
    if (title.isEmpty && link.isEmpty) continue;
    out.add(RssArticle(
      title: title.isEmpty ? link : title,
      link: link,
      summary: title,
      content: content,
    ));
  }
  return out;
}

String _eval(Object node, String rule) =>
    rule.trim().isEmpty ? '' : BookRule.evalString(node, rule);

String _absolute(String base, String href) {
  if (href.isEmpty) return '';
  final uri = Uri.tryParse(href);
  if (uri == null) return href;
  if (uri.hasScheme) return href;
  final baseUri = Uri.tryParse(base);
  if (baseUri == null) return href;
  try {
    return baseUri.resolveUri(uri).toString();
  } catch (_) {
    return href;
  }
}

class RssException implements Exception {
  const RssException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析 RSS 2.0 / Atom / RDF；解析不了抛 [RssException]。
List<RssArticle> parseRssArticles(String text) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(text);
  } catch (e) {
    throw RssException('不是有效的 RSS/Atom：$e');
  }
  final root = doc.rootElement;
  final items = <XmlElement>[];
  for (final el in root.descendants.whereType<XmlElement>()) {
    final name = el.name.local.toLowerCase();
    if (name == 'item' || name == 'entry') items.add(el);
  }
  if (items.isEmpty) {
    throw const RssException('这个地址没有条目（可能不是订阅源）');
  }
  final out = <RssArticle>[];
  for (final item in items) {
    final title = _text(item, const ['title']);
    final link = _link(item);
    final published = _text(item, const [
      'pubDate',
      'published',
      'updated',
      'dc:date',
    ]);
    final content = _text(item, const [
      'encoded',
      'content',
      'description',
      'summary',
    ]);
    final summary = _text(item, const ['summary', 'description']);
    if (title.isEmpty && link.isEmpty) continue;
    out.add(RssArticle(
      title: title,
      link: link,
      published: published,
      summary: _stripTags(summary),
      content: content,
    ));
  }
  return out;
}

/// 按 [names] 的**优先级**取文本：先找第一个名字的所有节点，再找第二个。
///
/// 不能按文档顺序取第一个命中——RSS 里 `description`（摘要）通常排在
/// `content:encoded`（全文）前面，按顺序取会永远只拿到摘要。
String _text(XmlElement parent, List<String> names) {
  final elements = parent.descendants.whereType<XmlElement>().toList();
  for (final name in names) {
    for (final child in elements) {
      if (child.name.local != name && child.name.qualified != name) continue;
      final text = child.innerText.trim();
      if (text.isNotEmpty) return text;
    }
  }
  return '';
}

String _link(XmlElement item) {
  // Atom: <link href="..."/>；RSS: <link>...</link>
  for (final child in item.descendants.whereType<XmlElement>()) {
    if (child.name.local != 'link') continue;
    final href = child.getAttribute('href');
    if (href != null && href.isNotEmpty) return href;
    final text = child.innerText.trim();
    if (text.isNotEmpty) return text;
  }
  return '';
}

/// 去标签 + 折叠空白（列表摘要用）。
String _stripTags(String html) => html
    .replaceAll(RegExp(r'<[^>]+>'), ' ')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
