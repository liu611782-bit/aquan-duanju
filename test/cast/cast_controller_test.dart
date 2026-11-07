import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/store/stores.dart';

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
  Object? seekError;

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
  Future<void> seekTo(Duration position) async {
    calls.add('seek:$position');
    if (seekError != null) throw seekError!;
  }
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

/// 兼容层假 transport：捕获 CastLoadRequest（M1-2/M1-8/M3 接线断言用）。
class CapturingCompatTransport implements CastTransport, CastCompatTransport {
  CapturingCompatTransport();

  final List<String> calls = <String>[];
  CastLoadRequest? lastRequest;
  Set<String> sinkAnswer = <String>{'http-get:*:video/mp4:*'};

  /// load 成功时返回的配方（可注入以模拟某台设备只吃 compact+bare）。
  CastRecipe hitRecipe = const CastRecipe(didl: DidlVariant.full);

  /// 轮询结果（连播测试切 STOPPED 触发播完连投）。
  CastPoll pollResult =
      const CastPoll(transportState: 'PLAYING', position: Duration.zero);

  @override
  Future<Set<String>> preflight() async => sinkAnswer;

  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    lastRequest = request;
    calls.add('load');
    return hitRecipe;
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
  Future<CastPoll> poll() async => pollResult;
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

  group('进度拖动（乐观 seek / 失败回读）', () {
    test('seekTo 下发 transport 并乐观对齐本地进度（不等轮询）', () async {
      final transport = FakeTransport()
        ..pollResult = const CastPoll(
            transportState: 'PAUSED_PLAYBACK',
            position: Duration(seconds: 42),
            duration: Duration(minutes: 10));
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(_target('d1'), _media());
      // 先轮询一次拿到真值（42s），再模拟用户拖动。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));

      await controller.seekTo(const Duration(minutes: 3));

      expect(transport.calls, contains('seek:${const Duration(minutes: 3)}'),
          reason: '拖动结束立即下发 Seek');
      expect(controller.remotePosition, const Duration(minutes: 3),
          reason: '乐观对齐：进度条不回跳，等下一轮轮询用真值校正');
      controller.dispose();
    });

    test('seekTo 失败：本地进度不被乐观值污染，forceRefresh 回读真实位置', () async {
      final transport = FakeTransport()
        ..seekError = SoapException('Seek 失败 HTTP 501', faultCode: 'UPnPError')
        ..pollResult = const CastPoll(
            transportState: 'PAUSED_PLAYBACK',
            position: Duration(seconds: 42),
            duration: Duration(minutes: 10));
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(_target('d1'), _media());
      // 先轮询一次拿到真值（42s），再模拟用户拖动。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));

      await expectLater(
        controller.seekTo(const Duration(minutes: 5)),
        throwsA(isA<SoapException>()),
      );
      // 失败后本地进度仍是轮询真值（42s），没有乐观漂移。
      expect(controller.remotePosition, const Duration(seconds: 42));
      // 面板失败回读路径：forceRefresh 立即拉真实位置（仍是设备上报值）。
      await controller.forceRefresh();
      expect(controller.remotePosition, const Duration(seconds: 42));
      expect(transport.calls.where((c) => c.startsWith('seek:')).length, 1);
      controller.dispose();
    });
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

  group('M3 配方/画像持久化（AC-14）', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('落盘 → 新建 controller（模拟重启）→ 直接命中配方不再跑全梯度',
        () async {
      final dir = await tempDir('cast_controller_ac14');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      // 第一次投屏：设备只吃 compact+bare（模拟梯度扫描后命中）。
      const hit = CastRecipe(
          didl: DidlVariant.compact,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare);
      final compat1 = CapturingCompatTransport()..hitRecipe = hit;
      final controller1 = CastController(
        transportFactory: (_) => compat1,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller1.castTo(_target('d1'), _media());
      controller1.dispose();

      // 落盘断言：v4 文件里有 udn 精确键 + 设备画像。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(json['version'], 4);
      final recipes = json['recipes'] as Map<String, dynamic>;
      expect(recipes.keys, contains('udn:d1'));
      expect(
        CastRecipe.fromJson(recipes['udn:d1'] as Map<String, dynamic>).didl,
        DidlVariant.compact,
      );
      final profiles = json['profiles'] as Map<String, dynamic>;
      expect(profiles.keys, contains('udn:d1'));
      final profile = profiles['udn:d1'] as Map<String, dynamic>;
      expect(profile['profileId'], 'generic');
      expect(
        (profile['sinkProtocols'] as List).cast<String>(),
        contains('http-get:*:video/mp4:*'),
      );
      expect(
        (profile['capabilities'] as List).cast<String>(),
        contains('getProtocolInfo'),
        reason: '预检成功且 Sink 非空',
      );

      // 模拟重启：新 store + 新 controller（ CapturingCompatTransport 会把
      // 收到的配方链原样透传给断言）。
      final store2 = CastStore(testDirectory: dir);
      await store2.ensureLoaded();
      final compat2 = CapturingCompatTransport()..hitRecipe = hit;
      final controller2 = CastController(
        transportFactory: (_) => compat2,
        recipeStore: store2.recipes,
        profileStore: store2.profiles,
      );
      await controller2.castTo(_target('d1'), _media());

      // 链首 = 记忆的配方（不再从 full+standard 梯度首项扫起）。
      expect(compat2.lastRequest, isNotNull);
      expect(compat2.lastRequest!.recipes.first.didl, DidlVariant.compact);
      expect(compat2.lastRequest!.recipes.first.protocolInfoTemplate,
          DidlProtocolInfoTemplate.bare);
      // 梯度首项紧随其后（命中失败仍可逐级降级）。
      expect(compat2.lastRequest!.recipes[1].didl, DidlVariant.full);
      controller2.dispose();
    });

    test('画像/配方写入时序：投屏成功 remember(recipe) 后 profiles 同步落盘',
        () async {
      final dir = await tempDir('cast_controller_profile');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      final compat = CapturingCompatTransport();
      final controller = CastController(
        transportFactory: (_) => compat,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller.castTo(_target('d1'), _media());

      // castTo 返回时（remember 之后）两个表都已落盘。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['recipes'] as Map).keys, contains('udn:d1'));
      expect((json['profiles'] as Map).keys, contains('udn:d1'));
      // 控制器内存表与 store 同源（CastService.attachStores 接的就是它）。
      expect(store.recipes.lookup(_target('d1')), isNotNull);
      expect(store.profiles.lookup('d1'), isNotNull);
      controller.dispose();
    });

    test('连播换集走 compat.load：full 变体 duration 恢复、不再用旧 setUri',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      var advanced = false;
      controller.onNextEpisode = () async {
        if (advanced) return null;
        advanced = true;
        return const CastMedia(
          url: 'http://192.168.1.10/2.mp4',
          title: '测试 · 第2集',
          duration: Duration(minutes: 2, seconds: 3),
        );
      };
      await controller.castTo(_target('d1'), _media());
      expect(compat.calls.where((c) => c == 'load').length, 1);

      // 电视播完当前集（STOPPED 且位置在结尾）→ 触发连投。
      compat.pollResult = const CastPoll(
        transportState: 'STOPPED',
        position: Duration(minutes: 2, seconds: 10),
        duration: Duration(minutes: 2, seconds: 10),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (compat.calls.where((c) => c == 'load').length < 2 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(compat.calls.where((c) => c == 'load').length, 2,
          reason: '首投 + 连播各一次 compat.load');
      expect(compat.calls.any((c) => c.startsWith('setUri')), isFalse,
          reason: 'M3-5：连播不再走旧 transport.setUri 三件套');
      // 连播请求携带下一集的真实 duration（M2 遗留问题收口，AC-27）。
      expect(compat.lastRequest!.title, '测试 · 第2集');
      expect(compat.lastRequest!.duration, '0:02:03');
      expect(compat.lastRequest!.didl.duration,
          const Duration(minutes: 2, seconds: 3));
      expect(controller.currentMedia?.title, '测试 · 第2集');
      controller.dispose();
    });
  });

  group('M5 兼容模式选路（M5-0 / M5-3 / G5）', () {
    /// 注入记录型转码挂点，返回调用记录列表；[fail] = 模拟中继起不来。
    List<String> hook(CastController controller, {bool fail = false}) {
      final hooked = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl}) async {
        hooked.add(m.url);
        return fail ? null : 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      return hooked;
    }

    test('auto + MKV → 本机转码；DIDL 按转码产物 HLS 判定', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, ['http://192.168.1.10/1.mkv'], reason: 'MKV 默认走中继');
      expect(compat.lastRequest!.url.toString(),
          'http://192.168.1.9:18280/relay/index.m3u8');
      expect(compat.lastRequest!.didl.uri.toString(),
          'http://192.168.1.9:18280/relay/index.m3u8');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl',
          reason: '转码产物恒为 HLS');
      controller.dispose();
    });

    test('auto + HEVC 提示（MP4 容器）→ 本机转码', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://192.168.1.10/1.mp4', title: 't', codecHint: 'hevc'),
      );
      expect(hooked, hasLength(1), reason: 'HEVC/AV1 默认走中继转 H.264');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('auto + MP4（无编码提示）→ 直投，不触发转码挂点', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mp4', title: 't'),
      );
      expect(hooked, isEmpty);
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mp4'));
      expect(compat.lastRequest!.didl.mimeType, 'video/mp4');
      controller.dispose();
    });

