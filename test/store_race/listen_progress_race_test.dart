import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// ListenProgressStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：听书播放进度高频落盘（`record`）与移除（`remove`）并发触发。
/// 混合调用全部完成后重读 `aquan_listen.json`：键全在、值正确，JSON 完整
/// 可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_listen.json');

Future<ListenProgressStore> _newStore(Directory dir) async {
  final store = ListenProgressStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：多本进度 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('listen_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发删除的记录（与真实时序一致）。
    await store.record(
      bookId: 'b-del',
      title: '待删除',
      coverUrl: '',
      chapterId: 'c0',
      chapterTitle: '章0',
      chapterIndex: 0,
      chapters: 10,
      toneId: 1,
      positionMs: 5000,
    );

    // 同一事件循环内的并发混合写：5 本书的进度写 + 1 条删除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.record(
          bookId: 'b$i',
          title: '听书$i',
          coverUrl: 'cover-$i',
          chapterId: 'c$i',
          chapterTitle: '章$i',
          chapterIndex: i,
          chapters: 20,
          toneId: 2,
          positionMs: 1000 * i,
        ),
      store.remove('b-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['b1', 'b2', 'b3', 'b4', 'b5']));
    expect(json.containsKey('b-del'), isFalse, reason: '并发删除不丢（不被旧快照写回）');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    for (var i = 1; i <= 5; i++) {
      expect(store2.entry('b$i')!.positionMs, 1000 * i, reason: 'b$i 进度不被并发写覆盖');
      expect(store2.entry('b$i')!.chapterIndex, i);
    }
    expect(store2.entry('b-del'), isNull);
    expect(store2.entries.length, 5);
  });
}
