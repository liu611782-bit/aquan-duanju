import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// VeneraStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：书源 save_data 写入（`setValue`，整库覆写型）与移除（`remove`）同刻
/// 并发触发。混合调用全部完成后重读 `aquan_venera.json`：全部 KV 键都在、
/// 值类型与内容正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_venera.json');

Future<VeneraStore> _newStore(Directory dir) async {
  final store = VeneraStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：多键 setValue + 同键覆盖 + 移除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('venera_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发移除的键。
    await store.setValue('data/src/del', '待删除');

    // 同一事件循环内的并发混合写：6 个新键（值类型混合：字符串/对象/整数/布尔/
    // 列表）+ 同一键 3 次覆盖（最终值 = 最后一次）+ 1 个移除。
    final futures = <Future<void>>[
      store.setValue('data/src1/explore', <String, dynamic>{
        'title': '推荐',
        'items': <String>['a', 'b'],
      }),
      store.setValue('data/src2/last_read', 'c1'),
      store.setValue('setting/src1/contrast', 0.75),
      store.setValue('setting/src2/enable', true),
      store.setValue('data/src3/tags', <String>['x', 'y', 'z']),
      store.setValue('setting/src3/order', 3),
      for (var i = 1; i <= 3; i++) store.setValue('data/dup/k', 'v$i'),
      store.remove('data/src/del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在、值类型正确。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>[
        'data/src1/explore',
        'data/src2/last_read',
        'setting/src1/contrast',
        'setting/src2/enable',
        'data/src3/tags',
        'setting/src3/order',
        'data/dup/k',
      ]),
    );
    expect(json.containsKey('data/src/del'), isFalse, reason: '并发移除不被旧快照写回');
    expect(json['data/src1/explore'], isA<Map<String, dynamic>>());
    expect(json['setting/src2/enable'], isTrue);
    expect(json['setting/src3/order'], 3);
    expect(json['data/dup/k'], 'v3', reason: '最后一次覆盖胜出');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.value('data/src2/last_read'), 'c1');
    expect((store2.value('data/src1/explore') as Map)['title'], '推荐');
    expect(store2.value('data/src3/tags'), <String>['x', 'y', 'z']);
    expect(store2.has('data/src/del'), isFalse);
  });

  test('顺序写与条件跳过回归：逐次 await 的最终值与旧版一致', () async {
    final dir = await Directory.systemTemp.createTemp('venera_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    await store.setValue('k1', 'v1');
    await store.setValue('k1', 'v2');
    await store.setValue('k2', <String, dynamic>{'a': 1});

    final before = _file(dir).readAsStringSync();
    await store.remove('k-none');
    expect(_file(dir).readAsStringSync(), before, reason: '无变化不写盘');

    final store2 = await _newStore(dir);
    expect(store2.value('k1'), 'v2');
    expect(store2.value('k2'), <String, dynamic>{'a': 1});
  });
}