    test('auto + HLS + Sink 含 HLS → 直投；Sink 不含 → 本机转码', () async {
      final supported = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller1 = CastController(transportFactory: (_) => supported);
      final hooked1 = hook(controller1);
      await controller1.castTo(_target('d1'), _media());
      expect(hooked1, isEmpty, reason: 'Sink 支持 HLS 时直投');
      expect(supported.lastRequest!.url, Uri.parse('http://192.168.1.10/1.m3u8'));
      controller1.dispose();

      final unsupported = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller2 = CastController(transportFactory: (_) => unsupported);
      final hooked2 = hook(controller2);
      await controller2.castTo(_target('d1'), _media());
      expect(hooked2, hasLength(1), reason: 'Sink 无 HLS mime → 走中继');
      expect(unsupported.lastRequest!.didl.mimeType,
          'application/vnd.apple.mpegurl');
      controller2.dispose();
    });

    test('auto + MKV + Sink 无 HLS 有 TS → ts 档：resolver 收 relayFormat=ts，'
        '产物 URL .ts 结尾且 DIDL 判 video/mp2t（AC-4）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp2t:*'};
      final controller = CastController(transportFactory: (_) => compat);
      final formats = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl}) async {
        formats.add(relayFormat ?? '');
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats, ['ts'], reason: 'Sink 无 HLS 有 TS → ts 档');
      expect(compat.lastRequest!.url.toString(), endsWith('/stream.ts'),
          reason: 'ts 档产物 URL 以 .ts 结尾');
      expect(compat.lastRequest!.didl.mimeType, 'video/mp2t',
          reason: '产物 mime 按 URL 扩展名判，DIDL 与产物同源');
      controller.dispose();
    });

    test('Sink 含 HLS → relayFormat=hls（现状）；Sink 缺失 → hls（证据缺失回落）',
        () async {
      // Sink 含 HLS 时 HLS 源走直投，用 MKV 强制进中继看档位。
      final compat1 = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:application/vnd.apple.mpegurl:*'};
      final controller1 = CastController(transportFactory: (_) => compat1);
      final formats1 = <String>[];
      controller1.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl}) async {
        formats1.add(relayFormat ?? '');
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller1.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats1, ['hls'], reason: 'Sink 含 HLS → hls 档（现状）');
      expect(compat1.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller1.dispose();

      final compat2 = CapturingCompatTransport()..sinkAnswer = <String>{};
      final controller2 = CastController(transportFactory: (_) => compat2);
      final formats2 = <String>[];
      controller2.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl}) async {
        formats2.add(relayFormat ?? '');
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller2.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(formats2, ['hls'], reason: 'Sink 缺失/未知 → hls（不回归）');
      controller2.dispose();
    });

    test('TS 档配方链升级：默认 standard → sinkEntry，Sink TS 拼写进 DIDL',
        () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{
          'http-get:*:video/vnd.dlna.mpeg-tts:DLNA.ORG_PN=MPEG_TS_HD_NA;*'
        };
      final controller = CastController(transportFactory: (_) => compat);
      controller.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl}) async {
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(compat.lastRequest!.recipes.first.protocolInfoTemplate,
          DidlProtocolInfoTemplate.sinkEntry,
          reason: 'TS 档产物：梯度首项 standard 升级 sinkEntry');
      expect(compat.lastRequest!.didl.mimeType, 'video/vnd.dlna.mpeg-tts',
          reason: '产物 mime 照抄设备 TS 拼写（preferSinkSpelling）');
      controller.dispose();
    });

    test('R3：会话字幕随中继调用透传（relaySubtitleUrl）', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp2t:*'};
      final controller = CastController(transportFactory: (_) => compat);
      Uri? passed;
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl}) async {
        passed = relaySubtitleUrl;
        return 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mkv',
          title: 't',
          subtitleUrl: 'http://192.168.1.10/sub.srt',
        ),
      );
      expect(passed, Uri.parse('http://192.168.1.10/sub.srt'),
          reason: '登记的字幕地址传给适配器 → castRelayStart subtitle_url');
      controller.dispose();
    });

    test('R1：编码提示合并——显式 h264 压过嗅探 hevc（红果优先级回归）', () async {
      // 本地伺服一个 ftyp=hvc1 的 MP4 头：控制器走 defaultSniffHead 真嗅探，
      // 嗅探产出 codecHint=hevc（模拟 CMS 无显式提示源的内容特征）。
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        const size = 8 + 4;
        req.response.add(<int>[
          0, 0, 0, size, ...'ftyp'.codeUnits, ...'hvc1'.codeUnits,
        ]);
        await req.response.close();
      });
      addTearDown(upstream.close);
      final mediaUrl = 'http://127.0.0.1:${upstream.port}/media';

      // 显式 codecHint=h264：合并结果 h264 → 直投不转码（红果行为不回归）。
      final compat1 = CapturingCompatTransport();
      final controller1 = CastController(transportFactory: (_) => compat1);
      final hooked1 = <String>[];
      controller1.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl}) async {
        hooked1.add(m.url);
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller1.castTo(
        _target('d1'),
        CastMedia(url: mediaUrl, title: 't', codecHint: 'h264'),
      );
      expect(hooked1, isEmpty, reason: '显式 h264 优先于嗅探 hevc → 不转码');
      expect(compat1.lastRequest!.didl.mimeType, 'video/mp4');
      controller1.dispose();

      // 无显式提示：同一内容嗅探 hevc 生效 → 中继转码（AC-2）。
      final compat2 = CapturingCompatTransport();
      final controller2 = CastController(transportFactory: (_) => compat2);
      final hooked2 = <String>[];
      controller2.transcodeResolver =
          (m, {relayFormat, relaySubtitleUrl}) async {
        hooked2.add(m.url);
        return 'http://192.168.1.9:18280/relay/index.m3u8';
      };
      await controller2.castTo(
        _target('d1'),
        CastMedia(url: mediaUrl, title: 't'),
      );
      expect(hooked2, hasLength(1), reason: '嗅探 hevc → auto 中继');
      expect(compat2.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller2.dispose();
    });

    test('never：MKV / HLS-无-Sink 都按现状直投，不触发转码挂点', () async {
      final compat = CapturingCompatTransport()
        ..sinkAnswer = <String>{'http-get:*:video/mp4:*'};
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.never);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, isEmpty, reason: '用户显式关闭转码');
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mkv'));
      expect(compat.lastRequest!.didl.mimeType, 'video/x-matroska');
      controller.dispose();
    });

    test('always：MP4 也走本机转码', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mp4', title: 't'),
      );
      expect(hooked, hasLength(1));
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('转码挂点失败（返回 null）→ 回退直投，不算投屏失败', () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      final hooked = hook(controller, fail: true);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, hasLength(1));
      expect(compat.lastRequest!.url, Uri.parse('http://192.168.1.10/1.mkv'),
          reason: '回退直投原始 URL');
      expect(compat.lastRequest!.didl.mimeType, 'video/x-matroska');
      expect(controller.state, CastSessionState.casting);
      controller.dispose();
    });

    test('viaRelay（URL 已是中继产物，如加密分集）→ 恒直投，不再二次转码',
        () async {
      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://127.0.0.1:18280/relay/index.m3u8',
          title: 't',
          viaRelay: true,
        ),
      );
      expect(hooked, isEmpty, reason: '中继产物不再套一层转码');
      expect(compat.lastRequest!.didl.mimeType, 'application/vnd.apple.mpegurl');
      controller.dispose();
    });

    test('Chromecast 播放路径不受选路影响（P0 契约：always 也不挂钩点）', () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      final target =
          CastTarget.chromecast(const CastDeviceInfo(host: '127.0.0.1', name: 'CC'));
      await controller.recipes.setTranscodeMode(target, CastTranscodeMode.always);
      final hooked = hook(controller);
      await controller.castTo(
        target,
        const CastMedia(url: 'http://192.168.1.10/1.mkv', title: 't'),
      );
      expect(hooked, isEmpty);
      expect(
        transport.calls.first,
        startsWith('setUri:http://192.168.1.10/1.mkv'),
      );
      controller.dispose();
    });
  });

  group('M5-1 字幕（DLNA 不转 VTT / 第三通道）', () {
    test('DLNA 字幕走代理且 SRT 不被转 VTT；媒体响应带 CaptionInfo.sec',
        () async {
      final upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      const srtBody = '1\n00:00:01,000 --> 00:00:03,000\n你好世界\n';
      final serverSub = upstream.listen((req) async {
        if (req.uri.path == '/sub.srt') {
          req.response.headers.contentType =
              ContentType('application', 'x-subrip', charset: 'utf-8');
          req.response.write(srtBody);
          await req.response.close();
          return;
        }
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]);
        await req.response.close();
      });
      addTearDown(() async {
        await serverSub.cancel();
        await upstream.close();
      });

      final compat = CapturingCompatTransport();
      final controller = CastController(transportFactory: (_) => compat);
      await controller.castTo(
        _target('d1'),
        CastMedia(
          // 媒体也指到本地上游：代理取流要真实可达（不可达 → 502 无第三通道头）。
          url: 'http://127.0.0.1:${upstream.port}/1.mp4',
          title: 't',
          headers: const {'Referer': 'http://origin/'},
          subtitleUrl: 'http://127.0.0.1:${upstream.port}/sub.srt',
        ),
      );

      // DIDL 三件套里的字幕 URL：代理路径 + .srt 扩展名。
      final sub = compat.lastRequest!.didl.subtitleUri!;
      expect(sub.host, '127.0.0.1', reason: '对外 URL host = 目标设备路由源 IP');
      expect(sub.path.endsWith('.srt'), isTrue, reason: 'DLNA 字幕 URL 带 .srt');
      final client = HttpClient();
      final res = await client.getUrl(sub).then((r) => r.close());
      expect(res.headers.contentType?.mimeType, 'text/srt',
          reason: '与 DIDL 声明的 text/srt 一致（修正转 VTT 却声明 srt 的错配）');
      expect(await res.transform(utf8.decoder).join(), srtBody,
          reason: 'SRT 响应体与输入一致（不转 VTT）');

      // 字幕第三通道：媒体响应头带 CaptionInfo.sec = 字幕 URL。
      final mediaRes =
          await client.getUrl(compat.lastRequest!.url).then((r) => r.close());
      expect(mediaRes.headers.value('captioninfo.sec'), sub.toString());
      client.close();
      controller.dispose();
    });
  });

  group('M5-0 AC-22：兼容模式三态按 UDN 记忆', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('写配方 → 落盘 → 重启读回（setTranscodeMode）', () async {
      final dir = await tempDir('cast_controller_ac22');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      await store.recipes.setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      // 立即读回。
      expect(store.recipes.lookup(_target('d1'))!.transcodeMode,
          CastTranscodeMode.always);
      // 落盘断言。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(
        CastRecipe.fromJson(
            ((json['recipes'] as Map<String, dynamic>)['udn:d1'])
                as Map<String, dynamic>)
            .transcodeMode,
        CastTranscodeMode.always,
      );

      // 模拟重启。
      final store2 = CastStore(testDirectory: dir);
      await store2.ensureLoaded();
      expect(store2.recipes.lookup(_target('d1'))!.transcodeMode,
          CastTranscodeMode.always);
    });

    test('用户设置的三态在梯度配方命中后不被冲掉（remember 沿用）', () async {
      final dir = await tempDir('cast_controller_ac22_keep');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      await store.recipes.setTranscodeMode(_target('d1'), CastTranscodeMode.never);

      // 梯度扫描命中 compact（返回的配方本身 mode=auto）。
      const hit = CastRecipe(didl: DidlVariant.compact);
      final compat = CapturingCompatTransport()..hitRecipe = hit;
      final controller = CastController(
        transportFactory: (_) => compat,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      await controller.castTo(_target('d1'), _media());

      final saved = store.recipes.lookup(_target('d1'))!;
      expect(saved.didl, DidlVariant.compact, reason: '命中配方正常记忆');
      expect(saved.transcodeMode, CastTranscodeMode.never,
          reason: '用户显式设置的从不不被 auto 冲掉');
      controller.dispose();
    });
  });

  // 注意：本组必须在文件最后——ensureInitialized 的测试绑定会接管
  // HttpClient，污染同 isolate 里后续测试的原始网络请求（registerSubtitle
  // 会被打断）。镜像测试需要绑定（MirrorController 的 MethodChannel）。
  group('M5 镜像路径不受选路影响（文件末尾：需要测试绑定）', () {
    test('always 也不挂钩点，镜像流按现状直投', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      await controller.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.always);
      final hooked = <String>[];
      controller.transcodeResolver = (m, {relayFormat, relaySubtitleUrl}) async {
        hooked.add(m.url);
        return 'http://127.0.0.1:18280/relay/index.m3u8';
      };
      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://127.0.0.1:18080/stream.ts', title: '屏幕镜像', isMirror: true),
      );
      expect(hooked, isEmpty);
      expect(
        transport.calls.first,
        startsWith('setUri:http://127.0.0.1:18080/stream.ts'),
      );
      await controller.disconnect();
      controller.dispose();
    });
  });
}
