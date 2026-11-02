/// 朗读流式合成的**单元缓存**（`11-02-listen-tts-streaming` S1）。
///
/// 与整章缓存（`tts_cache.dart`）并存，布局：
/// ```
/// <root>/<bookId>/<chapterId>-<engineId>-<voiceId>/
///     index.json      {unitCount, textSignature, units:[{durationMs, bytes, timeline?}]}
///     u000.<ext>      单元音频
/// ```
/// 规则：
/// - **写完所有单元才写 index.json**（原子写：临时文件 + rename）。没有 index = 未完成，
///   读的时候视为未命中，且可被 `pruneOrphans` 清掉。
/// - `textSignature` 进 index：源站改文后整章失效（与整章缓存同一判定语义）。
/// - 本类不做合成、不碰播放器，只负责「按单元读写 + 盘点」。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// 一个章目录的键（与整章缓存的键语义保持一致：含引擎与音色，不含倍速）。
class TtsUnitKey {
  const TtsUnitKey({
    required this.bookId,
    required this.chapterId,
    required this.engineId,
    required this.voiceId,
  });

  final String bookId;
  final String chapterId;
  final String engineId;
  final String voiceId;

  /// 目录名：Windows 路径不合法字符统一替换。
  String get dirName {
    final raw = '$chapterId-$engineId-$voiceId';
    final safe = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return safe.length <= 120 ? safe : safe.substring(0, 120);
  }

  String get bookDirName =>
      bookId.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  @override
  String toString() => '$bookId/$dirName';
}

/// 一个已打开（可能尚未完成）的章目录。
class TtsChapterUnits {
  TtsChapterUnits({
    required this.key,
    required this.directory,
    required this.extension,
    required this.unitCount,
    required this.textSignature,
  });

  final TtsUnitKey key;
  final Directory directory;
  final String extension;
  final int unitCount;
  final String textSignature;

  File unitFile(int index) =>
      File('${directory.path}/${_unitName(index, extension)}');

  File get indexFile => File('${directory.path}/index.json');
}

String _unitName(int index, String ext) =>
    'u${index.toString().padLeft(3, '0')}.$ext';

/// 命中结果：单元齐全的一章。
class TtsChapterHit {
  const TtsChapterHit({
    required this.units,
    required this.totalDurationMs,
  });

  final List<TtsUnitHit> units;
  final int totalDurationMs;
}

class TtsUnitHit {
  const TtsUnitHit({
    required this.index,
    required this.audioPath,
    required this.durationMs,
    this.timelineJson = '',
  });

  final int index;
  final String audioPath;
  final int durationMs;
  final String timelineJson;
}

/// 单元缓存。
class TtsUnitCache {
  TtsUnitCache({required this.root});

  /// 默认根目录：与整章缓存同级的 `audio_cache_units`。
  static Future<TtsUnitCache> openDefault() async {
    final support = await getApplicationSupportDirectory();
    return TtsUnitCache(
      root: Directory('${support.path}/audio_cache_units'),
    );
  }

  final Directory root;

  /// 打开一章的单元目录（不存在则创建）。
  Future<TtsChapterUnits> openChapter(
    TtsUnitKey key, {
    required int unitCount,
    required String textSignature,
    required String extension,
  }) async {
    final dir = Directory('${root.path}/${key.bookDirName}/${key.dirName}');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return TtsChapterUnits(
      key: key,
      directory: dir,
      extension: extension,
      unitCount: unitCount,
      textSignature: textSignature,
    );
  }

  /// 写一个单元（`durationMs` 与时间点由合成层给）。
  Future<void> writeUnit(
    TtsChapterUnits chapter,
    int index,
    Uint8List audio, {
    required int durationMs,
    String timelineJson = '',
  }) async {
    final file = chapter.unitFile(index);
    await file.writeAsBytes(audio, flush: true);
    // 单元旁挂一份小元数据，`finish` 时汇总进 index.json。
    await File('${file.path}.meta.json').writeAsString(
      jsonEncode({'durationMs': durationMs, 'timeline': timelineJson}),
      flush: true,
    );
  }

