import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/tts_unit_cache.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late TtsUnitCache cache;
  const key = TtsUnitKey(
    bookId: 'booksrc:https://x.example:https://x.example/book/1',
    chapterId: 'https://x.example/c/2',
    engineId: 'edge',
    voiceId: 'zh-CN-Yunxi',
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('tts_unit_cache');
    cache = TtsUnitCache(root: Directory('${tmp.path}/units'));
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('写入全部单元后命中，并汇总时长', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 3,
      textSignature: 'sig1',
      extension: 'mp3',
    );
    for (var i = 0; i < 3; i++) {
      await cache.writeUnit(
        chapter,
        i,
        Uint8List.fromList([i, i, i]),
        durationMs: (i + 1) * 1000,
        timelineJson: '[]',
      );
    }
    await cache.finish(chapter);

    final hit = await cache.lookup(key, textSignature: 'sig1', extension: 'mp3');
    expect(hit, isNotNull);
    expect(hit!.units, hasLength(3));
    expect(hit.totalDurationMs, 6000);
    expect(File(hit.units.first.audioPath).existsSync(), isTrue);
  });

  test('签名不一致 → 未命中（源站改文后整章重合成）', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 1,
      textSignature: 'sig1',
      extension: 'mp3',
    );
    await cache.writeUnit(chapter, 0, Uint8List.fromList([1]), durationMs: 100);
    await cache.finish(chapter);

    expect(await cache.lookup(key, textSignature: 'sig2', extension: 'mp3'), isNull);
  });

  test('缺一个单元 → 整章未命中（不播半章）', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 2,
      textSignature: 's',
      extension: 'mp3',
    );
    await cache.writeUnit(chapter, 0, Uint8List.fromList([1]), durationMs: 100);
    await cache.writeUnit(chapter, 1, Uint8List.fromList([2]), durationMs: 100);
    await cache.finish(chapter);
    // 删掉第二个单元文件
    File(chapter.unitFile(1).path).deleteSync();

    expect(await cache.lookup(key, textSignature: 's', extension: 'mp3'), isNull);
  });

  test('未 finish 的半成品不被命中，且可被 pruneOrphans 清掉', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 2,
      textSignature: 's',
      extension: 'mp3',
    );
    await cache.writeUnit(chapter, 0, Uint8List.fromList([1]), durationMs: 100);

    expect(await cache.lookup(key, textSignature: 's', extension: 'mp3'), isNull);
    expect(chapter.directory.existsSync(), isTrue);

    final removed = await cache.pruneOrphans();
    expect(removed, 1);
    expect(chapter.directory.existsSync(), isFalse);
  });

  test('keepKeys 里的章不被清理（正在合成）', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 1,
      textSignature: 's',
      extension: 'mp3',
    );
    final keep = '${key.bookDirName}/${chapter.directory.path.split(RegExp(r'[/\\]')).last}';
    final removed = await cache.pruneOrphans(keepKeys: {keep});
    expect(removed, 0);
    expect(chapter.directory.existsSync(), isTrue);
  });

  test('finish 时缺单元会报错（防止落一个不完整的 index）', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 2,
      textSignature: 's',
      extension: 'mp3',
    );
    await cache.writeUnit(chapter, 0, Uint8List.fromList([1]), durationMs: 100);
    await expectLater(cache.finish(chapter), throwsA(isA<StateError>()));
  });

  test('格式版本不符 → 未命中，且 pruneOrphans 会删掉旧格式目录', () async {
    final chapter = await cache.openChapter(
      key,
      unitCount: 1,
      textSignature: 's',
      extension: 'mp3',
    );
    await cache.writeUnit(chapter, 0, Uint8List.fromList([1]), durationMs: 100);
    await cache.finish(chapter);
    // 手改 index：模拟上一版产物（例如尾部裁剪余量更小）。
    final index = chapter.indexFile;
    final text = await index.readAsString();
    await index.writeAsString(
      text.replaceFirst('"format":$kTtsUnitCacheFormat', '"format":1'),
    );

    expect(await cache.lookup(key, textSignature: 's', extension: 'mp3'), isNull);
    final removed = await cache.pruneOrphans();
    expect(removed, 1);
    expect(chapter.directory.existsSync(), isFalse);
  });

  test('键里的非法路径字符被替换（第三方书源 URL 也能当目录名）', () {
    expect(key.dirName.contains('/'), isFalse);
    expect(key.dirName.contains(':'), isFalse);
    expect(key.bookDirName.contains('/'), isFalse);
  });
}
