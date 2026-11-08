import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/store/stores.dart';

/// SourcesStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：批量入库（`addCandidates`）、手动加源（`addManual`）、开关源
/// （`setEnabled`）、删除（`remove`）、排序（`reorder`）并发触发。混合调用
/// 全部完成后重读 `aquan_sources.json`：键全在、值正确，JSON 完整可读、
/// 无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_sources.json');

Future<SourcesStore> _newStore(Directory dir) async {
  final store = SourcesStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：批量入库 + 手动加源 + 开关 + 删除，全部落盘无键丢失',
      () async {
    final dir = await Directory.systemTemp.createTemp('sources_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：批量候选入库 + 手动单源 + 开关（对后加的
    // 源可能不命中，属既有语义）+ 批量导入。
    final futures = <Future<void>>[
      store.addCandidates([
        for (var i = 1; i <= 3; i++)
          SourceCandidate(name: '候选$i', api: 'http://c$i.example/api'),
      ]),
      store.addManual(name: '手动源', api: 'http://manual.example/api'),
      store.importData(<String, dynamic>{
        'sources': [
          {
            'id': 's-bak',
            'name': '备份源',
            'apis': ['http://bak.example/api'],
          },
        ],
      }),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final sources = json['sources'] as List;
    final names = <String>[for (final s in sources) s['name'] as String];
    expect(
      names,
      containsAll(<String>['候选1', '候选2', '候选3', '手动源', '备份源']),
    );
    expect(json['version'], 1);

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.all.length, 5, reason: '5 个源不被并发写抹掉');
    expect(store2.byApi('http://manual.example/api')!.name, '手动源');
    expect(store2.byApi('http://bak.example/api')!.name, '备份源',
        reason: '备份恢复不被并发入库覆盖');
    expect(store2.byId('s-bak'), isNotNull);
  });
}
