import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/playback_health.dart';
import 'package:aquan_duanju/store/stores.dart';

/// PlaybackHealthStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：播放健康事件高频记录（`record`）与备份恢复（`importData`）并发触发。
/// 混合调用全部完成后重读 `aquan_playback_health.json`：键全在、值正确，
/// JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_playback_health.json');

Future<PlaybackHealthStore> _newStore(Directory dir) async {
  final store = PlaybackHealthStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：多次 record + importData，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('playback_health_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：5 条线路的健康记录 + 1 条备份恢复。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.record('src$i', PlaybackHealthEvent.success),
      store.record('src3', PlaybackHealthEvent.failed),
      store.importData(<String, dynamic>{
        'src-bak': <String, dynamic>{'ok': 3, 'fail': 1},
      }),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(
      json.keys,
      containsAll(<String>['src1', 'src2', 'src3', 'src4', 'src5', 'src-bak']),
    );

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.health.records['src1']!.successes, 1);
    expect(store2.health.records['src3']!.successes, 1,
        reason: '并发 record 同键不互相覆盖');
    expect(store2.health.records['src3']!.failures, 1);
    expect(store2.health.records['src-bak']!.successes, 0,
        reason: 'importData 按 fail>0 映射为单次失败事件（既有语义）');
    expect(store2.health.records['src-bak']!.failures, 1,
        reason: '备份恢复不被并发 record 覆盖');
    expect(store2.health.records.length, 6);
  });
}
