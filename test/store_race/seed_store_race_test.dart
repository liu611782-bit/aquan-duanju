import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_seed.dart';
import 'package:aquan_duanju/store/stores.dart';

/// SeedStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：并发加种子（`add`）、禁用（`setEnabled`）、删内置种子（`remove`）、
/// 备份恢复（`importData`）。混合调用全部完成后重读 `aquan_source_seeds.json`：
/// 键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_source_seeds.json');

Future<SeedStore> _newStore(Directory dir) async {
  final store = SeedStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：加种子 + 禁用 + 删内置 + 恢复，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('seed_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：自定义种子 + 禁用内置 + 删内置（记 hidden）
    // + 备份恢复。
    final futures = <Future<void>>[
      for (var i = 1; i <= 3; i++)
        store.add('种子$i', 'http://seed$i.example/config.json', SeedKind.line),
      store.setEnabled('line_01', false),
      store.remove('line_02'),
      store.importData(<String, dynamic>{
        'seeds': [
          {
            'id': 'custom_bak',
            'name': '备份种子',
            'url': 'http://bak.example/config.json',
            'kind': 'line',
          },
        ],
      }),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、三键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final seeds = json['seeds'] as List;
    final urls = <String>[for (final s in seeds) s['url'] as String];
    expect(
      urls,
      containsAll(<String>[
        'http://seed1.example/config.json',
        'http://seed2.example/config.json',
        'http://seed3.example/config.json',
        'http://bak.example/config.json',
      ]),
    );
    expect((json['disabled'] as List), contains('line_01'),
        reason: '禁用不被并发写覆盖');
    expect((json['hidden'] as List), contains('line_02'),
        reason: '内置删除（hidden）不被并发写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.isEnabled('line_01'), isFalse);
    expect(store2.seeds.any((s) => s.id == 'line_02'), isFalse,
        reason: '删除内置不被并发写回');
    expect(store2.seeds.where((s) => s.url.contains('seed')), hasLength(3));
    expect(store2.seeds.any((s) => s.url == 'http://bak.example/config.json'),
        isTrue, reason: '备份恢复不被并发写覆盖');
  });
}
