import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三个阅读状态库 `mergeRemoteJson` 单测（11-08-book-sync-race）。
///
/// 覆盖：新增 / 较新覆盖 / 较旧保留 / 空远端 / 坏 JSON 容错，以及合并后
/// 内存即时刷新（与文件一致，恢复后不再需要重启加载）。

File _progressFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_reading.json');

File _bookmarkFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_bookmarks.json');

File _markingFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_markings.json');

void main() {
  group('ReadingProgressStore.mergeRemoteJson', () {
    test('空本地：远端全量补入，内存与文件同步生效，通知一次', () async {
      final dir = await Directory.systemTemp.createTemp('merge_read_new');
      addTearDown(() => dir.delete(recursive: true));
      final store = ReadingProgressStore(testDirectory: dir);
      // 生产里所有库在启动 bootstrap 就 ensureLoaded（监听在合并前已就绪），
      // 这里同样先加载完再挂监听，只统计本次合并的通知。
      await store.loadFromDisk();

      var notify = 0;
      store.addListener(() => notify++);
      final changed = await store.mergeRemoteJson(jsonEncode({
        'a': {
          'title': 'A',
          'chapter_index': 3,
          'updated_at': '2026-11-08T00:00:00.000Z',
        },
      }));

      expect(changed, 1);
      expect(notify, 1, reason: '有变化只通知一次');
      expect(store.entry('a')!.chapterIndex, 3, reason: '内存即时生效');
      final json =
          jsonDecode(_progressFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['a'] as Map)['chapter_index'], 3);
    });

    test('同书较新覆盖、较旧保留（内存与文件一致）', () async {
      final dir = await Directory.systemTemp.createTemp('merge_read_conflict');
      addTearDown(() => dir.delete(recursive: true));
      final store = ReadingProgressStore(testDirectory: dir);
      await store.record(
        bookId: 'keep',
        title: '留',
        coverUrl: '',
        chapterId: 'c1',
        chapterTitle: '一章',
        chapterIndex: 1,
        chapters: 10,
        offset: 0.5,
      );
      await store.record(
        bookId: 'win',
        title: '盖',
        coverUrl: '',
        chapterId: 'c1',
        chapterTitle: '一章',
        chapterIndex: 1,
        chapters: 10,
        offset: 0.5,
      );

      final changed = await store.mergeRemoteJson(jsonEncode({
        'keep': {
          'title': '旧',
          'chapter_index': 9,
          'updated_at': '2026-01-01T00:00:00.000Z',
        },
        'win': {
          'title': '新',
          'chapter_index': 9,
          'updated_at': '2030-01-01T00:00:00.000Z',
        },
      }));

      expect(changed, 1, reason: '只有较新的一条算变更');
      final keep = store.entry('keep')!;
      expect(keep.title, '留', reason: '较旧远端不动本地');
      expect(keep.chapterIndex, 1);
      final win = store.entry('win')!;
      expect(win.title, '新', reason: '较新远端覆盖内存');
      expect(win.chapterIndex, 9);
      final json =
          jsonDecode(_progressFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['keep'] as Map)['chapter_index'], 1);
      expect((json['win'] as Map)['chapter_index'], 9);
    });

    test('空远端与坏 JSON：容错为无变化，不写盘不通知', () async {
      final dir = await Directory.systemTemp.createTemp('merge_read_empty');
      addTearDown(() => dir.delete(recursive: true));
      final store = ReadingProgressStore(testDirectory: dir);
      await store.record(
        bookId: 'a',
        title: 'A',
        coverUrl: '',
        chapterId: 'c1',
        chapterTitle: '一章',
        chapterIndex: 1,
        chapters: 10,
        offset: 0.5,
      );
      final before = _progressFile(dir).readAsStringSync();

      var notify = 0;
      store.addListener(() => notify++);

      expect(await store.mergeRemoteJson(''), 0);
      expect(await store.mergeRemoteJson('{}'), 0);
      expect(await store.mergeRemoteJson('{not json'), 0);
      expect(notify, 0, reason: '无变化不通知');
      expect(_progressFile(dir).readAsStringSync(), before, reason: '无变化不写盘');
    });

    test('本地文件损坏：远端数据全量补入（与旧直写行为一致）', () async {
      final dir = await Directory.systemTemp.createTemp('merge_read_broken');
      addTearDown(() => dir.delete(recursive: true));
      await _progressFile(dir).writeAsString('{broken');
      final store = ReadingProgressStore(testDirectory: dir);

      final changed = await store.mergeRemoteJson(jsonEncode({
        'a': {'updated_at': '2026-11-08T00:00:00.000Z'},
      }));

      expect(changed, 1);
      expect(store.entry('a'), isNotNull);
    });
  });

  group('BookmarkStore.mergeRemoteJson', () {
    test('按 id 并集：远端新增 + 同 id 较新覆盖', () async {
      final dir = await Directory.systemTemp.createTemp('merge_bm_new');
      addTearDown(() => dir.delete(recursive: true));
      final store = BookmarkStore(testDirectory: dir);
      final local = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charOffset: 10,
        excerpt: '本地版',
      );

      final changed = await store.mergeRemoteJson(jsonEncode({
        'b1': [
          {
            'id': local.id,
            'excerpt': '远端新版',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
          {
            'id': 'bm_extra',
            'excerpt': '远端新增',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
        ],
      }));

      expect(changed, 2);
      final list = store.of('b1');
      expect(list, hasLength(2));
      expect(
        list.firstWhere((m) => m.id == local.id).excerpt,
        '远端新版',
        reason: '同 id 较新 created_at 覆盖内存',
      );
      expect(
        list.firstWhere((m) => m.id == 'bm_extra').excerpt,
        '远端新增',
      );
      final json =
          jsonDecode(_bookmarkFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['b1'] as List), hasLength(2));
    });

    test('同 id 较旧远端保留本地（无变化不写盘）', () async {
      final dir = await Directory.systemTemp.createTemp('merge_bm_old');
      addTearDown(() => dir.delete(recursive: true));
      final store = BookmarkStore(testDirectory: dir);
      final local = await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charOffset: 10,
        excerpt: '本地版',
      );
      final before = _bookmarkFile(dir).readAsStringSync();

      final changed = await store.mergeRemoteJson(jsonEncode({
        'b1': [
          {
            'id': local.id,
            'excerpt': '远端旧版',
            'created_at': '2000-01-01T00:00:00.000Z',
          },
        ],
      }));

      expect(changed, 0);
      expect(store.of('b1').single.excerpt, '本地版');
      expect(_bookmarkFile(dir).readAsStringSync(), before, reason: '无变化不写盘');
    });
  });

  group('MarkingStore.mergeRemoteJson', () {
    test('远端划线补入：内存与文件同步生效', () async {
      final dir = await Directory.systemTemp.createTemp('merge_mk_new');
      addTearDown(() => dir.delete(recursive: true));
      final store = MarkingStore(testDirectory: dir);
      await store.add(
        bookId: 'b1',
        chapterId: 'c1',
        chapterIndex: 0,
        charStart: 0,
        charEnd: 5,
        text: '本地划线',
      );

      final changed = await store.mergeRemoteJson(jsonEncode({
        'b1': [
          {
            'id': 'mk_remote',
            'chapter_id': 'c1',
            'chapter_index': 0,
            'char_start': 10,
            'char_end': 20,
            'text': '远端划线',
            'created_at': '2030-01-01T00:00:00.000Z',
          },
        ],
      }));

      expect(changed, 1);
      expect(store.countOf('b1'), 2);
      expect(
        store.of('b1').firstWhere((m) => m.id == 'mk_remote').text,
        '远端划线',
        reason: '内存即时生效',
      );
      final json =
          jsonDecode(_markingFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['b1'] as List), hasLength(2));
    });
  });
}
