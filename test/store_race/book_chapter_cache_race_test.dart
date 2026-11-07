import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// BookChapterCache 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：连续章节抓取落盘（`put`，每章成功即写）与删除（`remove`）同刻并发
/// 触发。混合调用全部完成后重读 `aquan_book_cache.json`：全部章节键都在、
/// 正文/签名正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_book_cache.json');

Future<BookChapterCache> _newStore(Directory dir) async {
  final store = BookChapterCache(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：多章 put + 同键覆盖 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('book_cache_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发移除的缓存。
    await store.put('item-del', '待删除正文', signature: 'sig-del');

    // 同一事件循环内的并发混合写：6 章新缓存 + 同一章 3 次覆盖（最终值 =
    // 最后一次）+ 1 条移除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 6; i++)
        store.put('item$i', '第$i章正文' * (i + 1), signature: 'sig-$i'),
      for (var i = 1; i <= 3; i++)
        store.put('item-dup', '覆盖正文v$i', signature: 'sig-dup-$i'),
      store.remove('item-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>[
        'item1',
        'item2',
        'item3',
        'item4',
        'item5',
        'item6',
        'item-dup',
      ]),
    );
    expect(json.containsKey('item-del'), isFalse, reason: '并发移除不被旧快照写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.text('item1'), '第1章正文' * 2);
    expect(
      store2.text('item6', expectSignature: 'sig-6'),
      isNotNull,
      reason: '签名一致才返回正文',
    );
    expect(
      store2.text('item-dup', expectSignature: 'sig-dup-3'),
      '覆盖正文v3',
      reason: '最后一次覆盖胜出',
    );
    expect(store2.text('item-del'), isNull);
    expect(store2.signatureOf('item-dup'), 'sig-dup-3');
  });

  test('顺序写与清空回归：逐次 await 的最终值与旧版一致', () async {
    final dir = await Directory.systemTemp.createTemp('book_cache_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    await store.put('a', '正文A', signature: 'sig-a');
    await store.put('a', '正文A2');
    await store.put('b', '正文B');
    await store.remove('b');

    final store2 = await _newStore(dir);
    expect(store2.text('a'), '正文A2');
    expect(store2.text('b'), isNull);
    expect(store2.totalBytes, greaterThan(0));
  });
}
