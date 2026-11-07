import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// ReadingProgressStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：阅读器高频进度写（900ms 防抖 + 漫画自动续号，`record`）与用户操作
/// （封面回填 `fillCover`、删除 `remove`）同刻并发触发。混合调用全部完成后
/// 重读 `aquan_reading.json`：全部书籍键都在、进度/封面正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_reading.json');

Future<ReadingProgressStore> _newStore(Directory dir) async {
  final store = ReadingProgressStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 高频进度写 × 用户操作：进度多次 + 封面回填 + 删除，无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('reading_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发删除的进度 + 一条待回填封面的记录。
    await store.record(
      bookId: 'b-del',
      title: '待删除',
      coverUrl: '',
      chapterId: 'c1',
      chapterTitle: '一章',
      chapterIndex: 0,
      chapters: 10,
      offset: 0.5,
    );
    await store.record(
      bookId: 'b1',
      title: '书1',
      coverUrl: '',
      chapterId: 'c1',
      chapterTitle: '一章',
      chapterIndex: 0,
      chapters: 10,
      offset: 0.1,
    );

    // 同一事件循环内的并发混合写：同一本书 8 次高频进度写（自动续号，最终值 =
    // 最后一次）+ 另一本书 4 次进度写 + 封面回填 + 删除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 8; i++)
        store.record(
          bookId: 'b1',
          title: '书1',
          coverUrl: '',
          chapterId: 'c$i',
          chapterTitle: '章$i',
          chapterIndex: i,
          chapters: 20,
          offset: i / 10,
        ),
      for (var i = 1; i <= 4; i++)
        store.record(
          bookId: 'b2',
          title: '书2',
          coverUrl: 'cover-2',
          chapterId: 'c$i',
          chapterTitle: '章$i',
          chapterIndex: i,
          chapters: 30,
          offset: i / 10,
        ),
      store.fillCover('b1', 'http://img/cover1.jpg'),
      store.remove('b-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['b1', 'b2']));
    expect(json.containsKey('b-del'), isFalse, reason: '并发删除不被旧快照写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    final b1 = store2.entry('b1')!;
    expect(b1.offset, 0.8, reason: '最后一次进度写胜出');
    expect(b1.chapterIndex, 8);
    expect(b1.coverUrl, 'http://img/cover1.jpg', reason: '封面回填不被并发进度写覆盖');
    expect(b1.revision, greaterThan(0), reason: '进度写自动续号');
    final b2 = store2.entry('b2')!;
    expect(b2.offset, 0.4);
    expect(b2.coverUrl, 'cover-2', reason: '已有封面不被 fillCover 空串清掉');
    expect(store2.entry('b-del'), isNull);
  });

  test('revision 守卫与条件跳过回归：旧序号写入被忽略、封面已非空不再写', () async {
    final dir = await Directory.systemTemp.createTemp('reading_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    final rev = await store.revisionOf('b1');
    await store.record(
      bookId: 'b1',
      title: '书1',
      coverUrl: 'c',
      chapterId: 'c1',
      chapterTitle: '一章',
      chapterIndex: 1,
      chapters: 10,
      offset: 0.5,
      revision: rev + 1,
    );
    final before = _file(dir).readAsStringSync();

    // 旧序号（≤ 已存序号）写进度：直接忽略，不写盘。
    await store.record(
      bookId: 'b1',
      title: '书1',
      coverUrl: 'c',
      chapterId: 'c0',
      chapterTitle: '零章',
      chapterIndex: 0,
      chapters: 10,
      offset: 0.1,
      revision: rev + 1,
    );
    expect(_file(dir).readAsStringSync(), before, reason: 'revision 守卫不写盘');

    // 封面已非空：fillCover 条件跳过并返回 false，不写盘。
    expect(await store.fillCover('b1', 'http://img/new.jpg'), isFalse);
    expect(_file(dir).readAsStringSync(), before);

    // 删除不存在的书：条件跳过不写盘。
    await store.remove('b-none');
    expect(_file(dir).readAsStringSync(), before);

    final store2 = await _newStore(dir);
    expect(store2.entry('b1')!.chapterId, 'c1', reason: '旧快照没有写回覆盖新进度');
  });
}
