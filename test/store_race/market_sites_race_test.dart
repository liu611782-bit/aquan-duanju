import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';
import 'package:aquan_duanju/store/stores.dart';

/// MarketSitesStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：加/删索引站（`addSite` / `removeSite`）、开关（`setSiteEnabled`）、
/// 解析接口写入（`setParses` / `addParses`）并发触发。混合调用全部完成后
/// 重读 `aquan_source_market.json`：键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_source_market.json');

Future<MarketSitesStore> _newStore(Directory dir) async {
  final store = MarketSitesStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：加站 + 删站 + 解析接口，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('market_sites_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落将被并发删除的站（与真实时序一致）。
    await store.addSite('待删站', 'http://del.example/index.json');

    // 同一事件循环内的并发混合写：加站 + 删站 + 解析接口写入。
    final futures = <Future<void>>[
      for (var i = 1; i <= 3; i++)
        store.addSite('索引站$i', 'http://m$i.example/index.json'),
      store.removeSite(
        store.sites.firstWhere((s) => s.url == 'http://del.example/index.json').id,
      ),
      store.setParses([
        const ParseApi(name: '解析1', url: 'http://jx1.example/?url='),
        const ParseApi(name: '解析2', url: 'http://jx2.example/?url='),
      ]),
      store.addParses([
        const ParseApi(name: '解析追加', url: 'http://jx3.example/?url='),
      ]),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final sites = json['sites'] as List;
    final urls = <String>[for (final s in sites) s['url'] as String];
    expect(
      urls,
      containsAll(<String>[
        'http://m1.example/index.json',
        'http://m2.example/index.json',
        'http://m3.example/index.json',
      ]),
    );
    expect(urls, isNot(contains('http://del.example/index.json')),
        reason: '并发删除不丢（不被旧快照写回）');
    final parses = json['parses'] as List;
    expect(parses.length, 3, reason: 'setParses 与 addParses 并发不互相覆盖');
    expect(
      <String>[for (final p in parses) p['url'] as String],
      containsAll(<String>['http://jx1.example/?url=', 'http://jx3.example/?url=']),
    );
    expect(json['version'], 1);

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    // 4 条内置索引站（首启种子）+ 3 条新增 = 7（待删站已删）。
    expect(store2.sites.length, builtinMarketSites.length + 3);
    expect(store2.sites.every((s) => s.url != 'http://del.example/index.json'),
        isTrue);
    expect(store2.parses.length, 3);
    expect(store2.parses.any((p) => p.name == '解析追加'), isTrue);
  });
}
