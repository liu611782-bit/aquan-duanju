import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

/// 全生命周期序列测试（工程收束批 R2）。
///
/// 分片测试（cast_controller_test / cast_p1_test / cast_auto_reconnect_test /
/// cast_session_resume_test）各自覆盖单环节；本文件用**一条连续序列**跑完
/// 投送 → 播完连投 → 轮询失联 → 自动恢复（复检门控）→ 电视端停止 →
/// 会话收尾（endedAt）→ resumeLastSession → 手动换集 → 手动断开，
/// 断言只有序列联动才能暴露的面：
/// - 每环节的 transport 调用序列（compat 链：preflight → load）；
/// - 诊断时间线关键行（连播/恢复/电视端停止/用户断开）；
/// - lastSession 演进（record → position → re-record → endedAt）；
/// - 自动恢复**恰一次**（同 transport 重投 + 位置接续）；
/// - 恢复重投**配方命中**（记忆配方置顶，不重跑全梯度）。
///
/// 搭建与注入方式参照 cast_auto_reconnect_test（FakeTransport 工厂 +
/// reachabilityProbe 假件 + 内存 recorder + forceRefresh 直驱轮询）。
DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

const _ep1 = CastMedia(url: 'http://192.168.1.10/1.mp4', title: '第1集');
const _ep2 = CastMedia(url: 'http://192.168.1.10/2.mp4', title: '第2集');
const _ep3 = CastMedia(url: 'http://192.168.1.10/3.mp4', title: '第3集');

/// 全生命周期假 transport：compat 能力（控制器走 preflight → load 配方链）
/// + 幂等相静态轮询 + 一次性转移相轮询。
///
/// - [pollResult]：常规播放轮询（幂等，定时器与 forceRefresh 谁来都一样）；
/// - [oneShots]：状态转移轮询（播完 / 电视端停止），**恰被一次 poll 消费**
///   ——杜绝 1s 轮询定时器与测试直驱并发消费同一 STOPPED 结果导致的双重
///   连投 / 双重收尾（序列联动下的真实坑，脚本化队列按条消费同理）；
/// - [failPoll]：true = poll 抛异常（模拟失联，forceRefresh 直驱计数）。
class _LifecycleTransport implements CastTransport, CastCompatTransport {
  _LifecycleTransport();

  final List<String> calls = [];
  final List<CastLoadRequest> loadRequests = [];
  CastPoll pollResult = const CastPoll(
      transportState: 'RUNNING', position: Duration(seconds: 5));
  final List<CastPoll> oneShots = [];
  bool failPoll = false;

  @override
  Future<Set<String>> preflight() async {
    calls.add('preflight');
    return <String>{'http-get:*:video/mp4:*'};
  }

  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    loadRequests.add(request);
    calls.add('load:${request.url}|${request.title}'
        '|pos=${request.position.inMilliseconds}');
    return const CastRecipe(didl: DidlVariant.compact);
  }

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url');
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
    if (oneShots.isNotEmpty) return oneShots.removeAt(0);
    return pollResult;
  }

  @override
  void close() => calls.add('close');
}

/// 内存版会话恢复记录器（与 cast_auto_reconnect_test 同款 + endedAt 真实演进）。
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
    calls.add('record:$mediaUrl|$title|$positionMs|${target.id}');
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
  Future<void> markSessionEnded() async {
    calls.add('ended');
    final r = lastSession;
    if (r == null) return;
    lastSession = CastSessionRecord(
      targetPersistJson: r.targetPersistJson,
      title: r.title,
      mediaUrl: r.mediaUrl,
      positionMs: r.positionMs,
      sourceId: r.sourceId,
      episodeIndex: r.episodeIndex,
      endedAt: DateTime.now(),
    );
  }

  @override
  Future<void> clearLastSession() async {
    calls.add('clear');
    lastSession = null;
  }
}

