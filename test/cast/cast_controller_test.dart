import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '测试电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

/// 假 transport：脚本化 poll 结果与故障注入。
class FakeTransport implements CastTransport {
  FakeTransport();

  final List<String> calls = [];
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));
  Object? setUriError;
  Object? stopError;

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url'
        '${duration == null ? '' : ' duration=$duration'}');
    if (setUriError != null) throw setUriError!;
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> stop() async {
    calls.add('stop');
    if (stopError != null) throw stopError!;
  }

  @override
  Future<void> seekTo(Duration position) async => calls.add('seek:$position');
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
  @override
  Future<void> setMute(bool muted) async => calls.add('mute:$muted');

  @override
  Future<CastPoll> poll() async {
    calls.add('poll');
    return pollResult;
  }

  @override
  void close() {}
}

CastMedia _media() =>
    const CastMedia(url: 'http://192.168.1.10/1.m3u8', title: '测试 · 第1集');

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

/// 兼容层假 transport：捕获 CastLoadRequest（M1-2/M1-8 接线断言用）。
class CapturingCompatTransport implements CastTransport, CastCompatTransport {
  CapturingCompatTransport();

  final List<String> calls = <String>[];
  CastLoadRequest? lastRequest;
  Set<String> sinkAnswer = <String>{'http-get:*:video/mp4:*'};

  @override
  Future<Set<String>> preflight() async => sinkAnswer;

  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    lastRequest = request;
    calls.add('load');
    return const CastRecipe(didl: DidlVariant.full);
  }

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url duration=$duration');
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seekTo(Duration position) async {}
  @override
  Future<void> setVolume(int percent) async {}
  @override
  Future<void> setMute(bool muted) async {}
  @override
  Future<CastPoll> poll() async =>
      const CastPoll(transportState: 'PLAYING', position: Duration.zero);
  @override
  void close() {}
}

void main() {
  test('castTo：connecting → casting，先 setUri 后 play', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    final states = <CastSessionState>[];
    controller.addListener(() => states.add(controller.state));

    await controller.castTo(_target('d1'), _media());

    expect(controller.state, CastSessionState.casting);
    expect(controller.isCasting, isTrue);
    expect(transport.calls.first, startsWith('setUri:http://192.168.1.10/1.m3u8'));
    expect(transport.calls, contains('play'));
    expect(states, contains(CastSessionState.connecting));
    controller.dispose();
  });

  test('castTo 失败：状态回 idle 并向上抛出', () async {
    final transport = FakeTransport()..setUriError = SoapException('设备未响应');
    final controller = CastController(transportFactory: (_) => transport);
    await expectLater(
      controller.castTo(_target('d1'), _media()),
      throwsA(isA<SoapException>()),
    );
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('带起始位置：play 后追加 seek', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(
      _target('d1'),
      const CastMedia(
          url: 'http://x/1.m3u8',
          title: 't',
          position: Duration(minutes: 5)),
    );
    expect(transport.calls.where((c) => c.startsWith('seek')), isNotEmpty);
    controller.dispose();
  });

  test('电视端主动停止（poll STOPPED）：onRemoteStopped 触发并回 idle', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<(CastTarget, Duration)>();
    controller.onRemoteStopped = (device, position) =>
        stopped.complete((device, position));

    await controller.castTo(_target('d1'), _media());
    // 1s 轮询：把结果改成 STOPPED。
    transport.pollResult =
        const CastPoll(transportState: 'STOPPED', position: Duration(minutes: 3));

    final (device, position) = await stopped.future.timeout(const Duration(seconds: 3));
    expect(device.id, 'd1');
    expect(position, const Duration(minutes: 3));
    expect(controller.state, CastSessionState.idle);
    expect(controller.currentDevice, isNull);
    controller.dispose();
  });

  test('disconnect：返回最后进度并下发 Stop；Stop 失败回退 Pause', () async {
    final transport = FakeTransport()
      ..pollResult = const CastPoll(
          transportState: 'RUNNING', position: Duration(minutes: 7))
      ..stopError = SoapException('Stop 失败 HTTP 501');
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(_target('d1'), _media());

    final position = await controller.disconnect();
    expect(position, const Duration(minutes: 7));
    expect(transport.calls.contains('stop'), isTrue);
    expect(transport.calls.contains('pause'), isTrue, reason: 'Stop 501 应回退 Pause');
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('暂停/恢复/音量透传到 transport', () async {
    final transport = FakeTransport();
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(_target('d1'), _media());
    await controller.pause();
    await controller.resume();
    await controller.setVolume(40);
    expect(transport.calls.contains('pause'), isTrue);
    expect(transport.calls.contains('play'), isTrue);
    expect(transport.calls.contains('volume:40'), isTrue);
    controller.dispose();
  });

  group('M1 媒体类型与 duration 接线（compat 链）', () {
    test('resolver 接入：.m3u8 → vnd.apple.mpegurl（旧 _mimeForCast 判 mp2t）',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest, isNotNull);
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('AC-13：Sink 只有 video/mp4 时也不覆盖 mime', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('Sink 拼写选择：Sink 用 x-mpegurl → 照抄设备写法', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/x-mpegurl:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.mimeType, 'application/x-mpegurl');
      controller.dispose();
    });

    test('AC-27：真实时长接入 CastLoadRequest 与 DidlRequest', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: '测试 · 第1集',
          duration: Duration(minutes: 2, seconds: 3),
        ),
      );
      expect(compat.lastRequest!.didl.duration, const Duration(minutes: 2, seconds: 3));
      expect(compat.lastRequest!.duration, '0:02:03');
      controller.dispose();
    });

    test('AC-27：时长未知（null）不写 duration', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(_target('d1'), _media());
      expect(compat.lastRequest!.didl.duration, isNull);
      expect(compat.lastRequest!.duration, isNull);
      controller.dispose();
    });

    test('标准路径 setUri 也带格式化时长', () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: 't',
          duration: Duration(hours: 1, minutes: 2, seconds: 3),
        ),
      );
      expect(
        transport.calls.where((c) => c.startsWith('setUri')),
        isNotEmpty,
      );
      expect(
        transport.calls.firstWhere((c) => c.startsWith('setUri')),
        contains('duration=1:02:03'),
      );
      controller.dispose();
    });

    test('mimeHint 作为显式 hint 优先于扩展名判定', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.m3u8',
          title: 't',
          mimeHint: 'application/x-mpegurl',
        ),
      );
      expect(compat.lastRequest!.didl.mimeType, 'application/x-mpegurl');
      controller.dispose();
    });
  });
}
