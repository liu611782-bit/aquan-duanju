/// 本地 TXT 小说导入（吸收自 Wenku8_Flutter 的 `local_text_import.dart` /
/// `book_text_encoding.dart` / `local_import_options.dart`，实现为原始 Dart）。
///
/// 设计要点（与上游对齐的部分）：
/// - 编码嗅探顺序：BOM → 显式指定 → UTF-8 严格试解 → GB18030/GBK → 兜底
///   `allowMalformed`（诚实标注乱码风险）；
/// - 章节标题默认正则与上游同源（`第X章/节/回/幕/话`、`Chapter n`、序章/楔子/
///   番外/后记等，含全角数字与「零〇一二…」汉字数字）；
/// - 超长物理行截断（4000 字符，代理对边界感知）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 章节标题默认正则（Wenku8 `defaultLocalChapterRule` 同源）。
final RegExp localChapterPattern = RegExp(
  r'^(第[零〇一二三四五六七八九十百千万萬两兩0-9０-９]+[章节節回幕话話]'
  r'|chapter\s+\d+|序章|序言|楔子|尾声|尾聲|后记|後記|番外)',
  caseSensitive: false,
);

/// 分卷标题默认正则。
final RegExp localVolumePattern = RegExp(
  r'^(第[零〇一二三四五六七八九十百千万萬两兩0-9０-９]+[卷部]|volume\s+\d+)',
  caseSensitive: false,
);

/// 编码嗅探结果。
enum LocalBookEncoding { utf8, gb18030, utf16Le, utf16Be, big5 }

/// 把文件字节解码成文本（Wenku8 `decodeTextFile` 的嗅探语义）。
///
/// [preferEncoding] 显式指定时优先（嗅探失败再回落）。
String decodeLocalBookText(Uint8List bytes, {LocalBookEncoding? preferEncoding}) {
  final order = <LocalBookEncoding>[
    ?preferEncoding,
    ...LocalBookEncoding.values.where((e) => e != preferEncoding),
  ];
  Object? decodeError;
  for (final enc in order) {
    try {
      return _decodeWith(enc, bytes);
    } catch (e) {
      decodeError = e;
    }
  }
  assert(decodeError != null || bytes.isEmpty, '至少一次解码尝试应发生');
  // 兜底：utf8 allowMalformed（调用方按需提示「可能乱码」）。
  return utf8.decode(bytes, allowMalformed: true);
}

String _decodeWith(LocalBookEncoding enc, Uint8List bytes) {
  switch (enc) {
    case LocalBookEncoding.utf8:
      return utf8.decode(bytes); // 严格：失败抛 FormatException
    case LocalBookEncoding.gb18030:
      return gbk.decode(bytes, allowMalformed: true);
    case LocalBookEncoding.utf16Le:
      return String.fromCharCodes(
          _u16(bytes, littleEndian: true));
    case LocalBookEncoding.utf16Be:
      return String.fromCharCodes(_u16(bytes, littleEndian: false));
    case LocalBookEncoding.big5:
      // 无 Big5 解码器：显式不支持（诚实，不静默乱码）。
      throw UnsupportedError('Big5 暂不支持');
  }
}

Iterable<int> _u16(Uint8List bytes, {required bool littleEndian}) sync* {
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    yield littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1];
  }
}

/// 按 BOM 判断显式编码；无 BOM 返回 null（交给嗅探链）。
LocalBookEncoding? bomEncoding(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return LocalBookEncoding.utf8;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return LocalBookEncoding.utf16Le;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return LocalBookEncoding.utf16Be;
  }
  return null;
}

/// 是否大概率 GBK 系（ASCII 占比高 + 含常见 GBK 双字节序列的启发式仅作提示，
/// 实际决策交给 utf8 严格试解失败）。这里给 UI 的嗅探标签。
LocalBookEncoding sniffEncoding(Uint8List bytes) {
  final bom = bomEncoding(bytes);
  if (bom != null) return bom;
  try {
    utf8.decode(bytes);
    return LocalBookEncoding.utf8;
  } on FormatException {
    return LocalBookEncoding.gb18030;
  }
}

