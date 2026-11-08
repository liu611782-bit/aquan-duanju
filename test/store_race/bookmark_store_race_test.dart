import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// BookmarkStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：阅读器加书签（`add`）、改批注（`updateNote`）、删书签（`remove`）、
/// 清空整书（`clearBook`）并发触发。混合调用全部完成后重读
/// `aquan_bookmarks.json`：键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_bookmarks.json');

Future<BookmarkStore> _newStore(Directory dir) async {
  final store = BookmarkStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：加书签 + 批注 + 删除 + 清书，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('bookmark_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落将被并发操作的书签（与真实时序一致）。
    final old = await store.add(
      bookId: 'book-a',
      chapterId: 'ch0',
      chapterIndex: 0,
      charOffset: 10,
    );

    // 同一事件循环内的并发混合写：3 本书加书签 + book-a 批注/删除 + book-b 清空。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.add(
          bookId: 'book$i',
          chapterId: 'ch$i',
          chapterIndex: i,
          charOffset: 100 + i,
          excerpt: '摘录$i',
        ),
      store.updateNote('book-a', old.id, '重点段落'),
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
      expect(list.single.charOffset, 100 + i);
      expect(list.single.excerpt, '摘录$i');
    }
    expect(store2.of('book-a'), isEmpty);
    expect(store2.countOf('book-b'), 0);
  });
}
