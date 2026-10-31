import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/models/book.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('detail_snapshot_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  DetailSnapshotStore newStore() => DetailSnapshotStore(testDirectory: tmp);

  group('DetailSnapshotStore 读写与持久化', () {
    test('put/get 往返 + savedAt', () async {
      final store = newStore();
      await store.put('aqua:detail:b1', {'id': 'b1', 'title': '测试书'});
      expect(store.get('aqua:detail:b1'), {'id': 'b1', 'title': '测试书'});
      expect(store.savedAtOf('aqua:detail:b1'), isNotNull);
      expect(store.get('missing'), isNull);
    });

    test('跨实例持久化（模拟二次进入详情页命中快照）', () async {
      final first = newStore();
      await first.put('src:cms1:101',
          {'title': '剧名', 'source_item_id': '101', 'lines': []});
      // 模拟进程重启：全新实例从磁盘加载。
      final second = newStore();
      await second.ensureLoaded();
      expect(second.get('src:cms1:101'), isNotNull);
      expect(second.get('src:cms1:101')!['title'], '剧名');
    });

    test('remove 与 clear', () async {
      final store = newStore();
      await store.put('k1', {'v': 1});
      await store.put('k2', {'v': 2});
      await store.remove('k1');
      expect(store.get('k1'), isNull);
      expect(store.get('k2'), isNotNull);
      await store.clear();
      expect(store.length, 0);
    });

    test('条数上限：最旧先淘汰', () async {
      final store = newStore()..limit = 2;
      await store.put('k1', {'n': 1});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.put('k2', {'n': 2});
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await store.put('k3', {'n': 3});
      expect(store.length, 2);
      expect(store.get('k1'), isNull, reason: '最旧的 k1 应被淘汰');
      expect(store.get('k2'), isNotNull);
      expect(store.get('k3'), isNotNull);
    });

    test('字节上限：大条目触发淘汰且至少保留一条', () async {
      final store = newStore()..maxBytes = 1024;
      await store.put('big', {'blob': 'x' * 4096});
      await store.put('small', {'blob': 'y'});
      // big 超限但被保留（至少一条），small 挤不掉 big（仍超限）——
      // 语义：放不下的不再保留，但绝不空掉。
      expect(store.get('big'), isNotNull);
      expect(store.length, greaterThanOrEqualTo(1));
    });

    test('损坏文件容错：加载为空且可继续写入', () async {
      final f = File('${tmp.path}${Platform.pathSeparator}aquan_detail_snapshot.json');
      await f.writeAsString('{not valid json');
      final store = newStore();
      await store.ensureLoaded();
      expect(store.length, 0);
      await store.put('k', {'ok': true});
      expect(store.get('k'), isNotNull);
    });
  });

  group('详情模型序列化往返', () {
    test('BookDetail / BookDirectory / BookChapter toJson→fromJson', () {
      const detail = BookDetail(
        id: 'b1',
        title: '书',
        author: '作者',
        abstractText: '简介',
        coverUrl: 'http://c/1.jpg',
        wordCount: 12345,
        chapterCount: 930,
        lastChapterTitle: '第九百三十章',
        category: '都市',
        score: '8.5',
        readCount: 7,
        finished: true,
      );
      final back = BookDetail.fromJson(detail.toJson());
      expect(back.id, 'b1');
      expect(back.abstractText, '简介');
      expect(back.chapterCount, 930);
      expect(back.finished, isTrue);

      const directory = BookDirectory(total: 2, chapters: [
        BookChapter(id: 'c1', title: '第一章', volume: '第一卷', index: 0),
        BookChapter(id: 'c2', title: '第二章', index: 1),
      ]);
      final dirBack = BookDirectory.fromJson(directory.toJson());
      expect(dirBack.total, 2);
      expect(dirBack.chapters.length, 2);
      expect(dirBack.chapters[0].volume, '第一卷');
      expect(dirBack.chapters[1].id, 'c2');
    });

    test('UnifiedSeries toJson→tryFromJson 往返（含线路与请求头）', () {
      const series = UnifiedSeries(
        sourceKey: 'cms1',
        sourceItemId: '101',
        title: '剧名',
        normalizedTitle: '剧名',
        year: '2026',
        coverUrl: 'http://c/1.jpg',
        remarks: '更新至第 10 集',
        description: '简介',
        lines: [
          PlayLine(name: '线路一', episodes: [
            UnifiedEpisode(title: '第01集', url: 'http://v/1.m3u8', index: 0),
            UnifiedEpisode(title: '第02集', url: 'http://v/2.m3u8', index: 1),
          ]),
          PlayLine(name: '线路二', episodes: []),
        ],
        headers: {'Referer': 'http://s/', 'User-Agent': 'UA'},
      );
      final back = UnifiedSeries.tryFromJson(jsonDecode(jsonEncode(series.toJson())));
      expect(back, isNotNull);
      expect(back!.sourceKey, 'cms1');
      expect(back.sourceItemId, '101');
      expect(back.lines.length, 2);
      expect(back.lines[0].episodes.length, 2);
      expect(back.lines[0].episodes[1].url, 'http://v/2.m3u8');
      expect(back.headers['Referer'], 'http://s/');
      expect(back.historyKey, 'cms1:101');
    });

    test('UnifiedSeries.tryFromJson 容错：缺关键字段返回 null', () {
      expect(UnifiedSeries.tryFromJson({'title': '无 id'}), isNull);
      expect(UnifiedSeries.tryFromJson('not a map'), isNull);
      expect(UnifiedSeries.tryFromJson(null), isNull);
      // 缺 lines/headers 等可选字段仍可解析。
      final s = UnifiedSeries.tryFromJson({'title': 't', 'source_item_id': 'x'});
      expect(s, isNotNull);
      expect(s!.lines, isEmpty);
    });
  });
}
