import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// FollowStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：详情页批量关注（`follow`）、追剧状态切换（`setStateOf`）、取消追剧
/// （`toggle`）同刻并发触发。混合调用全部完成后重读 `aquan_follows.json`：
/// 全部剧集键都在、状态正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_follows.json');

Future<FollowStore> _newStore(Directory dir) async {
  final store = FollowStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：关注多次 + 状态切换 + 取消追剧，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('follow_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先追一部将被并发取消的剧。
    await store.follow(
      seriesId: 's-del',
      title: '待取消',
      coverUrl: '',
      episodeCount: 8,
    );

    // 同一事件循环内的并发混合写：4 部新关注 + 其中两部的状态切换 + 1 部取消。
    final futures = <Future<void>>[
      for (var i = 1; i <= 4; i++)
        store.follow(
          seriesId: 's$i',
          title: '剧$i',
          coverUrl: 'cover-$i',
          episodeCount: 10 + i,
        ),
      store.setStateOf(seriesId: 's1', state: FollowState.want),
      store.setStateOf(seriesId: 's2', state: FollowState.watched),
      store.toggle(seriesId: 's-del', title: '', coverUrl: '', episodeCount: 0),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['s1', 's2', 's3', 's4']));
    expect(json.containsKey('s-del'), isFalse, reason: '并发取消不被旧快照写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.get('s1')!.state, FollowState.want);
    expect(store2.get('s1')!.title, '剧1', reason: '状态切换不丢标题');
    expect(store2.get('s2')!.state, FollowState.watched);
    expect(store2.get('s3')!.state, FollowState.watching, reason: '默认在看');
    expect(store2.get('s4')!.episodeCount, 14);
    expect(store2.get('s-del'), isNull);
    expect(store2.entries.length, 4);
  });

  test('条件跳过语义回归：状态相同不写盘', () async {
    final dir = await Directory.systemTemp.createTemp('follow_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    await store.follow(
      seriesId: 's1',
      title: '剧1',
      coverUrl: '',
      episodeCount: 3,
    );
    final before = _file(dir).readAsStringSync();
    expect(
      await store.setStateOf(seriesId: 's1', state: FollowState.watching),
      isTrue,
    );
    // 状态相同：不写盘（文件字节不变）。
    expect(_file(dir).readAsStringSync(), before);
  });
}
