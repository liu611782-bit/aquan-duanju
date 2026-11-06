import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/image_cache_index.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('aquan_image_index_');
    addTearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });
  });

  test('upsert / lookup / isStale / touch / remove', () {
    final idx = ImageCacheIndex();
    expect(idx.isStale('https://x/a.jpg'), isTrue);
    idx.upsert('https://x/a.jpg', size: 42);
    expect(idx.length, 1);
    expect(idx.lookup('https://x/a.jpg')!.size, 42);
    expect(idx.isStale('https://x/a.jpg'), isFalse);

    final old = DateTime(2020, 1, 1);
    idx.touch('https://x/a.jpg', atime: DateTime(2026, 1, 1));
    expect(idx.lookup('https://x/a.jpg')!.atime.year, 2026);
    expect(idx.lookup('https://x/a.jpg')!.fetchedAt.isAfter(old), isTrue);

    idx.remove('https://x/a.jpg');
    expect(idx.isEmpty, isTrue);
  });

  test('TTL 以抓取时间为准，恰好满 7 天即过期', () {
    final at = DateTime(2026, 1, 1);
    expect(
      ImageCacheIndex.isExpired(at,
          now: at.add(const Duration(days: 7))),
      isTrue,
    );
    expect(
      ImageCacheIndex.isExpired(at,
          now: at.add(const Duration(days: 7) - const Duration(milliseconds: 1))),
      isFalse,
    );
  });

  test('save/load 往返；索引损坏时回退扫盘并删坏文件', () async {
    final idx = ImageCacheIndex();
    idx.upsert('https://x/a.jpg',
        size: 42, fetchedAt: DateTime(2026, 1, 1));
    await idx.save(dir);

    final loaded = await ImageCacheIndex.load(dir);
    expect(loaded.needsRescan, isFalse);
    expect(loaded.lookup('https://x/a.jpg')!.size, 42);

    final file = File(
        '${dir.path}${Platform.pathSeparator}${ImageCacheIndex.fileName}');
    await file.writeAsString('{broken');
    final corrupt = await ImageCacheIndex.load(dir);
    expect(corrupt.needsRescan, isTrue);
    expect(corrupt.isEmpty, isTrue);
    expect(await file.exists(), isFalse);
  });

  test('索引缺失时 needsRescan = true', () async {
    final missing = await ImageCacheIndex.load(dir);
    expect(missing.needsRescan, isTrue);
  });
}