/// 一章（或卷头）。
class LocalBookChapter {
  const LocalBookChapter({
    required this.title,
    required this.body,
    this.isVolume = false,
  });

  final String title;
  final String body;
  final bool isVolume;

  int get charCount => title.length + body.length;
}

/// 解析结果。
class LocalBookParsed {
  const LocalBookParsed({
    required this.title,
    required this.chapters,
    required this.encoding,
  });

  final String title;
  final List<LocalBookChapter> chapters;
  final LocalBookEncoding encoding;

  int get totalChars =>
      chapters.fold(0, (a, c) => a + c.charCount);
}

/// 解析 TXT 全文为章节列表。
///
/// - 文件名（去扩展名）作书名；
/// - 命中 [chapterPattern] 的行是章节标题；[volumePattern] 命中是卷头（保留）；
/// - 无任何章节命中的书 → 整本单章（标题取书名）；
/// - 超长行按 4000 字符截断（代理对边界感知，上游同款）。
LocalBookParsed parseLocalBook(
  String fileName,
  String text, {
  RegExp? chapterPattern,
  RegExp? volumePattern,
}) {
  final cp = chapterPattern ?? localChapterPattern;
  final vp = volumePattern ?? localVolumePattern;
  final name = fileName.replaceAll(RegExp(r'\.txt$', caseSensitive: false), '').trim();
  final chapters = <LocalBookChapter>[];
  final body = <String>[];
  var currentTitle = '';
  var currentIsVolume = false;

  void flush() {
    if (currentTitle.isEmpty && body.isEmpty) return;
    chapters.add(LocalBookChapter(
      title: currentTitle.isEmpty
          ? (chapters.isEmpty ? name : '（未命名）')
          : currentTitle,
      body: body.join('\n'),
      isVolume: currentIsVolume,
    ));
    body.clear();
  }

  for (final rawLine in text.split(RegExp(r'\r\n|\n|\r'))) {
    final line = _clipLine(rawLine.trim());
    if (line.isEmpty) {
      if (body.isNotEmpty || currentTitle.isNotEmpty) body.add('');
      continue;
    }
    if (cp.hasMatch(line)) {
      flush();
      currentTitle = line;
      currentIsVolume = false;
      continue;
    }
    if (vp.hasMatch(line)) {
      flush();
      currentTitle = line;
      currentIsVolume = true;
      continue;
    }
    body.add(line);
  }
  flush();

  // 全书无章节标题 → 单章整本。
  if (chapters.isEmpty) {
    return LocalBookParsed(
      title: name,
      chapters: [LocalBookChapter(title: name, body: text.trim())],
      encoding: LocalBookEncoding.utf8,
    );
  }
  // 开头无标题的前言挂在首章前（保序，标题用文件名）。
  return LocalBookParsed(
    title: name,
    chapters: chapters,
    encoding: LocalBookEncoding.utf8,
  );
}

/// 超长行截断（4000，代理对边界感知）。
String _clipLine(String line) {
  const max = 4000;
  if (line.length <= max) return line;
  var next = max;
  final last = line.codeUnitAt(next - 1);
  if (last >= 0xd800 && last <= 0xdbff) next--;
  return line.substring(0, next);
}

/// 导入一个本地 TXT 文件（读文件 → 嗅探解码 → 解析章节）。
Future<LocalBookParsed> importLocalBookFile(String path,
    {LocalBookEncoding? preferEncoding}) async {
  final bytes = await File(path).readAsBytes();
  final enc = preferEncoding ?? sniffEncoding(bytes);
  var text = decodeLocalBookText(bytes, preferEncoding: enc);
  if (text.startsWith('\uFEFF')) text = text.substring(1);
  final fileName = path.split(Platform.pathSeparator).last;
  final parsed = parseLocalBook(fileName, text);
  return LocalBookParsed(
    title: parsed.title,
    chapters: parsed.chapters,
    encoding: enc,
  );
}
