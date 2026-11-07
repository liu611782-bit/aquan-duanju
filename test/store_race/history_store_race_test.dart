import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// HistoryStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：播放中高频进度落盘（`record`，每 5s/暂停/退出）与偏好写入
/// （`setPlaybackPrefs`）、历史删除（`remove`）并发触发。混合调用全部完成后
/// 重读 `aquan_history.json`：全部剧集键都在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_history.json');

Future<HistoryStore> _newStore(Directory dir) async {
  final store = HistoryStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：进度多次 + 偏好 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('history_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 先落一条将被并发删除的记录（与真实时序一致）。
    await store.record(
      seriesId: 's-del',
      title: '待删除',
      coverUrl: '',
      episode: 1,
      episodes: 10,
      episodeId: 'e1',
      position: 10,
    );

    // 同一事件循环内的并发混合写：5 部剧的进度写（每次都应真实写入，最终值 =
    // 最后一次）+ 其中两部的偏好写 + 1 部删除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.record(
          seriesId: 's$i',
          title: '剧$i',
          coverUrl: 'cover-$i',
          episode: i,
          episodes: 20,
          episodeId: 'ep$i',
          position: 100.0 + i,
          speed: 1.25,
          quality: '1080P',
        ),
      store.setPlaybackPrefs(seriesId: 's1', speed: 2.0, quality: '4K'),
      store.setPlaybackPrefs(seriesId: 's2', subtitleDelayMs: 350),
      store.remove('s-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['s1', 's2', 's3', 's4', 's5']));
    expect(json.containsKey('s-del'), isFalse, reason: '并发删除不丢（不被旧快照写回）');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.entry('s5')!.title, '剧5');
    expect(store2.entry('s5')!.position, 105.0);
    expect(store2.entry('s1')!.speed, 2.0, reason: '偏好写不被并发进度写覆盖');
    expect(store2.entry('s1')!.quality, '4K');
    expect(store2.entry('s2')!.subtitleDelayMs, 350);
    expect(store2.entry('s2')!.position, 102.0, reason: '进度不被并发偏好写覆盖');
    expect(store2.entry('s-del'), isNull);
    expect(store2.entries.length, 5);
  });

  test('顺序写（既有语义回归）：逐次 await 的最终值与旧版一致', () async {
    final dir = await Directory.systemTemp.createTemp('history_race2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    await store.record(
      seriesId: 's1',
      title: '顺序剧',
      coverUrl: 'c',
      episode: 1,
      episodes: 10,
      episodeId: 'e1',
      position: 10,
      speed: 1.0,
      quality: '720P',
    );
    await store.record(
      seriesId: 's1',
      title: '顺序剧',
      coverUrl: 'c',
      episode: 2,
      episodes: 10,
      episodeId: 'e2',
      position: 20,
      // 不带偏好：保留上一次手动选择的倍速/清晰度。
    );
    await store.setPlaybackPrefs(seriesId: 's1', speed: 1.5);

    final store2 = await _newStore(dir);
    expect(store2.entry('s1')!.episode, 2);
    expect(store2.entry('s1')!.position, 20);
    expect(store2.entry('s1')!.speed, 1.5, reason: '进度回写不带偏好时保留旧值');
    expect(store2.entry('s1')!.quality, '720P');
  });
}
