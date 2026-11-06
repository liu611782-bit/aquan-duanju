import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/mirror/mirror_controller.dart';

const _castChannel = MethodChannel('aquan/cast');

DlnaDevice _dlna(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
      location: 'http://192.168.1.9/desc.xml',
    );

class FakeTransport implements CastTransport {
  final calls = <String>[];

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url');
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(int percent) async {}
  @override
  Future<void> setMute(bool muted) async {}
  @override
  Future<CastPoll> poll() async =>
      const CastPoll(transportState: 'PLAYING', position: Duration(seconds: 1));
  @override
  void close() {}
}

/// 从测试侧向 Dart 发一条 Kotlin→Dart 通道事件（镜像服务回执）。
Future<void> pushEvent(MethodCall call) async {
  final codec = _castChannel.codec;
  final encoded = codec.encodeMethodCall(call);
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    _castChannel.name,
    encoded,
    (_) {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // 测试跑在宿主平台（Windows）：显式注入 Android 分支；单例跨用例存活，
    // 每个用例重置状态与启动超时预算，避免互相污染。
    MirrorController.instance
      ..debugAndroidMode = true
      ..debugStartTimeout = const Duration(seconds: 15)
      ..debugState = MirrorState.idle;
    // 每个用例重挂 mock：记录调用 + 可编程回执。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castChannel, (call) async {
      switch (call.method) {
        case 'requestMirrorPermission':
          return <String, dynamic>{'granted': true};
        case 'startMirror':
          // 模拟原生异步：稍后回 mirrorStarted 事件。
          unawaited(Future<void>.delayed(const Duration(milliseconds: 20)).then(
            (_) => pushEvent(const MethodCall('mirrorStarted', {
              'url': 'http://192.168.1.5:18380/stream.ts',
              'audio': true,
            })),
          ));
          return true;
        case 'stopMirror':
          unawaited(Future<void>.delayed(const Duration(milliseconds: 10)).then(
            (_) => pushEvent(const MethodCall('mirrorStopped', {'reason': 'stopped'})),
          ));
          return true;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castChannel, null);
  });

  test('镜像流程：授权 → start → 收 mirrorStarted 事件拿 URL → mirroring', () async {
    final mirror = MirrorController.instance;
    expect(await mirror.requestPermission(), isTrue);
    final url = await mirror.start();
    expect(url, 'http://192.168.1.5:18380/stream.ts');
    expect(mirror.state, MirrorState.mirroring);
    expect(mirror.hasAudio, isTrue);
  });

  test('授权被拒：requestPermission 返回 false 并记录原因', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castChannel, (call) async {
      if (call.method == 'requestMirrorPermission') {
        return <String, dynamic>{'granted': false, 'reason': 'denied'};
      }
      return null;
    });
    final mirror = MirrorController.instance;
    expect(await mirror.requestPermission(), isFalse);
    expect(mirror.lastError, '未授权屏幕录制');
  });

  test('mirrorStopped 事件：状态回 idle、URL 清空', () async {
    final mirror = MirrorController.instance;
    await mirror.requestPermission();
    await mirror.start();
    expect(mirror.isMirroring, isTrue);
    await pushEvent(const MethodCall('mirrorStopped', {'reason': 'error'}));
    expect(mirror.state, MirrorState.idle);
    expect(mirror.url, isNull);
  });

  test('镜像会话断开：CastController 自动下发 stopMirror', () async {
    final received = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castChannel, (call) async {
      received.add(call.method);
      return true;
    });
    final mirror = MirrorController.instance;
    mirror.debugState = MirrorState.mirroring;

    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(
      CastTarget.dlna(_dlna('d1')),
      const CastMedia(
          url: 'http://192.168.1.5:18380/stream.ts',
          title: '屏幕镜像',
          isMirror: true),
    );
    expect(transport.calls.first, startsWith('setUri:http://192.168.1.5:18380'));
    await controller.disconnect();
    expect(received, contains('stopMirror'),
        reason: '镜像会话结束必须停掉采集服务');
    controller.dispose();
  });

  test('启动超时后晚到事件不二次 complete（15s 超时护栏）', () async {
    final mirror = MirrorController.instance;
    // 缩短启动预算，让「超时 → 晚到事件」这条路径可以在单测里跑完。
    mirror.debugStartTimeout = const Duration(milliseconds: 40);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_castChannel, (call) async {
      if (call.method == 'startMirror') {
        // 服务在超时之后才回 mirrorStopped（晚到事件）。
        unawaited(Future<void>.delayed(const Duration(milliseconds: 90)).then(
          (_) => pushEvent(const MethodCall('mirrorStopped', {'reason': 'error'})),
        ));
        return true;
      }
      return null;
    });

    final url = await mirror.start();
    expect(url, isNull, reason: '超时必须优雅返回 null，而不是挂起或崩溃');
    expect(mirror.state, MirrorState.idle);
    expect(mirror.lastError, isNotNull);

    // 晚到 / 重复的 mirrorStopped 与 mirrorStarted 都不得二次 complete 或抛异常。
    await pushEvent(const MethodCall('mirrorStopped', {'reason': 'late-stop'}));
    await pushEvent(const MethodCall('mirrorStarted', {
      'url': 'http://192.168.1.5:18380/stream.ts',
      'audio': false,
    }));
    expect(mirror.state, MirrorState.idle,
        reason: '超时后迟到的启动回执不复活状态机');
    expect(mirror.url, isNull);

    // 排空模拟的延迟事件，避免溢出到下一个用例。
    await Future<void>.delayed(const Duration(milliseconds: 120));
  });
}
