import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/image_cache_store.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('image_cache_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ImageCacheStore newStore({int? limit, int? maxBytes}) =>
      ImageCacheStore(directory: () async => tmp, limit: limit, maxBytes: maxBytes);

  group('ImageCacheStore 读写与持久化', () {
    test('put/get 往返（字节原样）', () async {
      final store = newStore();
      final bytes = [1, 2, 3, 250, 0, 42];
      await store.put('k1', bytes);
      expect(await store.get('k1'), bytes);
      expect(await store.get('missing'), isNull);
    });

    test('跨实例持久化（模拟重启后命中）', () async {
      await newStore().put('cover', [9, 9, 9]);
      final second = newStore();
      expect(await second.get('cover'), [9, 9, 9]);
      expect(await second.entryCount(), 1);
    });

    test('同 key 重写覆盖', () async {
      final store = newStore();
      await store.put('k', [1, 1]);
      await store.put('k', [2, 2, 2]);
      expect(await store.get('k'), [2, 2, 2]);
      expect(await store.entryCount(), 1);
    });

    test('条数上限：最旧先淘汰', () async {
      final store = newStore(limit: 2);
      await store.put('a', [1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.put('b', [2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.put('c', [3]);
      expect(await store.entryCount(), 2);
      expect(await store.get('a'), isNull, reason: '最旧的 a 被淘汰');
      expect(await store.get('b'), [2]);
      expect(await store.get('c'), [3]);
    });

    test('字节上限：新者优先保留，超限条目淘汰', () async {
      final store = newStore(maxBytes: 32);
      await store.put('big', List<int>.generate(100, (i) => i % 256));
      await store.put('small', [7]);
      // 新者优先：small 保留在预算内；big 超限被淘汰。
      expect(await store.entryCount(), 1);
      expect(await store.get('small'), [7]);
      expect(await store.get('big'), isNull);
    });

    test('单条本身超上限仍保留（至少一条语义）', () async {
      final store = newStore(maxBytes: 32);
      await store.put('huge', List<int>.generate(100, (i) => i % 256));
      expect(await store.get('huge'), isNotNull);
      expect(await store.entryCount(), 1);
    });

    test('访问续期：命中后不再是最旧', () async {
      final store = newStore(limit: 2);
      await store.put('a', [1]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.put('b', [2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.get('a'); // a 续期
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await store.put('c', [3]); // 淘汰 b（最旧）
      expect(await store.get('a'), [1]);
      expect(await store.get('b'), isNull);
      expect(await store.get('c'), [3]);
    });

    test('损坏文件视为未命中且被清走', () async {
      await newStore().put('k', [1, 2, 3]);
      // 找到落盘文件并写坏。
      final bin = tmp
          .listSync()
          .whereType<File>()
          .firstWhere((f) => f.path.endsWith('.bin'));
      await bin.writeAsBytes([0, 0, 0, 255]); // keyLen 非法
      final store = newStore();
      expect(await store.get('k'), isNull);
      expect(bin.existsSync(), isFalse, reason: '损坏文件应被清走');
    });

    test('clear 只清仓内文件', () async {
      final store = newStore();
      await store.put('x', [1]);
      final stranger = File('${tmp.path}${Platform.pathSeparator}other.txt');
      await stranger.writeAsString('keep me');
      await store.clear();
      expect(await store.entryCount(), 0);
      expect(await store.get('x'), isNull);
      expect(stranger.existsSync(), isTrue, reason: '不碰仓外文件');
    });

    test('remove 单条', () async {
      final store = newStore();
      await store.put('a', [1]);
      await store.remove('a');
      expect(await store.get('a'), isNull);
      expect(await store.entryCount(), 0);
    });
  });
}
