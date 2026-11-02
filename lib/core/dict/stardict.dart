/// StarDict 词典（纯 Dart）：`.ifo` 元数据 + `.idx` 索引 + `.dict`/`.dict.dz` 数据。
///
/// 只做「查词」这一件事：精确匹配 → 前缀建议 → 释义清洗（HTML/Pango 标签剥离）。
/// MDict（.mdx/.mdd）由 Go 核心解析，不走这里。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 词典元信息。
class DictInfo {
  const DictInfo({
    required this.id,
    required this.name,
    required this.wordCount,
    required this.path,
    this.sametypesequence = '',
  });

  final String id;
  final String name;
  final int wordCount;

  /// 词典目录（含 .ifo/.idx/.dict）。
  final String path;
  final String sametypesequence;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'wordCount': wordCount,
        'path': path,
        'sametypesequence': sametypesequence,
      };

  factory DictInfo.fromJson(Map<String, dynamic> j) => DictInfo(
        id: j['id']?.toString() ?? '',
        name: j['name']?.toString() ?? '',
        wordCount: (j['wordCount'] as num?)?.toInt() ?? 0,
        path: j['path']?.toString() ?? '',
        sametypesequence: j['sametypesequence']?.toString() ?? '',
      );
}

/// 一条查询结果。
class DictHit {
  const DictHit({
    required this.word,
    required this.definition,
    required this.dictName,
  });

  final String word;
  final String definition;
  final String dictName;
}

/// 打开一本 StarDict 词典。
class StarDict {
  StarDict._({
    required this.info,
    required this.entries,
    required this._file,
    required this._dataMode,
    required this._dataBytes,
  });

  final DictInfo info;

  /// 索引：word → (offset, size)，保持文件顺序（已按词排序）。
  final List<({String word, int offset, int size})> entries;

  final RandomAccessFile? _file;
  final _DataMode _dataMode;
  final Uint8List? _dataBytes;

  static const int _maxDecompressedBytes = 256 * 1024 * 1024;

  bool get isOpen => _file != null || _dataBytes != null;

  /// 从词典目录打开（目录里需有同名 `.ifo`/`.idx`/`.dict`）。
  static Future<StarDict> open(String dirPath) async {
    final dir = Directory(dirPath);
    final ifo = _findFile(dir, '.ifo');
    if (ifo == null) {
      throw const FormatException('缺少 .ifo 文件');
    }
    final meta = _parseIfo(await ifo.readAsString());
    final base = ifo.path.substring(0, ifo.path.length - 4);
    final idxFile = File('$base.idx');
    if (!idxFile.existsSync()) {
      throw const FormatException('缺少 .idx 文件');
    }
    final idxBytes = await idxFile.readAsBytes();
    final entries = _parseIdx(idxBytes);

    final name = ifo.path.replaceAll('\\', '/').split('/').last;
    final info = DictInfo(
      id: _idOf(meta['bookname'] ?? base),
      name: meta['bookname'] ?? name.replaceAll('.ifo', ''),
      wordCount: int.tryParse(meta['wordcount'] ?? '') ?? entries.length,
      path: dir.path,
      sametypesequence: meta['sametypesequence'] ?? '',
    );

    // 数据：.dict 走随机读，.dict.dz 解压进内存（上限 256MB）。
    final dictFile = File('$base.dict');
    final dzFile = File('$base.dict.dz');
    if (dictFile.existsSync()) {
      final file = await dictFile.open();
      return StarDict._(
        info: info,
        entries: entries,
        file: file,
        dataMode: _DataMode.file,
        dataBytes: null,
      );
    }
    if (dzFile.existsSync()) {
      final raw = await dzFile.readAsBytes();
      final decoded = _gunzip(raw);
      if (decoded.length > _maxDecompressedBytes) {
        throw const FormatException('词典解压后超过 256MB');
      }
      return StarDict._(
        info: info,
        entries: entries,
        file: null,
        dataMode: _DataMode.memory,
        dataBytes: decoded,
      );
    }
    throw const FormatException('缺少 .dict / .dict.dz 文件');
  }

  /// 精确查词（大小写不敏感，先整词再前后缀）。
  Future<DictHit?> lookup(String word) async {
    final key = word.trim();
    if (key.isEmpty) return null;
    final index = _indexOf(key);
    if (index < 0) return null;
    final definition = await _definitionAt(entries[index]);
    if (definition.isEmpty) return null;
    return DictHit(
      word: entries[index].word,
      definition: definition,
      dictName: info.name,
    );
  }

  /// 前缀建议（最多 [limit] 条）。
  Future<List<String>> suggestions(String prefix, {int limit = 20}) async {
    final key = prefix.trim();
    if (key.isEmpty) return const [];
    var low = 0;
    var high = entries.length;
    final lower = key.toLowerCase();
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (entries[mid].word.toLowerCase().compareTo(lower) < 0) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    final out = <String>[];
    for (var i = low; i < entries.length && out.length < limit; i++) {
      if (!entries[i].word.toLowerCase().startsWith(lower)) break;
      out.add(entries[i].word);
    }
    return out;
  }

