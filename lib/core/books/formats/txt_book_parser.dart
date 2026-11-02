/// TXT 解析：复用 `local_book_import.dart` 的编码嗅探、章节正则与超长行截断，
/// 把纯文本章节转成 [ParagraphBlock]。
library;

import 'dart:typed_data';

import '../local_book_import.dart';
import 'book_block.dart';
import 'book_format_parser.dart';
import 'format_limits.dart';

class TxtBookParser extends BookFormatParser {
  const TxtBookParser({this.chapterPattern, this.volumePattern});

  /// 自定义章节正则（默认用 [localChapterPattern]）。
  final RegExp? chapterPattern;

  /// 自定义分卷正则（默认 [localVolumePattern]）。
  final RegExp? volumePattern;

  @override
  String get id => 'txt';

  @override
  Set<String> get extensions => const {'txt'};

  @override
  String get displayName => 'TXT';

  @override
  Future<ParsedBook> parse(BookFileRef ref) async {
    final bytes = await ref.readBytes();
    if (bytes.length > kTxtByteLimit) {
      throw const BookFormatException('TXT 超过 128MB，已拒绝导入');
    }
    return parseTxtBytes(bytes, fileName: ref.fileName);
  }
}

/// 直接从字节解析（导入与测试共用；不读磁盘）。
ParsedBook parseTxtBytes(
  Uint8List bytes, {
  required String fileName,
  LocalBookEncoding? preferEncoding,
  RegExp? chapterPattern,
  RegExp? volumePattern,
}) {
  final encoding = preferEncoding ?? sniffEncoding(bytes);
  final text = decodeLocalBookText(bytes, preferEncoding: encoding);
  final parsed = parseLocalBook(
    fileName,
    text,
    chapterPattern: chapterPattern,
    volumePattern: volumePattern,
  );
  return ParsedBook(
    title: parsed.title,
    formatId: 'txt',
    chapters: [
      for (final c in parsed.chapters.take(kMaxChapters))
        ParsedChapter(
          title: c.title,
          isVolume: c.isVolume,
          href: 'txt:${c.title}',
          blocks: c.isVolume
              ? const <BookBlock>[]
              : blocksFromLines(c.body.split('\n')),
        ),
    ],
  );
}
