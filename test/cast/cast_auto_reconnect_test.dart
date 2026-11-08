import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

CastMedia _media() =>
    const CastMedia(url: 'http://192.168.1.10/1.m3u8', title: '测试 · 第1集');

/// 假 transport：脚本化 poll 失败与故障注入（与 cast_controller_test 同款）。
class FakeTransport implements CastTransport {
  FakeTransport();

  final List<String> calls = [];
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));

  /// true = poll 抛异常（模拟失联；forceRefresh 直驱 _pollOnce 计数）。
  bool failPoll = false;
  Object? setUriError;

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url');
    if (setUriError != null) throw setUriError!;
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seek:$position');

  @override
  Future<void> setVolume(int percent) async {}
  @override
  Future<void> setMute(bool muted) async {}

  @override
  Future<CastPoll> poll() async {
    calls.add('poll');
    if (failPoll) throw const SocketException('模拟失联');
    return pollResult;
  }

  @override
  void close() => calls.add('close');
}

/// 内存版会话恢复记录器（与 cast_session_resume_test 同款）。
class _MemoryRecorder implements CastSessionRecorder {
  @override
  CastSessionRecord? lastSession;
  final List<String> calls = [];

  @override
  Future<void> recordSession({
    required CastTarget target,
    required String title,
    required String mediaUrl,
    int positionMs = 0,
    String sourceId = '',
    int episodeIndex = 1,
  }) async {
    calls.add('record:$mediaUrl|$positionMs');
    lastSession = CastSessionRecord(
      targetPersistJson: target.toPersistJson(),
      title: title,
      mediaUrl: mediaUrl,
      positionMs: positionMs,
      sourceId: sourceId,
      episodeIndex: episodeIndex,
      endedAt: DateTime.now(),
    );
  }

  @override
  Future<void> updateSessionPosition(int positionMs) async {
    calls.add('position:$positionMs');
    final r = lastSession;
    if (r == null) return;
    lastSession = CastSessionRecord(
      targetPersistJson: r.targetPersistJson,
      title: r.title,
      mediaUrl: r.mediaUrl,
      positionMs: positionMs,
      sourceId: r.sourceId,
      episodeIndex: r.episodeIndex,
      endedAt: r.endedAt,
    );
  }

  @override
  Future<void> markSessionEnded() async => calls.add('ended');

  @override
  Future<void> clearLastSession() async {
    calls.add('clear');
    lastSession = null;
  }
}

/// 直驱 _pollOnce 制造 N 次连续轮询失败（不等真实 1s 轮询定时器）。
Future<void> _failPolls(CastController controller, int times) async {
  for (var i = 0; i < times; i++) {
    await controller.forceRefresh();
  }
}

