/// 单文件 HTML / XHTML 解析：h1–h3 作为章节边界（≥2 个标题才切），否则整篇一章。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../book_markup.dart';
import 'book_format_parser.dart';
import 'format_limits.dart';
import 'html_blocks.dart';

class HtmlBookParser extends BookFormatParser {
  const HtmlBookParser();

  /// 是否把 h1–h3 当章节边界。
  static const int minHeadingsToSplit = 2;

  @override
  String get id => 'html';

  @override
  Set<String> get extensions => const {'html', 'htm', 'xhtml'};

  @override
  String get displayName => 'HTML';

  @override
  Future<ParsedBook> parse(BookFileRef ref) async {
    final bytes = await ref.readBytes();
    if (bytes.length > kMarkupByteLimit) {
      throw const BookFormatException('HTML 超过 32MB，已拒绝导入');
    }
    return parseHtmlBookText(
      decodeMarkupText(bytes),
      fallbackTitle: baseNameOfFile(ref.fileName),
    );
  }
}

/// 直接从 HTML 文本解析（HTML / Markdown 共用入口）。
ParsedBook parseHtmlBookText(
  String html, {
  required String fallbackTitle,
  String formatId = 'html',
}) {
  final doc = html_parser.parse(html);
  final body = doc.body ?? doc.documentElement;
  if (body == null) {
    throw const BookFormatException('HTML 没有 body');
  }

  final notes = collectHtmlNotes(doc);
  final css = htmlStylesOf(doc);
  final docTitle = _docTitle(doc);

  final sections = _splitByHeadings(body);
  final chapters = <ParsedChapter>[];

  if (sections.length < HtmlBookParser.minHeadingsToSplit) {
    final blocks = buildHtmlBlocks(
      body,
      notes: notes,
      css: css,
    );
    if (blocks.isEmpty) {
      throw const BookFormatException('HTML 正文为空');
    }
    chapters.add(ParsedChapter(
      title: docTitle.isEmpty ? fallbackTitle : docTitle,
      blocks: blocks,
    ));
  } else {
    for (final section in sections) {
      final blocks = buildHtmlBlocks(
        section.container,
        notes: notes,
        css: css,
      );
      if (blocks.isEmpty) continue;
      chapters.add(ParsedChapter(
        title: section.title.isEmpty ? fallbackTitle : section.title,
        blocks: blocks,
      ));
      if (chapters.length >= kMaxChapters) break;
    }
    if (chapters.isEmpty) {
      throw const BookFormatException('HTML 章节内容为空');
    }
  }

  return ParsedBook(
    title: docTitle.isEmpty ? fallbackTitle : docTitle,
    formatId: formatId,
    chapters: chapters,
  );
}

class _Section {
  _Section(this.title);

  final String title;
  final dom.Element container = dom.Element.tag('div');
}

List<_Section> _splitByHeadings(dom.Element body) {
  final sections = <_Section>[];
  _Section? current;

  void ensureSection() {
    current ??= _Section('');
    if (!sections.contains(current)) sections.add(current!);
  }

  for (final node in body.nodes.toList()) {
    if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (RegExp(r'^h[1-3]$').hasMatch(tag)) {
        final title = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        current = _Section(title);
        sections.add(current!);
        continue;
      }
    }
    ensureSection();
    current!.container.append(node.clone(true));
  }
  return sections;
}

String _docTitle(dom.Document doc) {
  final title = doc.querySelector('title')?.text ?? '';
  final cleaned = title
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceFirst(RegExp(r'\s*[-_|].*$'), '')
      .trim();
  if (cleaned.isNotEmpty) return cleaned;
  final h1 = doc.querySelector('h1')?.text ?? '';
  return h1.replaceAll(RegExp(r'\s+'), ' ').trim();
}