  Future<void> close() async {
    await _file?.close();
  }

  int _indexOf(String word) {
    final lower = word.toLowerCase();
    var low = 0;
    var high = entries.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final cmp = entries[mid].word.toLowerCase().compareTo(lower);
      if (cmp == 0) return mid;
      if (cmp < 0) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return -1;
  }

  Future<String> _definitionAt(({String word, int offset, int size}) entry) async {
    if (entry.size <= 0) return '';
    final Uint8List bytes;
    if (_dataMode == _DataMode.memory) {
      final data = _dataBytes;
      if (data == null) return '';
      final end = (entry.offset + entry.size).clamp(0, data.length);
      final start = entry.offset.clamp(0, data.length);
      bytes = Uint8List.sublistView(data, start, end);
    } else {
      final file = _file;
      if (file == null) return '';
      await file.setPosition(entry.offset);
      bytes = await file.read(entry.size);
    }
    return _render(bytes);
  }

  /// 按 sametypesequence / 内嵌类型字节解析释义。
  String _render(Uint8List bytes) {
    final seq = info.sametypesequence;
    final chunks = <String>[];

    if (seq.isNotEmpty) {
      var cursor = 0;
      for (var i = 0; i < seq.length; i++) {
        if (cursor >= bytes.length) break;
        final type = seq[i];
        final isLast = i == seq.length - 1;
        final slice = isLast
            ? Uint8List.sublistView(bytes, cursor)
            : _takeUntilNul(bytes, cursor);
        cursor += isLast ? bytes.length - cursor : slice.length + 1;
        chunks.add(_decodeType(type, slice));
      }
    } else {
      var cursor = 0;
      while (cursor < bytes.length) {
        final type = String.fromCharCode(bytes[cursor]);
        cursor++;
        final slice = _takeUntilNul(bytes, cursor);
        cursor += slice.length + 1;
        chunks.add(_decodeType(type, slice));
      }
    }
    return chunks.where((c) => c.trim().isNotEmpty).join('\n').trim();
  }

  static Uint8List _takeUntilNul(Uint8List bytes, int start) {
    var end = start;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    return Uint8List.sublistView(bytes, start, end);
  }

  String _decodeType(String type, Uint8List bytes) {
    final text = _decodeText(bytes);
    switch (type) {
      case 'm':
      case 'l':
        return text;
      case 'g':
      case 'x':
      case 'h':
      case 'w':
        return stripMarkup(text);
      case 't':
      case 'y':
        return text.trim().isEmpty ? '' : '[$text]';
      case 'k':
        return stripMarkup(text);
      case 'P':
        return '（图片释义）';
      default:
        return text;
    }
  }
}

enum _DataMode { file, memory }

String _decodeText(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return gbkSafeDecode(bytes);
  }
}

/// GBK 兜底（宽松模式：一处坏字节不至于丢掉整条释义）。
String gbkSafeDecode(Uint8List bytes) {
  try {
    return gbk.decode(bytes, allowMalformed: true);
  } catch (_) {
    return '';
  }
}

/// 去掉 HTML/Pango/XDXF 标签，保留换行。
String stripMarkup(String input) {
  var text = input;
  text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'</(p|div|tr|li)\s*>', caseSensitive: false), '\n');
  text = text.replaceAll(RegExp(r'<[^>]+>'), '');
  text = text
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  text = text.replaceAll(RegExp(r'[ \t]+'), ' ');
  text = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return text.trim();
}

// ---------------------------------------------------------------------------
// 解析
// ---------------------------------------------------------------------------

Map<String, String> _parseIfo(String text) {
  final map = <String, String>{};
  for (final line in text.split(RegExp(r'\r?\n'))) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    map[line.substring(0, eq).trim()] = line.substring(eq + 1).trim();
  }
  return map;
}

List<({String word, int offset, int size})> _parseIdx(Uint8List bytes) {
  final entries = <({String word, int offset, int size})>[];
  var cursor = 0;
  while (cursor < bytes.length) {
    var end = cursor;
    while (end < bytes.length && bytes[end] != 0) {
      end++;
    }
    if (end + 9 > bytes.length) break;
    final word = _decodeText(Uint8List.sublistView(bytes, cursor, end));
    final offset = (bytes[end + 1] << 24) |
        (bytes[end + 2] << 16) |
        (bytes[end + 3] << 8) |
        bytes[end + 4];
    final size = (bytes[end + 5] << 24) |
        (bytes[end + 6] << 16) |
        (bytes[end + 7] << 8) |
        bytes[end + 8];
    entries.add((word: word, offset: offset, size: size));
    cursor = end + 9;
  }
  return entries;
}

File? _findFile(Directory dir, String ext) {
  if (!dir.existsSync()) return null;
  for (final entity in dir.listSync()) {
    if (entity is File && entity.path.toLowerCase().endsWith(ext)) return entity;
  }
  return null;
}

Uint8List _gunzip(Uint8List bytes) {
  try {
    return Uint8List.fromList(gzip.decode(bytes));
  } catch (e) {
    throw FormatException('词典压缩包损坏：$e');
  }
}

String _idOf(String name) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(name)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(36);
}
