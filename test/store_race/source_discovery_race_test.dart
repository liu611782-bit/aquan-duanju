import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_discovery.dart';
import 'package:aquan_duanju/store/stores.dart';

/// SourceDiscoveryStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：自动找源批量回写（`upsertAll`）、单条回写（`upsert`）、运行结果
/// （`markRun` / `markMerged`）、移除（`removeUrl`）并发触发。混合调用全部
/// 完成后重读 `aquan_source_discovery.json`：键全在、值正确，JSON 完整可读、
/// 无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_source_discovery.json');

Future<SourceDiscoveryStore> _newStore(Directory dir) async {
  final store = SourceDiscoveryStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：批量回写 + markRun + markMerged，全部落盘无键丢失',
      () async {
    final dir = await Directory.systemTemp.createTemp('source_discovery_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：批量验证记录 + 单条 + 运行元数据 + 合并元数据。
    final futures = <Future<void>>[
      store.upsertAll([
        for (var i = 1; i <= 3; i++)
          DiscoveryEntry(
            name: '配置$i',
            url: 'http://d$i.example/config.json',
            origin: DiscoveryOrigin.manual,
            usable: true,
            siteCount: 10 * i,
            checkedAt: DateTime.now(),
          ),
      ]),
      store.upsert(DiscoveryEntry(
        name: '单条',
        url: 'http://single.example/config.json',
        origin: DiscoveryOrigin.manual,
        usable: false,
        message: '超时',
      )),
      store.markRun(ok: true),
      store.markMerged(42),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final entries = json['entries'] as Map<String, dynamic>;
    expect(entries.length, 4, reason: '4 条验证记录不被并发写抹掉');
    expect(json.containsKey('last_ok_at'), isTrue, reason: '运行元数据不被并发写覆盖');
    expect(json['fail_streak'], 0);
    expect((json['merged'] as Map<String, dynamic>)['sites'], 42,
        reason: '合并元数据不被并发写覆盖');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.all.length, 4);
    expect(store2.entryOf('http://d2.example/config.json')!.usable, isTrue);
    expect(store2.entryOf('http://single.example/config.json')!.message, '超时');
    expect(store2.lastOkAt, isNotNull);
    expect(store2.mergedSiteCount, 42);
  });
}
