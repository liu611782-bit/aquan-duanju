import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// DetailSnapshotStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：详情页秒开缓存写入（`put`，多个详情页/目录并发打开）与移除
/// （`remove`）同刻并发触发。混合调用全部完成后重读 `aquan_detail_snapshot.json`：
/// 全部快照键都在、数据可读回、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_detail_snapshot.json');

Future<DetailSnapshotStore> _newStore(Directory dir) async {
  final store = DetailSnapshotStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

Map<String, dynamic> _snapshot(String id) => <String, dynamic>{
  'id': id,
  'title': '书$id',
  'chapters': <Map<String, dynamic>>[
    {'title': '第1章', 'url': 'http://x/$id/1'},
    {'title': '第2章', 'url': 'http://x/$id/2'},
  ],
};

void main() {
  test('Future.wait 混合写：多键 put + 同键覆盖 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('detail_snapshot_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发移除的快照。
    await store.put('aqua:detail:del', _snapshot('del'));

    // 同一事件循环内的并发混合写：6 个新快照 + 同一键 2 次覆盖（最终值 =
    // 最后一次）+ 1 个移除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 6; i++)
        store.put('aqua:detail:b$i', _snapshot('b$i')),
      for (var i = 1; i <= 2; i++)
        store.put('aqua:dir:dup', <String, dynamic>{
          'v': i,
          'nested': _snapshot('d$i'),
        }),
      store.remove('aqua:detail:del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>[
        'aqua:detail:b1',
        'aqua:detail:b2',
        'aqua:detail:b3',
        'aqua:detail:b4',
        'aqua:detail:b5',
        'aqua:detail:b6',
        'aqua:dir:dup',
      ]),
    );
    expect(json.containsKey('aqua:detail:del'), isFalse, reason: '并发移除不被旧快照写回');

    // 新实例（模拟重启）读回：全部键值正确（含嵌套 Map 不丢字段）。
    final store2 = await _newStore(dir);
    expect(store2.get('aqua:detail:b1')!['title'], '书b1');
    expect(store2.get('aqua:dir:dup')!['v'], 2, reason: '最后一次覆盖胜出');
    expect((store2.get('aqua:dir:dup')!['nested'] as Map)['title'], '书d2');
    expect(store2.get('aqua:detail:del'), isNull);
    expect(store2.savedAtOf('aqua:detail:b1'), isNotNull);
  });

  test('条件跳过语义回归：删除不存在的键不写盘', () async {
    final dir = await Directory.systemTemp.createTemp('detail_snapshot_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    await store.put('aqua:detail:b1', _snapshot('b1'));
    final before = _file(dir).readAsStringSync();
    await store.remove('aqua:detail:none');
    expect(_file(dir).readAsStringSync(), before, reason: '无变化不写盘');
  });
}
