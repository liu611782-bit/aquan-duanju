import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';
import 'package:aquan_duanju/core/sources/source_probe.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aquan_stores_test');
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  group('SourcesStore', () {
    test('addCandidates 去重入库 / byApi / 开关 / 钉选 / 排序 / 删除', () async {
      final store = SourcesStore(testDirectory: tmp);
      await store.ensureLoaded();

      final added = await store.addCandidates([
        SourceCandidate(name: 'A', api: 'http://a/api/'),
        SourceCandidate(name: 'A2', api: 'http://a/api'),
        const SourceCandidate(
            name: 'S',
            api: 'csp_X',
            kind: SourceKind.spider,
            unsupportedReason: '需要爬虫引擎'),
      ]);
      expect(added, 1);
      expect(store.byApi('http://a/api')?.name, 'A');

      final manual = await store.addManual(name: 'B', api: 'http://b/api');
      expect(store.all.length, 2);

      await store.setEnabled(manual.id, false);
      expect(store.byId(manual.id)?.enabled, isFalse);
      expect(store.enabled.length, 1);

      await store.togglePinned(store.all.first.id);
      expect(store.all.firstWhere((s) => s.name == 'A').pinned, isTrue);

      await store.reorder([manual.id, store.all.first.id]);
      expect(store.all.first.name, 'B');

      await store.remove(manual.id);
      expect(store.all.length, 1);
    });

    test('磁盘持久化往返', () async {
      final store1 = SourcesStore(testDirectory: tmp);
      await store1.addCandidates([SourceCandidate(name: 'A', api: 'http://a/api')]);

      final store2 = SourcesStore(testDirectory: tmp);
      await store2.ensureLoaded();
      expect(store2.all.single.name, 'A');
      expect(store2.all.single.api, 'http://a/api');
    });

    test('importData：备份优先合并，本地独有保留', () async {
      final store = SourcesStore(testDirectory: tmp);
      await store.addCandidates([SourceCandidate(name: '本地', api: 'http://local/api')]);
      final merged = await store.importData({
        'sources': [
          SourceConfig(id: 'remote1', name: '备份', apis: ['http://remote/api'])
              .toJson(),
        ],
      });
      expect(merged, 1);
      expect(store.all.length, 2);
      expect(store.byId('remote1')?.name, '备份');
    });
  });

  group('SourceHealthStore', () {
    test('记录与持久化往返', () async {
      final store1 = SourceHealthStore(testDirectory: tmp);
      await store1.recordSuccess('s1', 640);
      await store1.recordFailure('s2', '超时');

      final store2 = SourceHealthStore(testDirectory: tmp);
      await store2.ensureLoaded();
      expect(store2.recordOf('s1').avgLatencyMs, 640);
      expect(store2.recordOf('s2').isCoolingDown(), isTrue);
      expect(store2.scoreOf('s1'), greaterThan(0));
    });

    test('测速结论按会话记忆：probeOf 可读、未测为 null、不落盘', () async {
      final store = SourceHealthStore(testDirectory: tmp);
      expect(store.probeOf('s1'), isNull);
      store.rememberProbe(
          const ProbeOutcome(sourceId: 's1', state: ProbeState.ok, ttfbMs: 120));
      expect(store.probeOf('s1')?.latencyMs, 120);

      // 会话内记忆不写盘：新实例读不到（重启后回落到健康分排序）。
      final store2 = SourceHealthStore(testDirectory: tmp);
      await store2.ensureLoaded();
      expect(store2.probeOf('s1'), isNull);
    });
  });

  group('MarketSitesStore', () {
    test('首载种子内置 4 站（builtin 可删可恢复）', () async {
      final store1 = MarketSitesStore(testDirectory: tmp);
      await store1.ensureLoaded();
      expect(store1.sites.length, 4);
      expect(store1.sites.every((s) => s.builtin), isTrue);
      expect(
        store1.sites.map((s) => s.url),
        contains('https://zoo.ink/tvbox.html'),
      );

      await store1.removeSite(store1.sites.first.id);
      expect(store1.sites.length, 3);

      final store2 = MarketSitesStore(testDirectory: tmp);
      await store2.ensureLoaded();
      expect(store2.sites.length, 3, reason: '删除要持久化');

      await store2.resetBuiltin();
      expect(store2.sites.length, 4);
    });

    test('addSite 去重 + parses 存取', () async {
      final store = MarketSitesStore(testDirectory: tmp);
      await store.ensureLoaded();
      await store.addSite('自定义', 'https://my.host/tvbox.html');
      await store.addSite('自定义', 'https://my.host/tvbox.html');
      expect(store.sites.length, 5);

      await store.setParses([
        const ParseApi(name: 'Json轮询', url: 'https://p/?url='),
      ]);
      final store2 = MarketSitesStore(testDirectory: tmp);
      await store2.ensureLoaded();
      expect(store2.parses.single.url, 'https://p/?url=');
    });

    test('importData 按 url 去重合并', () async {
      final store = MarketSitesStore(testDirectory: tmp);
      await store.ensureLoaded();
      final merged = await store.importData({
        'sites': [
          MarketSite(id: 'x', name: '已有', url: 'https://zoo.ink/tvbox.html')
              .toJson(),
          MarketSite(id: 'y', name: '新站', url: 'https://new.host/tvbox.html')
              .toJson(),
        ],
      });
      expect(merged, 1);
      expect(store.sites.length, 5);
    });
  });
}