/// 配方语义相等（忽略 successCount：`fallbackChain` 去重按归一化比较，
/// 但链内元素保留原 successCount——诊断计数不参与配方语义）。
bool _sameRecipe(CastRecipe a, CastRecipe b) =>
    a.copyWith(successCount: 0) == b.copyWith(successCount: 0);

/// 直驱 _pollOnce 制造 N 次连续轮询失败（不等真实 1s 轮询定时器）。
Future<void> _failPolls(CastController controller, int times) async {
  for (var i = 0; i < times; i++) {
    await controller.forceRefresh();
  }
}

/// 等待条件成立（deadline 轮询；连播/恢复链路是异步流程，谁先消费不定）。
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
  group('全生命周期序列（一条 FakeTransport 跑完收束批 R2 全环节）', () {
    test(
      '投送 → 播完连投 → 失联自动恢复 → 电视端停止 → resumeLastSession → '
      '手动换集 → 手动断开',
      () async {
        final transport = _LifecycleTransport();
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
        final remoteStops = <(CastTarget, Duration)>[];
        controller.onRemoteStopped = (device, position) {
          remoteStops.add((device, position));
        };

        // ① castTo(设备A)：compat 全链 preflight → load；无记忆 → 完整梯度链。
        await controller.castTo(_target('d1'), _ep1);
        expect(controller.state, CastSessionState.casting);
        expect(controller.currentDevice?.id, 'd1');
        expect(factoryCalls, 1);
        expect(transport.calls.first, 'preflight');
        expect(transport.calls[1], startsWith('load:http://192.168.1.10/1.mp4'));
        expect(recorder.calls.single,
            'record:http://192.168.1.10/1.mp4|第1集|0|d1',
            reason: '投送成功写全量恢复记录（源 URL）');
        final firstLoad = transport.loadRequests.single;
        expect(firstLoad.recipes, CastRecipeStore.gradient,
            reason: '首投无记忆：完整梯度链（full/standard 起扫）');
        expect(
          CastDiagnostics.instance.timeline,
          containsAll(<Matcher>[
            contains('选路：直投'),
            contains('能力预检完成'),
          ]),
        );
        final endedAtAfterCast = recorder.lastSession!.endedAt;

        // ② 正常播放轮询：进度写入恢复记录（会话中持续更新 =「最后位置」）。
        transport.pollResult = const CastPoll(
            transportState: 'RUNNING',
            position: Duration(seconds: 47),
            duration: Duration(seconds: 120));
        await controller.forceRefresh();
        expect(recorder.calls, contains('position:47000'));
        expect(recorder.lastSession?.positionMs, 47000);

        // ③ poll 报告播完（118s / 120s，≥ dur-5s）→ 自动连投下一集
        //    （_handlePoll ended 分支 → _tryAdvance，与 advanceNextEpisode
        //    同一推送链路）。一次性转移轮询恰被消费一次 → 恰一次连投。
        controller.onNextEpisode = () async => _ep2;
        transport.oneShots.add(const CastPoll(
            transportState: 'STOPPED',
            position: Duration(seconds: 118),
            duration: Duration(seconds: 120)));
        await controller.forceRefresh();
        await _waitUntil(() => recorder.calls
            .contains('record:http://192.168.1.10/2.mp4|第2集|0|d1'));
        expect(controller.state, CastSessionState.casting,
            reason: '连投不回 idle（避免 connecting 闪烁）');
        expect(controller.currentMedia?.title, '第2集');
        expect(remoteStops, isEmpty, reason: '播完连投不是电视端停止');
        final secondLoad = transport.loadRequests[1];
        expect(secondLoad.url, Uri.parse('http://192.168.1.10/2.mp4'));
        expect(secondLoad.position, Duration.zero, reason: '新一集从零起播');
        expect(
            _sameRecipe(secondLoad.recipes.first,
                const CastRecipe(didl: DidlVariant.compact)),
            isTrue,
            reason: '连投沿用会话记忆配方（置顶），不重扫梯度');
        expect(transport.loadRequests.length, 2, reason: '连投恰一次推送');
        expect(
          CastDiagnostics.instance.timeline.any(
              (l) => l.contains('连播下一集：第2集')),
          isTrue,
        );

        // ④ 第2集进度 47s = 失联前的「最后位置」。
        await controller.forceRefresh();
        expect(recorder.lastSession?.positionMs, 47000);

        // ⑤ 连续 poll 失败 ≥5 → 复检成功 → 自动恢复恰一次（同 transport
        //    重投 + 位置接续 47s + 记录重写）。
        transport.failPoll = true;
        await _failPolls(controller, 5);
        await _waitUntil(() => toasts == 1);
        transport.failPoll = false;
        expect(probes, hasLength(1), reason: '复检恰一次');
        expect(probes.single.id, 'd1');
        expect(factoryCalls, 2, reason: '首投 + 恢复重投（工厂复用同一假件实例）');
        expect(controller.state, CastSessionState.casting);
        expect(controller.currentDevice?.id, 'd1');
        expect(controller.currentMedia?.title, '第2集');
        expect(toasts, 1, reason: 'onAutoReconnected 恰一次');
        expect(lostCalls, 0, reason: '恢复成功不走 onSessionLost');
        // 同 transport 重投：先 close 失联旧连接，再 preflight → load。
        final load2Idx =
            transport.calls.indexWhere((c) => c.startsWith('load:'));
        final closeIdx = transport.calls.indexOf('close', load2Idx + 1);
        final reconnectLoadIdx = transport.calls
            .indexWhere((c) => c.startsWith('load:'), closeIdx + 1);
        expect(closeIdx, greaterThan(load2Idx), reason: '重投前释放失联旧 transport');
        expect(reconnectLoadIdx, greaterThan(closeIdx));
        final reconnectLoad = transport.loadRequests[2];
        expect(reconnectLoad.url, Uri.parse('http://192.168.1.10/2.mp4'));
        expect(reconnectLoad.position, const Duration(seconds: 47),
            reason: '重投 seek 记录位置（compat 链路在 load 请求带 position）');
        expect(
            _sameRecipe(reconnectLoad.recipes.first,
                const CastRecipe(didl: DidlVariant.compact)),
            isTrue,
            reason: '恢复重投配方命中：记忆配方置顶，不从梯度首项重扫');
        expect(recorder.calls,
            contains('record:http://192.168.1.10/2.mp4|第2集|47000|d1'),
            reason: '恢复重投重写记录：位置接续（47s），不是从 0 重记');
        expect(
          CastDiagnostics.instance.timeline
              .any((l) => l.contains('中断自动恢复')),
          isTrue,
        );

        // ⑥ 电视端停止（停在中途，非播完）→ onRemoteStopped(device, 位置)
        //    → 会话收尾：endedAt 更新、记录保留、提供器清空。
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final endedAtBeforeStop = recorder.lastSession!.endedAt;
        transport.oneShots.add(const CastPoll(
            transportState: 'STOPPED',
            position: Duration(minutes: 2),
            duration: Duration(minutes: 10)));
        await _waitUntil(() => controller.state == CastSessionState.idle);
        expect(remoteStops, hasLength(1));
        expect(remoteStops.single.$1.id, 'd1');
        expect(remoteStops.single.$2, const Duration(minutes: 2),
            reason: 'onRemoteStopped 携带最后已知位置');
        expect(controller.currentDevice, isNull);
        expect(controller.onNextEpisode, isNull, reason: '会话结束清空连播提供器');
        expect(recorder.calls.where((c) => c == 'ended'), hasLength(1));
        expect(recorder.lastSession, isNotNull, reason: '记录保留（重启后可恢复）');
        expect(recorder.lastSession!.endedAt.isAfter(endedAtBeforeStop),
            isTrue, reason: '会话收尾更新 endedAt');
        expect(recorder.lastSession!.positionMs, 120000,
            reason: '电视端停止位置落入记录（恢复接续用）');
        expect(
          CastDiagnostics.instance.timeline
              .any((l) => l.contains('电视端停止投屏')),
          isTrue,
        );

        // ⑦ resumeLastSession：记录重建 target → 标准序列重投；恰一次 load
        //    （配方命中，无全梯度重试）；位置接续 2min。
        final loadsBeforeResume = transport.loadRequests.length;
        final ok = await controller.resumeLastSession();
        expect(ok, isTrue);
        expect(controller.state, CastSessionState.casting);
        expect(factoryCalls, 3, reason: '恢复重投第三次经工厂取 transport');
        expect(transport.loadRequests.length, loadsBeforeResume + 1,
            reason: '恰一次 load：配方命中不重跑全梯度');
        final resumeLoad = transport.loadRequests.last;
        expect(resumeLoad.url, Uri.parse('http://192.168.1.10/2.mp4'));
        expect(resumeLoad.title, '第2集');
        expect(resumeLoad.position, const Duration(minutes: 2),
            reason: '恢复位置接续电视端停止时的最后位置');
        expect(
            _sameRecipe(resumeLoad.recipes.first,
                const CastRecipe(didl: DidlVariant.compact)),
            isTrue,
            reason: '恢复重投复用配方：记忆配方置顶，而非梯度首项 full/standard');
        expect(resumeLoad.recipes.length, CastRecipeStore.gradient.length,
            reason: '命中记忆后梯度仅作兜底（去重后链长不变）');
        expect(recorder.calls,
            contains('record:http://192.168.1.10/2.mp4|第2集|120000|d1'),
            reason: '恢复成功重写记录（位置保留）');

        // ⑧ 手动换集（advanceNextEpisode，恢复后的会话内）：同一 transport
        //    推送第3集，会话保持，记录跟随。
        controller.onNextEpisode = () async => _ep3;
        expect(await controller.advanceNextEpisode(), isTrue);
        expect(controller.state, CastSessionState.casting);
        expect(controller.currentMedia?.title, '第3集');
        expect(factoryCalls, 3, reason: '手动换集在当前 transport 上推送');
        final advanceLoad = transport.loadRequests.last;
        expect(advanceLoad.title, '第3集');
        expect(advanceLoad.position, Duration.zero);
        expect(recorder.calls,
            contains('record:http://192.168.1.10/3.mp4|第3集|0|d1'),
            reason: '恢复记录跟随到第3集');

        // ⑨ 手动断开：读进度 → Stop → 收尾；状态 idle、记录保留。
        transport.pollResult = const CastPoll(
            transportState: 'RUNNING', position: Duration(seconds: 9));
        final finalPosition = await controller.disconnect();
        expect(finalPosition, const Duration(seconds: 9),
            reason: '断开返回电视端最后进度');
        expect(controller.state, CastSessionState.idle);
        expect(controller.currentDevice, isNull);
        expect(transport.calls.where((c) => c == 'stop'), isNotEmpty,
            reason: '断开下发 Stop');
        expect(recorder.calls.where((c) => c == 'ended'), hasLength(2),
            reason: '电视端停止 + 手动断开各收尾一次');
        expect(recorder.lastSession, isNotNull, reason: '断开不删记录');
        expect(recorder.lastSession!.mediaUrl, 'http://192.168.1.10/3.mp4');
        expect(recorder.calls, isNot(contains('clear')),
            reason: '正常生命周期全程无记录清理');
        expect(lostCalls, 0);
        expect(
          CastDiagnostics.instance.timeline
              .any((l) => l.contains('用户断开投屏')),
          isTrue,
        );
        expect(endedAtAfterCast.isBefore(recorder.lastSession!.endedAt),
            isTrue, reason: 'endedAt 随会话收尾演进');
        controller.dispose();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );
  });
}
