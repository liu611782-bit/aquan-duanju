import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DlnaDevice _dlna(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
      location: 'http://192.168.1.9/desc.xml',
    );

CastTarget _target(String udn) => CastTarget.dlna(_dlna(udn));

/// 脚本化 transport：poll 序列 + 可选的第二次 setUri 失败。
class _ScriptedTransport implements CastTransport {
  final List<CastPoll> pollScript;
  bool failSecondSetUri = false;
  int setUriCount = 0;
  final calls = <String>[];

  _ScriptedTransport(this.pollScript);

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    setUriCount++;
    calls.add('setUri:$url');
    if (failSecondSetUri && setUriCount >= 2) {
      throw SoapException('SetAVTransportURI 失败 HTTP 500',
          faultCode: 'UPnPError');
    }
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seek');
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
  @override
  Future<void> setMute(bool muted) async => calls.add('mute:$muted');

  int _pollIndex = 0;

  @override
  Future<CastPoll> poll() async {
    calls.add('poll');
    final i = _pollIndex.clamp(0, pollScript.length - 1);
    _pollIndex++;
    return pollScript[i];
  }

  @override
  void close() {}
}

const _running = CastPoll(
  transportState: 'RUNNING',
  position: Duration(seconds: 590),
  duration: Duration(minutes: 10),
);
const _ended = CastPoll(
  transportState: 'STOPPED',
  position: Duration(seconds: 596),
  duration: Duration(minutes: 10),
);
const _midStop = CastPoll(
  transportState: 'STOPPED',
  position: Duration(minutes: 2),
  duration: Duration(minutes: 10),
);