/// 等待条件成立（deadline 轮询；恢复链路是 unawaited 异步流程）。
Future<void> _waitUntil(bool Function() cond,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('等待超时：条件未在 $timeout 内成立');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('AC-1 触发与门控', () {
    test('连续失败 ≥5 → 复检成功 → 重投 setUri→play→seek 最后位置；'
        '本会话内恰一次，续批走既有 onSessionLost', () async {
      final transport = FakeTransport();
      var factoryCalls = 0;
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) {
          factoryCalls++;
          return transport;
        },
        sessionRecorder: recorder,
      );
      final probes = <CastTarget>[];
      controller.reachabilityProbe = (device) async {
        probes.add(device);
        return true;
      };
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;

      await controller.castTo(_target('d1'), _media());
      // 一次成功轮询：记录更新为「最后位置」77s（lastSession 会话中持续更新）。
      transport.pollResult = const CastPoll(
          transportState: 'RUNNING', position: Duration(seconds: 77));
      await controller.forceRefresh();
      expect(recorder.lastSession?.positionMs, 77000);

      // 连续 5 次轮询失败 → 触发一次恢复。
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => toasts == 1);

      // 恰一次：探针/重投各一次；恢复链路与 resumeLastSession 同款
      // （重建 target → 标准序列 setUri → play → seek 记录位置）。
      expect(probes, hasLength(1));
      expect(probes.single.id, 'd1');
      expect(factoryCalls, 2, reason: '首投 + 恢复重投各一次 transport');
      expect(controller.state, CastSessionState.casting);
      expect(controller.currentDevice?.id, 'd1');
      final firstSetUri =
          transport.calls.indexWhere((c) => c.startsWith('setUri'));
      final secondSetUri =
          transport.calls.indexWhere((c) => c.startsWith('setUri'), firstSetUri + 1);
      expect(secondSetUri, greaterThan(firstSetUri));
      final playIdx = transport.calls.indexOf('play', secondSetUri);
      final seekIdx =
          transport.calls.indexOf('seek:0:01:17.000000', secondSetUri);
      expect(seekIdx, greaterThan(playIdx), reason: '标准序列：setUri → play → seek');
      expect(playIdx, greaterThan(secondSetUri));
      expect(
        CastDiagnostics.instance.timeline
            .any((l) => l.contains('中断自动恢复')),
        isTrue,
        reason: '恢复成功记时间线「中断自动恢复」',
      );

      // 本会话内再次失联：不再触发（一次性 flag），走既有 onSessionLost。
      await _failPolls(controller, 5);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(probes, hasLength(1), reason: '恢复尝试后无论成败不再触发（R1）');
      expect(factoryCalls, 2);
      expect(toasts, 1);
      expect(lostCalls, 1, reason: '续批失联维持既有 onSessionLost 行为');
      controller.dispose();
    });

    test('复检失败（不可达注入）→ 静默走电视端停止：不重投、'
        'onRemoteStopped 携最后位置、记录保留、不 toast', () async {
      final transport = FakeTransport();
      var factoryCalls = 0;
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) {
          factoryCalls++;
          return transport;
        },
        sessionRecorder: recorder,
      );
      var probeCalls = 0;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return false;
      };
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;
      final stopped = Completer<(CastTarget, Duration)>();
      controller.onRemoteStopped = (device, position) {
        if (!stopped.isCompleted) stopped.complete((device, position));
      };

      await controller.castTo(_target('d1'), _media());
      // 一次成功轮询拿到最后位置 30s，随后失联。
      await controller.forceRefresh();
      transport.failPoll = true;
      await _failPolls(controller, 5);

      final (device, position) =
          await stopped.future.timeout(const Duration(seconds: 5));
      expect(device.id, 'd1');
      expect(position, const Duration(seconds: 30), reason: '最后已知轮询位置');
      expect(controller.state, CastSessionState.idle);
      expect(controller.currentDevice, isNull);
      expect(probeCalls, 1);
      expect(factoryCalls, 1, reason: '门控失败不重投');
      expect(transport.calls.where((c) => c.startsWith('setUri')), hasLength(1));
      expect(toasts, 0, reason: '静默：不 toast、不打扰');
      expect(lostCalls, 0, reason: '门控失败走电视端停止路径，不走 onSessionLost');
      expect(recorder.lastSession, isNotNull, reason: '记录保留（电视开机后可手动恢复）');
      expect(recorder.calls, contains('ended'));
      final timeline = CastDiagnostics.instance.timeline;
      expect(timeline.any((l) => l.contains('电视端停止投屏')), isTrue);
      expect(timeline.any((l) => l.contains('中断自动恢复：目标不可达')), isTrue);
      controller.dispose();
    });

    test('复检成功但重投失败 → 现有错误路径：会话收尾回 idle、'
        'onSessionLost、记录保留、无 toast', () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      var probeCalls = 0;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return true;
      };
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;

      await controller.castTo(_target('d1'), _media());
      // 首投成功后注入 setUri 故障：恢复重投时失败。
      transport.setUriError = SoapException('设备未响应');
      transport.failPoll = true;
      await _failPolls(controller, 5);

      await _waitUntil(() => lostCalls == 1);
      expect(controller.state, CastSessionState.idle);
      expect(controller.currentDevice, isNull);
      expect(probeCalls, 1);
      expect(toasts, 0);
      expect(recorder.lastSession, isNotNull, reason: '失败不删记录（可手动重试）');
      expect(recorder.calls, contains('ended'));
      controller.dispose();
    });

    test('flag 会话结束复位：恢复尝试结束会话后，新会话失联可再次触发', () async {
      final transport = FakeTransport();
      var factoryCalls = 0;
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) {
          factoryCalls++;
          return transport;
        },
        sessionRecorder: recorder,
      );
      var probeCalls = 0;
      var allow = false;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return allow;
      };
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;

      // 会话 1：门控失败 → 会话结束（flag 复位）。
      await controller.castTo(_target('d1'), _media());
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => controller.state == CastSessionState.idle);
      expect(probeCalls, 1);
      expect(factoryCalls, 1);

      // 会话 2：用户重新投屏 → 失联 → 再次触发（探针第 2 次，这次放行）。
      transport.failPoll = false;
      allow = true;
      await controller.castTo(_target('d1'), _media());
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => toasts == 1);
      expect(probeCalls, 2, reason: '会话结束后 flag 复位，新会话重新获得恰一次机会');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('未记录会话（未接 recorder）失联 → 直接 onSessionLost，默认路径不变',
        () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      var probeCalls = 0;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return true;
      };
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;

      await controller.castTo(_target('d1'), _media());
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => lostCalls == 1);
      expect(probeCalls, 0, reason: '无可恢复记录，不做自动恢复');
      expect(controller.state, CastSessionState.casting,
          reason: '既有行为：失联不自动结束会话');
      controller.dispose();
    });
  });

  group('AC-1/R4 护栏', () {
    test('恢复尝试期间瞬态 STOPPED 不误判电视端主动停止（换集同款护栏）', () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      controller.reachabilityProbe = (_) async {
        // 探针挂起 200ms：制造「恢复尝试进行中」的窗口。
        await Future<void>.delayed(const Duration(milliseconds: 200));
        return true;
      };
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;
      var stoppedCalls = 0;
      controller.onRemoteStopped = (_, _) => stoppedCalls++;

      await controller.castTo(_target('d1'), _media());
      transport.failPoll = true;
      await _failPolls(controller, 5);
      // 探针挂起期间设备瞬态上报 STOPPED：护栏吞掉，不结束会话。
      transport.failPoll = false;
      transport.pollResult = const CastPoll(
          transportState: 'STOPPED', position: Duration(seconds: 30));
      await controller.forceRefresh();
      // 恢复重投成功。
      transport.failPoll = true;
      transport.pollResult = const CastPoll(
          transportState: 'RUNNING', position: Duration(seconds: 30));
      await _waitUntil(() => toasts == 1);
      expect(stoppedCalls, 0, reason: 'R4：恢复尝试期间 STOPPED 不误判电视端停止');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('换集推送进行中失联 → 不触发恢复（共用推送护栏互斥），走既有 onSessionLost',
        () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      var probeCalls = 0;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return true;
      };
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;
      controller.onNextEpisode = () async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return null; // 模拟取下一集期间失联批次到达。
      };

      await controller.castTo(_target('d1'), _media());
      final advance = controller.advanceNextEpisode();
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => lostCalls == 1);
      expect(probeCalls, 0, reason: '换集推送进行中不启动恢复（_autoAdvancing 互斥）');
      expect(await advance, isFalse);
      transport.failPoll = false;
      controller.dispose();
    });
  });

  group('复检探针（默认实现，真实 HTTP/TCP）', () {
    test('描述 URL 200 → 可达', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        req.response.write('<root/>');
        await req.response.close();
      });
      expect(
        await probeDeviceDescriptionReachable(
            'http://127.0.0.1:${server.port}/dd.xml'),
        isTrue,
      );
    });

    test('描述 URL 404 → 不可达（门控失败 → 静默）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        req.response.statusCode = 404;
        await req.response.close();
      });
      expect(
        await probeDeviceDescriptionReachable(
            'http://127.0.0.1:${server.port}/dd.xml'),
        isFalse,
      );
    });

    test('描述 URL 连接拒绝 → 不可达', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      expect(
        await probeDeviceDescriptionReachable('http://127.0.0.1:$port/dd.xml'),
        isFalse,
      );
    });

    test('描述 URL 响应超时（>1.8s 口径）→ 不可达且有界返回', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        await Future<void>.delayed(const Duration(seconds: 3));
        await req.response.close();
      });
      // 单次尝试口径：attempts=1 时 1.8s 超时先发制人，不等 3s 慢响应。
      final sw = Stopwatch()..start();
      final ok = await probeDeviceDescriptionReachable(
          'http://127.0.0.1:${server.port}/dd.xml',
          attempts: 1);
      expect(ok, isFalse);
      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
    });

    test('默认双尝试：首次超时第二次成功 → 可达（慢设备防御）', () async {
      var hits = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((req) async {
        hits++;
        if (hits == 1) {
          await Future<void>.delayed(const Duration(seconds: 3));
          await req.response.close();
          return;
        }
        await req.response.close();
      });
      final ok = await probeDeviceDescriptionReachable(
          'http://127.0.0.1:${server.port}/dd.xml');
      expect(ok, isTrue, reason: '第二次尝试应命中');
      expect(hits, 2);
    });

    test('无描述 URL 协议：端口探活连上即可达、拒绝则不可达', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      expect(await probeHostPortReachable('127.0.0.1', server.port), isTrue);
      expect(await probeHostPortReachable('127.0.0.1', 1), isFalse);
    });
  });

  // 注意：本组必须在文件最后——ensureInitialized 的测试绑定会接管
  // HttpClient，污染同 isolate 里后续测试的原始网络请求；镜像会话的
  // disconnect/dispose 路径会触到 MirrorController（同 cast_controller_test
  // 与 cast_session_resume_test 的镜像组约定）。
  group('AC-3 镜像排除（文件末尾：需要测试绑定）', () {
    test('镜像会话失联：不复检、不重投，直接既有 onSessionLost', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      var probeCalls = 0;
      controller.reachabilityProbe = (_) async {
        probeCalls++;
        return true;
      };
      var lostCalls = 0;
      controller.onSessionLost = (_) => lostCalls++;
      var toasts = 0;
      controller.onAutoReconnected = () => toasts++;

      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://192.168.1.5:18380/stream.ts',
            title: '屏幕镜像',
            isMirror: true),
      );
      transport.failPoll = true;
      await _failPolls(controller, 5);
      await _waitUntil(() => lostCalls == 1);
      expect(probeCalls, 0, reason: '镜像会话不参与中断自动恢复（R4）');
      expect(controller.state, CastSessionState.casting);
      expect(toasts, 0);
      await controller.disconnect();
      controller.dispose();
    });
  });
}
