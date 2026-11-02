/// Markdown 解析：先转 HTML（`package:markdown`），再走 HTML 分章/区块链。
///
/// 这样标题分章、行内强调、列表、引用、代码块与 HTML 行为完全一致，不需要两套逻辑。
library;

import 'dart:convert';

import 'package:markdown/markdown.dart' as md;

import 'book_format_parser.dart';
import 'format_limits.dart';
import 'html_book_parser.dart';

class MarkdownBookParser extends BookFormatParser {
  const MarkdownBookParser();

  @override
  String get id => 'markdown';

  @override
  Set<String> get extensions => const {'md', 'markdown'};

  @override
  String get displayName => 'Markdown';

  @override
  Future<ParsedBook> parse(BookFileRef ref) async {
    final bytes = await ref.readBytes();
    if (bytes.length > kMarkupByteLimit) {
      throw const BookFormatException('Markdown 超过 32MB，已拒绝导入');
    }
    return parseMarkdownBookText(
      decodeMarkdownBytes(bytes),
      fallbackTitle: baseNameOfFile(ref.fileName),
    );
  }
}

/// 直接从 Markdown 文本解析。
ParsedBook parseMarkdownBookText(
  String source, {
  required String fallbackTitle,
}) {
  final html = md.markdownToHtml(
    source,
    extensionSet: md.ExtensionSet.gitHubFlavored,
  );
  return parseHtmlBookText(
    html,
    fallbackTitle: fallbackTitle,
    formatId: 'markdown',
  );
}

/// Markdown 约定 UTF-8；非法字节按有损替换（不中断导入）。
String decodeMarkdownBytes(List<int> bytes) {
  try {
    final text = utf8.decode(bytes);
    return text.startsWith('\uFEFF') ? text.substring(1) : text;
  } on FormatException {
    return utf8.decode(bytes, allowMalformed: true);
  }
}