void main() {
  test('播完（接近时长结尾）自动连投下一集，会话不中断', () async {
    final transport = _ScriptedTransport([_running, _ended]);
    final controller = CastController(transportFactory: (_) => transport);
    var remoteStopped = 0;
    controller.onRemoteStopped = (_, _) => remoteStopped++;

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    // 等两轮 1s 轮询触发 ended 分支。
    await Future<void>.delayed(const Duration(milliseconds: 2300));

    expect(transport.setUriCount, 2);
    expect(transport.calls.contains('setUri:http://x/2.mp4'), isTrue);
    expect(transport.calls.contains('play'), isTrue);
    expect(controller.state, CastSessionState.casting, reason: '连投后会话继续');
    expect(controller.currentMedia?.title, '第2集');
    expect(remoteStopped, 0, reason: '正常连投不应触发远端停止');
    controller.dispose();
  });

  test('停在中途：视为遥控器手动停止，不连投', () async {
    final transport = _ScriptedTransport([_running, _midStop]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<Duration>();
    controller.onRemoteStopped = (_, position) => stopped.complete(position);

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    final position = await stopped.future.timeout(const Duration(seconds: 3));
    expect(position, const Duration(minutes: 2));
    expect(transport.setUriCount, 1, reason: '不应连投');
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('没有下一集：走远端停止路径', () async {
    final transport = _ScriptedTransport([_running, _ended]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async => null;

    await stopped.future.timeout(const Duration(seconds: 3));
    expect(transport.setUriCount, 1);
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('连投推送失败：回退远端停止路径', () async {
    final transport = _ScriptedTransport([_running, _ended])
      ..failSecondSetUri = true;
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');

    await stopped.future.timeout(const Duration(seconds: 3));
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('会话结束清空连播提供器', () async {
    final transport = _ScriptedTransport([_running, _midStop]);
    final controller = CastController(transportFactory: (_) => transport);
    final stopped = Completer<void>();
    controller.onRemoteStopped = (_, _) => stopped.complete();

    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    controller.onNextEpisode = () async =>
        const CastMedia(url: 'http://x/2.mp4', title: '第2集');
    await stopped.future.timeout(const Duration(seconds: 3));
    expect(controller.onNextEpisode, isNull, reason: '防止旧闭包跨会话生效');
    controller.dispose();
  });

  test('setMute 透传到 transport', () async {
    final transport = _ScriptedTransport([_running]);
    final controller = CastController(transportFactory: (_) => transport);
    await controller.castTo(
      _target('d1'),
      const CastMedia(url: 'http://x/1.mp4', title: 't'),
    );
    await controller.setMute(true);
    expect(transport.calls.contains('mute:true'), isTrue);
    controller.dispose();
  });

  group('遥控器手动换集（进度条任务 11-07-cast-remote-polish）', () {
    test('手动下一集：复用连播链路在同一 transport 换集，会话不断', () async {
      final transport = _ScriptedTransport([_running]);
      final controller = CastController(transportFactory: (_) => transport);
      var remoteStopped = 0;
      controller.onRemoteStopped = (_, _) => remoteStopped++;

      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
      );
      controller.onNextEpisode = () async =>
          const CastMedia(url: 'http://x/2.mp4', title: '第2集');

      final ok = await controller.advanceNextEpisode();
      expect(ok, isTrue);
      expect(transport.setUriCount, 2, reason: '同一 transport 上换集（不重复起停中继）');
      expect(transport.calls.contains('setUri:http://x/2.mp4'), isTrue);
      expect(controller.state, CastSessionState.casting, reason: '手动换集会话保持');
      expect(controller.currentMedia?.title, '第2集');
      // 换集后进度归零（远端从零起播）；插值含亚毫秒噪声，用上限断言。
      expect(controller.remotePosition, lessThan(const Duration(seconds: 1)),
          reason: '换集后进度归零，不是上一集的 590s');
      expect(remoteStopped, 0, reason: '手动换集不是远端停止');
      controller.dispose();
    });

    test('手动下一集：未注入提供器返回 false（面板按钮置灰对应路径）', () async {
      final transport = _ScriptedTransport([_running]);
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
      );
      expect(await controller.advanceNextEpisode(), isFalse);
      expect(controller.state, CastSessionState.casting);
      expect(transport.setUriCount, 1);
      controller.dispose();
    });

    test('手动上一集：onEpisodeJump 提供 delta 语义媒体并复用推送链路', () async {
      final transport = _ScriptedTransport([_running]);
      final controller = CastController(transportFactory: (_) => transport);
      var remoteStopped = 0;
      controller.onRemoteStopped = (_, _) => remoteStopped++;

      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/2.mp4', title: '第2集'),
      );
      controller.onEpisodeJump = (delta) async {
        expect(delta, -1);
        return const CastMedia(url: 'http://x/1.mp4', title: '第1集');
      };

      final ok = await controller.jumpEpisode(-1);
      expect(ok, isTrue);
      expect(transport.setUriCount, 2);
      expect(transport.calls.contains('setUri:http://x/1.mp4'), isTrue);
      expect(controller.currentMedia?.title, '第1集');
      expect(controller.state, CastSessionState.casting);
      expect(remoteStopped, 0);
      controller.dispose();
    });

    test('onEpisodeJump 未注入：jumpEpisode 返回 false 不抛错、会话保持', () async {
      final transport = _ScriptedTransport([_running]);
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/2.mp4', title: '第2集'),
      );
      expect(await controller.jumpEpisode(-1), isFalse);
      expect(controller.state, CastSessionState.casting);
      expect(transport.setUriCount, 1);
      controller.dispose();
    });

    test('delta 0 / 越界（提供器返回 null）：false 且会话保持', () async {
      final transport = _ScriptedTransport([_running]);
      final controller = CastController(transportFactory: (_) => transport);
      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/2.mp4', title: '第2集'),
      );
      controller.onEpisodeJump = (delta) async => null;

      expect(await controller.jumpEpisode(0), isFalse, reason: 'delta 0 无意义');
      expect(await controller.jumpEpisode(-1), isFalse, reason: '越界 → null');
      expect(await controller.jumpEpisode(5), isFalse);
      expect(controller.state, CastSessionState.casting, reason: '手动换集失败不清会话');
      expect(transport.setUriCount, 1);
      controller.dispose();
    });

    test('跳集推送失败：返回 false，会话保持，不触发远端停止', () async {
      final transport = _ScriptedTransport([_running])..failSecondSetUri = true;
      final controller = CastController(transportFactory: (_) => transport);
      var remoteStopped = 0;
      controller.onRemoteStopped = (_, _) => remoteStopped++;

      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/2.mp4', title: '第2集'),
      );
      controller.onEpisodeJump = (delta) async =>
          const CastMedia(url: 'http://x/1.mp4', title: '第1集');

      expect(await controller.jumpEpisode(-1), isFalse);
      expect(controller.state, CastSessionState.casting,
          reason: '当前集仍在播：推送失败不归一为远端停止');
      expect(remoteStopped, 0);
      expect(controller.currentMedia?.title, '第2集', reason: '媒体记录不因失败被改写');
      controller.dispose();
    });

    test('会话结束清空跳集提供器', () async {
      final transport = _ScriptedTransport([_running, _midStop]);
      final controller = CastController(transportFactory: (_) => transport);
      final stopped = Completer<void>();
      controller.onRemoteStopped = (_, _) => stopped.complete();

      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
      );
      controller.onEpisodeJump = (delta) async =>
          const CastMedia(url: 'http://x/0.mp4', title: '第0集');
      await stopped.future.timeout(const Duration(seconds: 3));
      expect(controller.onEpisodeJump, isNull, reason: '防止旧闭包跨会话生效');
      controller.dispose();
    });

    test('换集推送期间轮询到 STOPPED：不打断会话（_autoAdvancing 护栏）', () async {
      final midStop = const CastPoll(
        transportState: 'STOPPED',
        position: Duration(minutes: 2),
        duration: Duration(minutes: 10),
      );
      final transport = _ScriptedTransport([_running, midStop, _running]);
      final controller = CastController(transportFactory: (_) => transport);
      var remoteStopped = 0;
      controller.onRemoteStopped = (_, _) => remoteStopped++;

      await controller.castTo(
        _target('d1'),
        const CastMedia(url: 'http://x/2.mp4', title: '第2集'),
      );
      // 提供器延迟 2.5s：第 2s 的轮询（返回 STOPPED）落在推送进行中。
      controller.onEpisodeJump = (delta) async {
        await Future<void>.delayed(const Duration(milliseconds: 2500));
        return const CastMedia(url: 'http://x/1.mp4', title: '第1集');
      };

      final ok = await controller.jumpEpisode(-1);
      expect(ok, isTrue);
      // 再等一轮轮询（第 3s，已回到 RUNNING）确认会话未被误停。
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(controller.state, CastSessionState.casting,
          reason: '推送期间的 STOPPED 轮询是换集瞬态，不是电视端停止');
      expect(remoteStopped, 0);
      expect(transport.setUriCount, 2);
      controller.dispose();
    });
  });
}
