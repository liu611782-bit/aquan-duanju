/// ZIP 解析：包内按扩展名委派给已注册的 parser。
///
/// - 包内含 `.epub` → 直接当 EPUB 解析（常见「zip 包 epub」形态）；
/// - 否则取 texthtml/md 条目，按条目名排序，多文件时章节标题前缀文件名；
/// - zip-slip（`..`/绝对路径）与解压总量（1GiB）双防护。
library;

import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'book_format_parser.dart';
import 'format_limits.dart';
import 'html_blocks.dart';

class ZipBookParser extends BookFormatParser {
  ZipBookParser({this.registry});

  /// 委派用的格式注册表（注册时传入，避免自引用构造）。
  final BookFormatParserRegistry? registry;

  @override
  String get id => 'zip';

  @override
  Set<String> get extensions => const {'zip'};

  @override
  String get displayName => 'ZIP';

  @override
  Future<ParsedBook> parse(BookFileRef ref) async {
    final bytes = await ref.readBytes();
    if (bytes.length > kArchiveByteLimit) {
      throw const BookFormatException('ZIP 超过 512MB，已拒绝导入');
    }
    final registry = this.registry;
    if (registry == null) {
      throw const BookFormatException('ZIP 解析器未绑定格式注册表');
    }

    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw BookFormatException('ZIP 压缩包损坏：$e');
    }

    final entries = <({String name, Uint8List data})>[];
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      // zip-slip：原始名里带 `..` 或是绝对路径的条目直接丢弃（必须在规范化之前判）。
      final rawName = file.name.replaceAll('\\', '/');
      if (rawName.startsWith('/') || rawName.split('/').contains('..')) {
        continue;
      }
      final name = normalizeArchivePath(file.name);
      if (name.isEmpty) continue;
      total += file.size;
      if (total > kUnzipTotalByteLimit) {
        throw const BookFormatException('ZIP 解压后超过 1GB，已拒绝（疑似压缩炸弹）');
      }
      entries.add((name: name, data: file.content));
    }
    if (entries.isEmpty) {
      throw const BookFormatException('ZIP 里没有文件');
    }

    // 单本 EPUB 打包：直接交给 EPUB parser（保留目录/注音/插图能力）。
    for (final entry in entries) {
      if (!entry.name.toLowerCase().endsWith('.epub')) continue;
      final parser = registry.byExtension('epub');
      if (parser == null) continue;
      return parser.parse(BookFileRef(
        fileName: entry.name,
        bytes: entry.data,
        sizeBytes: entry.data.length,
      ));
    }

    final bookTitle = baseNameOfFile(ref.fileName);
    final readable = <({String name, Uint8List data})>[];
    var skipped = 0;
    for (final entry in entries) {
      final ext = _extOf(entry.name);
      if (registry.byExtension(ext) == null) {
        skipped++;
        continue;
      }
      // 图像等资源不算章节。
      if (ext == 'epub' || ext == 'zip') continue;
      readable.add(entry);
    }
    if (readable.isEmpty) {
      throw BookFormatException('ZIP 里没有可读的文本条目（跳过 $skipped 个非文本文件）');
    }
    readable.sort((a, b) => a.name.compareTo(b.name));

    final chapters = <ParsedChapter>[];
    for (final entry in readable) {
      final parser = registry.byExtension(_extOf(entry.name));
      if (parser == null) continue;
      final ParsedBook parsed;
      try {
        parsed = await parser.parse(BookFileRef(
          fileName: entry.name,
          bytes: entry.data,
          sizeBytes: entry.data.length,
        ));
      } catch (_) {
        // 单个条目坏了不拖垮整包：跳过（计数在 UI 侧由章节数体现）。
        continue;
      }
      final prefix = readable.length > 1 ? '${baseNameOfFile(entry.name)} · ' : '';
      for (final chapter in parsed.chapters) {
        chapters.add(ParsedChapter(
          title: prefix.isEmpty || chapter.isVolume
              ? chapter.title
              : '$prefix${chapter.title}',
          blocks: chapter.blocks,
          isVolume: chapter.isVolume,
          href: entry.name,
        ));
        if (chapters.length >= kMaxChapters) break;
      }
      if (chapters.length >= kMaxChapters) break;
    }

    if (chapters.isEmpty) {
      throw const BookFormatException('ZIP 内容解析失败：没有可用章节');
    }

    return ParsedBook(
      title: bookTitle,
      formatId: 'zip',
      chapters: chapters,
    );
  }
}

String _extOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return '';
  return name.substring(dot + 1).toLowerCase();
}
