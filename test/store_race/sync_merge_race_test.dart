import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

/// mergeRemoteJson 并发回归锁（11-08-book-sync-race）。
///
/// 场景：云同步恢复（`mergeRemoteJson`，旧版对 JSON 文件队列外直写）与该库
/// 常规写者（进度 `record`/`fillCover`/`remove`，书签/划线 `add`）在同一事件
/// 循环内并发触发。混合调用全部完成后重读 JSON：远端合并进来的键与本地并发
/// 写入的键全在、无键丢失；新实例（模拟重启）读回一致。

File _progressFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_reading.json');

File _bookmarkFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_bookmarks.json');

File _markingFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_markings.json');

void main() {
  test('进度：mergeRemoteJson × record/fillCover/remove 并发，键全在不丢', () async {
    final dir = await Directory.systemTemp.createTemp('merge_race_read');
    addTearDown(() => dir.delete(recursive: true));
    final store = ReadingProgressStore(testDirectory: dir);
    await store.loadFromDisk();

    // 先落两条将被并发操作的记录：待删除的 b-del、待回填封面的 b3。
    await store.record(
      bookId: 'b-del',
      title: '待删除',
      coverUrl: '',
      chapterId: 'c1',
      chapterTitle: '一章',
      chapterIndex: 0,
      chapters: 10,
      offset: 0.1,
    );
    await store.record(
      bookId: 'b3',
      title: '书3',
      coverUrl: '',
      chapterId: 'c1',
      chapterTitle: '一章',
      chapterIndex: 1,
      chapters: 10,
      offset: 0.3,
    );

    // 同一事件循环内的并发混合写：两次远端合并（r1/r2/r3 均为新键）+
    // 本地进度写 + 封面回填 + 删除。
    final futures = <Future<void>>[
      store.mergeRemoteJson(jsonEncode({
        'r1': {
          'title': '远端1',
          'chapter_index': 2,
          'updated_at': '2030-01-01T00:00:00.000Z',
        },
        'r2': {
          'title': '远端2',
          'chapter_index': 3,
          'updated_at': '2030-01-01T00:00:00.000Z',
        },
      })),
      store.mergeRemoteJson(jsonEncode({
        'r3': {
          'title': '远端3',
          'chapter_index': 4,
          'updated_at': '2030-01-01T00:00:00.000Z',
        },
      })),
      store.record(
        bookId: 'b2',
        title: '书2',
        coverUrl: '',
        chapterId: 'c1',
        chapterTitle: '一章',
        chapterIndex: 1,
        chapters: 10,
        offset: 0.2,
      ),
      store.fillCover('b3', 'http://img/cover3.jpg'),
      store.remove('b-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：远端键与本地键全在，删除不被写回。
    final json =
        jsonDecode(_progressFile(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['r1', 'r2', 'r3', 'b2', 'b3']));
    expect(json.containsKey('b-del'), isFalse, reason: '并发删除不被合并写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = ReadingProgressStore(testDirectory: dir);
    await store2.loadFromDisk();
    expect(store2.entry('r1')!.title, '远端1');
    expect(store2.entry('r2')!.chapterIndex, 3);
    expect(store2.entry('r3')!.chapterIndex, 4);
    expect(store2.entry('b2')!.offset, 0.2);
    expect(store2.entry('b3')!.coverUrl, 'http://img/cover3.jpg',
        reason: '封面回填不被并发合并覆盖');
    expect(store2.entry('b-del'), isNull);
  });

  test('书签：mergeRemoteJson × add 并发，远端与本地书签全在', () async {
    final dir = await Directory.systemTemp.createTemp('merge_race_bm');
    addTearDown(() => dir.delete(recursive: true));
    final store = BookmarkStore(testDirectory: dir);
    await store.loadFromDisk();

    // 并发：远端合并（book-r 补 2 条）+ 本地 3 本书写入，其中 book-r 同时
    // 被本地 add（同一本书「合并 × 新增」交错的压力路径）。
    final futures = <Future<void>>[
      store.mergeRemoteJson(jsonEncode({
        'book-r': [
          {
            'id': 'bm-r1',
            'chapter_id': 'ch1',
            'chapter_index': 1,
            'char_offset': 11,
            'excerpt': '远端1',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
          {
            'id': 'bm-r2',
            'chapter_id': 'ch1',
            'chapter_index': 2,
            'char_offset': 12,
            'excerpt': '远端2',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
        ],
      })),
      store.add(
        bookId: 'book-r',
        chapterId: 'ch2',
        chapterIndex: 2,
        charOffset: 23,
        excerpt: '本地混入远端书',
      ),
      store.add(
        bookId: 'book-l1',
        chapterId: 'ch1',
        chapterIndex: 1,
        charOffset: 21,
        excerpt: '本地1',
      ),
      store.add(
        bookId: 'book-l2',
        chapterId: 'ch1',
        chapterIndex: 1,
        charOffset: 22,
        excerpt: '本地2',
      ),
    ];
    await Future.wait(futures);

    final json =
        jsonDecode(_bookmarkFile(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['book-r', 'book-l1', 'book-l2']));
    expect(json['book-r'], hasLength(3), reason: '远端 2 条 + 本地并发加的 1 条都在');

    final store2 = BookmarkStore(testDirectory: dir);
    await store2.loadFromDisk();
    expect(store2.countOf('book-r'), 3);
    expect(store2.of('book-r').map((m) => m.id), containsAll(<String>['bm-r1', 'bm-r2']));
    expect(store2.countOf('book-l1'), 1);
    expect(store2.countOf('book-l2'), 1);
  });

  test('划线：mergeRemoteJson × add 并发，远端与本地划线全在', () async {
    final dir = await Directory.systemTemp.createTemp('merge_race_mk');
    addTearDown(() => dir.delete(recursive: true));
    final store = MarkingStore(testDirectory: dir);
    await store.loadFromDisk();

    final futures = <Future<void>>[
      store.mergeRemoteJson(jsonEncode({
        'book-r': [
          {
            'id': 'mk-r1',
            'chapter_id': 'ch1',
            'chapter_index': 1,
            'char_start': 10,
            'char_end': 20,
            'text': '远端1',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
        ],
      })),
      store.add(
        bookId: 'book-r',
        chapterId: 'ch1',
        chapterIndex: 1,
        charStart: 30,
        charEnd: 40,
        text: '本地划线',
      ),
      store.add(
        bookId: 'book-l1',
        chapterId: 'ch1',
        chapterIndex: 1,
        charStart: 50,
        charEnd: 60,
        text: '别的书',
      ),
    ];
    await Future.wait(futures);

    final json =
        jsonDecode(_markingFile(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['book-r', 'book-l1']));
    expect(json['book-r'], hasLength(2), reason: '远端 + 本地并发加的划线都在');

    final store2 = MarkingStore(testDirectory: dir);
    await store2.loadFromDisk();
    expect(store2.countOf('book-r'), 2);
    expect(
      store2.of('book-r').map((m) => m.id),
      containsAll(<String>['mk-r1']),
    );
    expect(store2.countOf('book-l1'), 1);
  });
}
