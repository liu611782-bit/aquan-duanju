import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/sources/auto_source_manager.dart';
import 'package:aquan_duanju/core/sources/merged_source.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_discovery.dart';
import 'package:aquan_duanju/core/sources/source_seed.dart';
import 'package:aquan_duanju/core/sources/source_validator.dart';
import 'package:aquan_duanju/store/stores.dart';

ConfigValidation _result(
  String url, {
  required bool usable,
  int sites = 0,
}) =>
    ConfigValidation(
      url: url,
      usable: usable,
      name: '验证 $url',
      siteCount: sites,
      cmsSiteCount: sites,
      verifiedSites: usable ? 1 : 0,
      latencyMs: 12,
      message: usable ? '' : '抽样站点均无响应',
      checkedAt: DateTime.now(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late SettingsStore settings;
  late SeedStore seeds;
  late SourcesStore sources;
  late SourceDiscoveryStore discovery;
  late MarketSitesStore marketSites;
  late MergedSourceStore merged;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('aquan_auto_source_test');
    SharedPreferences.setMockInitialValues({});
    settings = await SettingsStore.load();
    seeds = SeedStore(testDirectory: tmp);
    sources = SourcesStore(testDirectory: tmp);
    discovery = SourceDiscoveryStore(testDirectory: tmp);
    marketSites = MarketSitesStore(testDirectory: tmp);
    merged = MergedSourceStore(supportDirectory: () async => tmp);
    await seeds.ensureLoaded();
    await sources.ensureLoaded();
    await discovery.ensureLoaded();
    await marketSites.ensureLoaded();
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  AutoSourceManager build({
    required List<DiscoveredConfig> found,
    required Map<String, ConfigValidation> checks,
  }) =>
      AutoSourceManager(
        seeds: seeds,
        sources: sources,
        discovery: discovery,
        marketSites: marketSites,
        settings: settings,
        mergedStore: merged,
        discover: ({CancelToken? cancel, String githubToken = ''}) async =>
            DiscoveryReport(found),
        validate: (url) async => checks[url] ?? _result(url, usable: false),
      );

  test('可用配置写入列表、失效自动项剔除、合并源重建', () async {
    await sources.addCandidates([
      const SourceCandidate(name: 'A', api: 'http://a/api'),
      const SourceCandidate(name: 'B', api: 'http://b/api'),
    ]);
    final dead = await seeds.add('旧失效', 'http://dead/api', SeedKind.line);
    await discovery.upsert(DiscoveryEntry(
      name: '旧失效',
      url: 'http://dead/api',
      origin: DiscoveryOrigin.github,
      auto: true,
      usable: true,
      siteCount: 3,
      checkedAt: DateTime.now(),
    ));

    final manager = build(
      found: [
        const DiscoveredConfig(
            name: '新可用', url: 'http://new/api', origin: DiscoveryOrigin.github),
        const DiscoveredConfig(
            name: '旧失效', url: 'http://dead/api', origin: DiscoveryOrigin.github),
      ],
      checks: {
        'http://new/api': _result('http://new/api', usable: true, sites: 4),
        'http://dead/api': _result('http://dead/api', usable: false),
      },
    );
    await manager.runNow();

    expect(seeds.seeds.any((s) => s.url == 'http://new/api'), isTrue);
    expect(seeds.seeds.any((s) => s.id == dead.id), isFalse);
    expect(discovery.entryOf('http://new/api')?.usable, isTrue);
    expect(discovery.entryOf('http://dead/api')?.usable, isFalse);
    expect(manager.usableCount, 1);

    final info = await merged.info();
    expect(info, isNotNull);
    expect(info!.siteCount, 2);
    expect(discovery.mergedSiteCount, 2);
    manager.dispose();
  });

  test('一轮全失败时不动任何配置', () async {
    final keep = await seeds.add('手动', 'http://keep/api', SeedKind.line);
    final manager = build(
      found: [
        const DiscoveredConfig(
            name: '死了', url: 'http://dead/api', origin: DiscoveryOrigin.github),
      ],
      checks: {
        'http://dead/api': _result('http://dead/api', usable: false),
      },
    );
    await manager.runNow();

    expect(seeds.seeds.any((s) => s.id == keep.id), isTrue);
    expect(discovery.entryOf('http://dead/api'), isNull);
    expect(await merged.info(), isNull);
    expect(discovery.lastError, isNotEmpty);
    manager.dispose();
  });

  test('手动配置永远不会被自动剔除', () async {
    final manual = await seeds.add('手动', 'http://manual/api', SeedKind.line);
    await discovery.upsert(DiscoveryEntry(
      name: '手动',
      url: 'http://manual/api',
      origin: DiscoveryOrigin.manual,
      auto: false,
      usable: true,
      checkedAt: DateTime.now(),
    ));
    // 同时有一条可用结果，保证本轮不是「全灭」。
    final manager = build(
      found: [
        const DiscoveredConfig(
            name: '可用', url: 'http://ok/api', origin: DiscoveryOrigin.gitee),
        const DiscoveredConfig(
            name: '手动', url: 'http://manual/api', origin: DiscoveryOrigin.manual),
      ],
      checks: {
        'http://ok/api': _result('http://ok/api', usable: true, sites: 1),
        'http://manual/api': _result('http://manual/api', usable: false),
      },
    );
    await manager.runNow();

    expect(seeds.seeds.any((s) => s.id == manual.id), isTrue);
    manager.dispose();
  });
}
