import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/models/play_skip.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// PlaySkipStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：播放中设置/覆盖片头片尾（`upsert`）与移除（`remove`）同刻并发触发。
/// 混合调用全部完成后重读 `aquan_play_skip.json`：version + items 结构完整、
/// 全部剧集键都在、值正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_play_skip.json');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('play_skip_race');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  test('Future.wait 混合写：多次设置 + 同键覆盖 + 移除，全部落盘无键丢失', () async {
    final store = PlaySkipStore();
    await store.ensureLoaded();

    // 先落一条将被并发移除的记录。
    await store.upsert(
      's-del',
      const PlaySkipEntry(openingMs: 1000, endingMs: 2000),
    );

    // 同一事件循环内的并发混合写：4 部新设置 + 同一剧 3 次覆盖（最终值 =
    // 最后一次）+ 1 部移除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 4; i++)
        store.upsert(
          's$i',
          PlaySkipEntry(openingMs: 10000 + i, endingMs: 60000 + i),
        ),
      for (var i = 1; i <= 3; i++)
        store.upsert('s-dup', PlaySkipEntry(openingMs: i * 100)),
      store.remove('s-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、结构完整。
    final json =
        jsonDecode(_file(support).readAsStringSync()) as Map<String, dynamic>;
    expect(json['version'], 1);
    final items = json['items'] as Map<String, dynamic>;
    expect(items.keys, containsAll(<String>['s1', 's2', 's3', 's4', 's-dup']));
    expect(items.containsKey('s-del'), isFalse, reason: '并发移除不被旧快照写回');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = PlaySkipStore();
    await store2.ensureLoaded();
    expect(store2.entryFor('s1')!.openingMs, 10001);
    expect(store2.entryFor('s4')!.endingMs, 60004);
    expect(store2.entryFor('s-dup')!.openingMs, 300, reason: '最后一次覆盖胜出');
    expect(store2.entryFor('s-del'), isNull);
  });

  test('顺序写（既有语义回归）：逐次 await 的最终值与旧版一致', () async {
    final store = PlaySkipStore();
    await store.ensureLoaded();

    await store.upsert(
      's1',
      const PlaySkipEntry(openingMs: 30000, endingMs: 60000),
    );
    await store.upsert('s1', const PlaySkipEntry(openingMs: 15000));
    await store.remove('s2');

    final store2 = PlaySkipStore();
    await store2.ensureLoaded();
    expect(store2.entryFor('s1')!.openingMs, 15000);
    expect(store2.entryFor('s1')!.endingMs, 0, reason: '覆盖后旧值清零');
  });
}
