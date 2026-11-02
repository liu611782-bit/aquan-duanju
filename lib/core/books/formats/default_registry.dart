/// 标准格式注册表：TXT / EPUB / HTML / Markdown / ZIP。
///
/// 新格式接入 = 写 parser + 在这里 `register`（或在运行时对
/// `BookLibrary.registry` 再注册），导入/阅读链路不改。
library;

import 'book_format_parser.dart';
import 'epub_book_parser.dart';
import 'html_book_parser.dart';
import 'markdown_book_parser.dart';
import 'txt_book_parser.dart';
import 'zip_book_parser.dart';

BookFormatParserRegistry standardBookFormatRegistry() {
  final registry = BookFormatParserRegistry();
  registry.register(const TxtBookParser());
  registry.register(const EpubBookParser());
  registry.register(const HtmlBookParser());
  registry.register(const MarkdownBookParser());
  registry.register(ZipBookParser(registry: registry));
  return registry;
}
