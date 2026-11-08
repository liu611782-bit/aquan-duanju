import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/store/stores.dart';

/// LivesStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：换台记录（`setLastWatched`，播放中高频）、批量导入直播源
/// （`addCandidates`）、删除（`remove`）并发触发。混合调用全部完成后重读
/// `aquan_lives.json`：键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_lives.json');

Future<LivesStore> _newStore(Directory dir) async {
  final store = LivesStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：导入 + 换台 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('lives_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落将被并发删除的直播源（与真实时序一致）。
    await store.addManual(name: '待删台', url: 'http://del.example/live.m3u8');

    // 同一事件循环内的并发混合写：批量导入 + 换台记录 + 删除。
    final futures = <Future<void>>[
      store.addCandidates([
        for (var i = 1; i <= 3; i++)
          LiveConfig(name: '直播台$i', url: 'http://l$i.example/live.m3u8'),
      ]),
      store.setLastWatched('l2', '直播台2'),
      store.remove(
        store.all.firstWhere((e) => e.url == 'http://del.example/live.m3u8').id,
      ),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final lives = json['lives'] as List;
    final urls = <String>[for (final e in lives) e['url'] as String];
    expect(
      urls,
      containsAll(<String>[
        'http://l1.example/live.m3u8',
        'http://l2.example/live.m3u8',
        'http://l3.example/live.m3u8',
      ]),
    );
    expect(urls, isNot(contains('http://del.example/live.m3u8')),
        reason: '并发删除不丢（不被旧快照写回）');
    expect(json['last_live_id'], 'l2', reason: '换台记录不被并发导入覆盖');
    expect(json['last_channel'], '直播台2');
    expect(json['version'], 1);

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.all.length, 3);
    expect(store2.lastLiveId, 'l2');
    expect(store2.lastChannelName, '直播台2');
    expect(
      store2.all.where((e) => e.url == 'http://l2.example/live.m3u8'),
      hasLength(1),
    );
  });
}
