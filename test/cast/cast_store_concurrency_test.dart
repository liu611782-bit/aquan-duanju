import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_profile.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/store/stores.dart';

/// CastStore 写队列并发回归锁（R3，11-07-cast-reliability）。
///
/// 场景：投屏会话进行中，轮询进度落盘（`_persistLastSession`）与面板侧
/// 混合写（兼容模式 → `_persistRecipes`、画像 → `_persistProfiles`、接收端
/// UDN → `_persistReceiverUdn`、最近使用 → `_flush`）并发触发。混合调用
/// 全部完成后重读 `aquan_cast.json`：lastSession / recipes / profiles /
/// receiverUdn / lastDevice 全部在且值正确，JSON 完整可读、无键丢失。

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '设备-$udn',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

File _castFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

Future<CastStore> _newStore(Directory dir) async {
  final store = CastStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：进度多次 + 配方 + 画像 + 接收端 UDN + 最近使用，'
      '全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('cast_store_conc');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    final t0 = DateTime.now();
    // 先落一条会话记录（与真实时序一致：先投送成功再轮询进度）。
    await store.recordSession(
      target: _target('u1'),
      title: '并发会话',
      mediaUrl: 'http://example.com/1.mp4',
      positionMs: 0,
      now: t0,
    );
    // 同一事件循环内的并发混合写：节流窗外（每次 +11s）的连续进度更新
    // （每次都应真实写入，最终值 = 最后一次）+ 配方 + 画像 + 最近使用 +
    // 接收端 UDN。
    String? udnA;
    String? udnB;
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.updateSessionPosition(
          i * 1000,
          now: t0.add(Duration(seconds: 11 * i)),
        ),
      store.recipes.setTranscodeMode(_target('u2'), CastTranscodeMode.always),
      store.recipes.setTranscodeMode(_target('u3'), CastTranscodeMode.never),
      store.recipes.remember(
        _target('u4'),
        const CastRecipe(didl: DidlVariant.compact),
      ),
      store.profiles.remember(const CastDeviceProfile(
        udn: 'u2',
        friendlyName: '厨房电视',
        modelName: 'TV-100',
      )),
      store.touchLast(_target('u1')),
      store.ensureReceiverUdn().then((v) => udnA = v),
      store.ensureReceiverUdn().then((v) => udnB = v),
    ];
    await Future.wait(futures);
    expect(udnA, isNotNull);
    expect(udnB, udnA, reason: '并发双取接收端 UDN 必须同一个');

    // 全部完成后重读 JSON：完整可读。
    final raw = _castFile(dir).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>[
      'version',
      'lastSession',
      'lastDevice',
      'pinned',
      'recipes',
      'profiles',
      'receiverUdn',
    ]));
    expect(json['receiverUdn'], udnA);

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.lastSession?.positionMs, 5000,
        reason: '最后一次进度更新胜出（节流窗外逐次写入）');
    expect(store2.lastSession?.title, '并发会话');
    expect(store2.lastDevice?.id, 'u1');
    expect(
      store2.recipes.lookup(_target('u2'))?.transcodeMode,
      CastTranscodeMode.always,
    );
    expect(
      store2.recipes.lookup(_target('u3'))?.transcodeMode,
      CastTranscodeMode.never,
    );
    expect(
      store2.recipes.lookup(_target('u4'))?.didl,
      DidlVariant.compact,
    );
    expect(store2.profiles.lookup('u2')?.friendlyName, '厨房电视');
    expect(store2.receiverUdn, udnA);
  });

  test('节流窗口内并发多次进度 + 配方写混合：节流保持首值，配方不丢', () async {
    final dir = await Directory.systemTemp.createTemp('cast_store_conc2');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    final t0 = DateTime.now();
    await store.recordSession(
      target: _target('u1'),
      title: '节流会话',
      mediaUrl: 'http://example.com/1.mp4',
      positionMs: 0,
      now: t0,
    );
    // 节流窗外同一时刻（t0+11s）的并发进度更新：只有第一条真实写入
    //（窗口内的后续更新被节流忽略）。同时并发触发配方写（面板改兼容
    // 模式与轮询进度同刻发生）。
    final updatesAt = t0.add(const Duration(seconds: 11));
    await Future.wait(<Future<void>>[
      for (var i = 1; i <= 5; i++)
        store.updateSessionPosition(i * 1000, now: updatesAt),
      store.recipes.setTranscodeMode(_target('u9'), CastTranscodeMode.always),
      store.ensureReceiverUdn(),
    ]);

    final store2 = await _newStore(dir);
    expect(store2.lastSession?.positionMs, 1000,
        reason: '10s 节流窗口内的后续进度被忽略（首条胜出）');
    expect(store2.lastSession?.title, '节流会话', reason: '进度更新不改标题');
    expect(
      store2.recipes.lookup(_target('u9'))?.transcodeMode,
      CastTranscodeMode.always,
      reason: '并发配方写不丢',
    );
    expect(store2.receiverUdn, isNotNull);
  });

  test('顺序写（既有语义回归）：逐次 await 的最终值与旧版一致', () async {
    final dir = await Directory.systemTemp.createTemp('cast_store_conc3');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    final t0 = DateTime.now();
    await store.recordSession(
      target: _target('u1'),
      title: '顺序会话',
      mediaUrl: 'http://example.com/1.mp4',
      now: t0,
    );
    await store.updateSessionPosition(
        1000, now: t0.add(const Duration(seconds: 11)));
    await store.updateSessionPosition(
        2000, now: t0.add(const Duration(seconds: 22)));
    await store.recipes
        .setTranscodeMode(_target('u1'), CastTranscodeMode.never);
    await store.ensureReceiverUdn();

    final store2 = await _newStore(dir);
    expect(store2.lastSession?.positionMs, 2000);
    expect(
      store2.recipes.lookup(_target('u1'))?.transcodeMode,
      CastTranscodeMode.never,
    );
    expect(store2.receiverUdn, isNotNull);
    // 会话记录与配方互不覆盖（既有回归口径）。
    expect(store2.lastSession?.mediaUrl, 'http://example.com/1.mp4');
  });
}
