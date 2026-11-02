/// 本地书**格式 parser 注册表**（可插拔层之二）。
///
/// 新增格式 = 实现 [BookFormatParser] + `register`，导入/阅读链路不动。
/// 解析器只依赖 `dart:*` + pub 的纯 Dart 包，不碰 Flutter。
library;

import 'dart:io';
import 'dart:typed_data';

import 'book_block.dart';

/// 待解析的文件引用：可能是磁盘文件，也可能是压缩包内的内存条目。
class BookFileRef {
  BookFileRef({
    required this.fileName,
    this.path = '',
    this.sizeBytes = 0,
    this.bytes,
  });

  /// 磁盘路径（内存条目为空）。
  final String path;

  /// 文件名（含扩展名；EPUB 内为包内路径）。
  final String fileName;

  final int sizeBytes;

  /// 内存条目字节（压缩包内文件/测试夹具）；为 null 时按 [path] 读盘。
  final Uint8List? bytes;

  bool get isInMemory => bytes != null;

  /// 扩展名（小写、无点）。
  String get extension {
    final dot = fileName.lastIndexOf('.');
    if (dot < 0 || dot == fileName.length - 1) return '';
    return fileName.substring(dot + 1).toLowerCase();
  }

  /// 读取全部字节（磁盘文件按需读，内存条目直接返回）。
  Future<Uint8List> readBytes() async {
    final cached = bytes;
    if (cached != null) return cached;
    if (path.isEmpty) {
      throw StateError('BookFileRef 既无 path 也无 bytes（$fileName）');
    }
    return File(path).readAsBytes();
  }

  @override
  String toString() => 'BookFileRef($fileName, ${sizeBytes}B)';
}

/// 一章解析结果。
class ParsedChapter {
  const ParsedChapter({
    required this.title,
    required this.blocks,
    this.isVolume = false,
    this.href = '',
  });

  final String title;
  final List<BookBlock> blocks;

  /// 卷标题（无正文，阅读器目录里作分组）。
  final bool isVolume;

  /// 源内定位（EPUB 包内路径 / ZIP 条目名 / TXT 文件路径）。
  final String href;

  ChapterBlocks toBlocks() => ChapterBlocks(title: title, blocks: blocks);
}

/// 资源解析器：把 `ImageBlock.href` 变成字节（EPUB 读包内条目，其它读相对文件）。
abstract class BookResourceResolver {
  Future<Uint8List?> resolve(String href);

  /// MIME（渲染时判断是否可解码；未知返回空串）。
  String mimeOf(String href) => '';

  static const BookResourceResolver empty = _EmptyResolver();
}

class _EmptyResolver implements BookResourceResolver {
  const _EmptyResolver();

  @override
  Future<Uint8List?> resolve(String href) async => null;

  @override
  String mimeOf(String href) => '';
}

/// 一本解析完成的本地书。
class ParsedBook {
  ParsedBook({
    required this.title,
    required this.formatId,
    required this.chapters,
    this.author = '',
    this.intro = '',
    this.coverBytes,
    BookResourceResolver? resources,
  }) : resources = resources ?? BookResourceResolver.empty;

  final String title;
  final String author;
  final String intro;
  final String formatId;

  /// 目录顺序的章节（含卷条目）。
  final List<ParsedChapter> chapters;

  /// 封面原始字节（拿不到为 null）。
  final Uint8List? coverBytes;

  final BookResourceResolver resources;

  int get chapterCount => chapters.where((c) => !c.isVolume).length;

  int get charCount => chapters.fold<int>(
        0,
        (sum, c) =>
            sum +
            c.blocks.fold<int>(0, (s, b) {
              if (b is ParagraphBlock) return s + b.plainText.length;
              return s;
            }),
      );
}

/// 格式 parser。
abstract class BookFormatParser {
  const BookFormatParser();

  /// 稳定标识（`txt` / `epub` / …），会持久化到书库索引。
  String get id;

  /// 支持的扩展名（小写、无点）。
  Set<String> get extensions;

  /// 人类可读的名称（导入失败提示用）。
  String get displayName;

  bool supports(String fileName) => extensions.contains(_ext(fileName));

  Future<ParsedBook> parse(BookFileRef ref);
}

/// 未支持的格式（诚实报错，不静默当 txt 解）。
class UnsupportedBookFormat implements Exception {
  const UnsupportedBookFormat(this.extension, {this.fileName = ''});

  final String extension;
  final String fileName;

  @override
  String toString() => extension.isEmpty
      ? '无法识别文件格式${fileName.isEmpty ? '' : '：$fileName'}'
      : '暂不支持 .$extension 格式';
}

/// 解析失败（损坏/结构异常），带可读原因。
class BookFormatException implements Exception {
  const BookFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 格式注册表。
class BookFormatParserRegistry {
  BookFormatParserRegistry([Iterable<BookFormatParser>? parsers]) {
    if (parsers != null) {
      for (final p in parsers) {
        register(p);
      }
    }
  }

  final Map<String, BookFormatParser> _byExtension = {};

  void register(BookFormatParser parser) {
    for (final ext in parser.extensions) {
      _byExtension[ext] = parser;
    }
  }

  BookFormatParser? byExtension(String extension) =>
      _byExtension[extension.toLowerCase()];

  /// 按文件名解析；不支持 → [UnsupportedBookFormat]。
  BookFormatParser resolve(String fileName) {
    final parser = byExtension(_ext(fileName));
    if (parser == null) {
      throw UnsupportedBookFormat(_ext(fileName), fileName: fileName);
    }
    return parser;
  }

  Set<String> get supportedExtensions => _byExtension.keys.toSet();

  List<BookFormatParser> get all => _byExtension.values.toSet().toList();
}

String _ext(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}

/// 文件名去掉扩展名（作为书名兜底）。
String baseNameOfFile(String path) {
  final normalized = path.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  final name = index < 0 ? normalized : normalized.substring(index + 1);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}


