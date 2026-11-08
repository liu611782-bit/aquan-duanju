import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// MarkingStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：阅读器划线（`add`）、改批注（`updateNote`）、删划线（`remove`）、
/// 清空整书（`clearBook`）并发触发。混合调用全部完成后重读
/// `aquan_markings.json`：键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_markings.json');

Future<MarkingStore> _newStore(Directory dir) async {
  final store = MarkingStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：划线 + 批注 + 删除 + 清书，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('marking_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落将被并发操作的划线（与真实时序一致）。
    final old = (await store.add(
      bookId: 'book-a',
      chapterId: 'ch0',
      chapterIndex: 0,
      charStart: 10,
      charEnd: 30,
      text: '旧划线',
    ))!;

    // 同一事件循环内的并发混合写：3 本书划线 + book-a 批注/删除 + book-b 清空。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.add(
          bookId: 'book$i',
          chapterId: 'ch$i',
          chapterIndex: i,
          charStart: 100 + i,
          charEnd: 200 + i,
          text: '划线$i',
        ),
      store.updateNote('book-a', old.id, '重要'),
      store.remove('book-a', old.id),
      store.clearBook('book-b'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>['book1', 'book2', 'book3', 'book4', 'book5']),
    );
    expect(json.containsKey('book-a'), isFalse, reason: '并发删除不丢（不被旧快照写回）');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    for (var i = 1; i <= 5; i++) {
      final list = store2.of('book$i');
      expect(list.length, 1, reason: 'book$i 不被并发写抹掉');
      expect(list.single.charStart, 100 + i);
      expect(list.single.charEnd, 200 + i);
      expect(list.single.text, '划线$i');
    }
    expect(store2.of('book-a'), isEmpty);
    expect(store2.countOf('book-b'), 0);
  });
}
