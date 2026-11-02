/// RSS / Atom 解析与抓取（纯函数解析 + 单一网络出口）。
library;

import 'dart:convert';

import 'package:xml/xml.dart';

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
  return parseRssArticles(text);
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