  /// 全部单元写完后落 `index.json`（原子写）。
  ///
  /// 中途失败不会调用它 → 目录没有 index → 读取视为未命中，可被清理。
  Future<void> finish(TtsChapterUnits chapter) async {
    final units = <Map<String, dynamic>>[];
    var total = 0;
    for (var i = 0; i < chapter.unitCount; i++) {
      final audio = chapter.unitFile(i);
      if (!audio.existsSync()) {
        throw StateError('单元 $i 缺失，不能落 index（章目录：${chapter.directory.path}）');
      }
      final meta = File('${audio.path}.meta.json');
      var durationMs = 0;
      var timeline = '';
      if (meta.existsSync()) {
        try {
          final json = jsonDecode(await meta.readAsString());
          if (json is Map<String, dynamic>) {
            durationMs = (json['durationMs'] as num?)?.toInt() ?? 0;
            timeline = json['timeline']?.toString() ?? '';
          }
        } catch (_) {
          // 元数据坏了按 0 处理：音频还在，只是对齐精度下降。
        }
      }
      total += durationMs;
      units.add({
        'i': i,
        'durationMs': durationMs,
        if (timeline.isNotEmpty) 'timeline': timeline,
        'bytes': await audio.length(),
      });
    }

    final payload = jsonEncode({
      'unitCount': chapter.unitCount,
      'textSignature': chapter.textSignature,
      'totalDurationMs': total,
      'units': units,
    });
    final tmp = File('${chapter.indexFile.path}.tmp');
    await tmp.writeAsString(payload, flush: true);
    await tmp.rename(chapter.indexFile.path);
  }

  /// 读一章：index 存在、签名一致、单元文件齐全才算命中。
  Future<TtsChapterHit?> lookup(
    TtsUnitKey key, {
    required String textSignature,
    required String extension,
  }) async {
    final dir = Directory('${root.path}/${key.bookDirName}/${key.dirName}');
    final indexFile = File('${dir.path}/index.json');
    if (!indexFile.existsSync()) return null;

    Map<String, dynamic> index;
    try {
      final json = jsonDecode(await indexFile.readAsString());
      if (json is! Map<String, dynamic>) return null;
      index = json;
    } catch (_) {
      return null;
    }
    if ((index['textSignature'] ?? '').toString() != textSignature) return null;

    final units = <TtsUnitHit>[];
    var total = 0;
    final rawUnits = index['units'];
    if (rawUnits is! List) return null;
    for (final item in rawUnits) {
      if (item is! Map) return null;
      final i = (item['i'] as num?)?.toInt() ?? -1;
      if (i < 0) return null;
      final audio = File('${dir.path}/${_unitName(i, extension)}');
      if (!audio.existsSync()) return null; // 缺一个就当整章未命中
      final durationMs = (item['durationMs'] as num?)?.toInt() ?? 0;
      total += durationMs;
      units.add(TtsUnitHit(
        index: i,
        audioPath: audio.path,
        durationMs: durationMs,
        timelineJson: item['timeline']?.toString() ?? '',
      ));
    }
    if (units.isEmpty) return null;
    return TtsChapterHit(units: units, totalDurationMs: total);
  }

  /// 清掉没有 `index.json` 的章目录（合成中断留下的半成品）。
  ///
  /// 返回删除的目录数；`keepKeys` 里的章即使未完成也保留（正在合成）。
  Future<int> pruneOrphans({Set<String> keepKeys = const {}}) async {
    if (!root.existsSync()) return 0;
    var removed = 0;
    for (final bookDir in root.listSync().whereType<Directory>()) {
      for (final chapterDir in bookDir.listSync().whereType<Directory>()) {
        final key = '${bookDir.path.split(RegExp(r'[/\\]')).last}/'
            '${chapterDir.path.split(RegExp(r'[/\\]')).last}';
        if (keepKeys.contains(key)) continue;
        if (File('${chapterDir.path}/index.json').existsSync()) continue;
        try {
          await chapterDir.delete(recursive: true);
          removed++;
        } catch (_) {
          // 删不掉（占用）就留到下次启动。
        }
      }
      if (bookDir.listSync().isEmpty) {
        try {
          await bookDir.delete();
        } catch (_) {}
      }
    }
    return removed;
  }
}
