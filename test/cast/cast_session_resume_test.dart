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
import 'package:aquan_duanju/widgets/cast_panel.dart';

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

CastMedia _media() =>
    const CastMedia(url: 'http://192.168.1.10/1.m3u8', title: '测试 · 第1集');

/// 假 transport：脚本化 poll 结果与故障注入（与 cast_controller_test 同款）。
class FakeTransport implements CastTransport {
  FakeTransport();

  final List<String> calls = [];
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));
  Object? setUriError;

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
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seek:$position');

  @override
  Future<void> setVolume(int percent) async {}
  @override
  Future<void> setMute(bool muted) async {}

  @override
  Future<CastPoll> poll() async => pollResult;

  @override
  void close() {}
}

/// 捕获 compat load 请求的假 transport（恢复链路 DIDL 断言用，
/// 与 cast_controller_test 的 CapturingCompatTransport 同款）。
class _CapturingCompatTransport implements CastTransport, CastCompatTransport {
  _CapturingCompatTransport();

  CastLoadRequest? lastRequest;
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));

  @override
  Future<Set<String>> preflight() async => <String>{'http-get:*:video/mp4:*'};

  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    lastRequest = request;
    return const CastRecipe(didl: DidlVariant.full);
  }

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {}

  @override
  Future<void> play() async {}
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

/// 内存版会话恢复记录器：断言控制器埋点时序用。
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
  }) async {
    calls.add('record:$mediaUrl|$title|$positionMs|${target.id}');
    lastSession = CastSessionRecord(
      targetPersistJson: target.toPersistJson(),
      title: title,
      mediaUrl: mediaUrl,
      positionMs: positionMs,
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

File _castFile(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

Future<CastStore> _newStore(Directory dir) async {
  final store = CastStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  group('CastStore.lastSession 持久化（AC-1）', () {
    test('投送成功写全量 → 新实例（重启）读回一致，目标可重建', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_ac1');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      expect(store.lastSession, isNull, reason: '无记录时为 null');

      await store.recordSession(
        target: _target('u1'),
        title: '短剧 · 第3集',
        mediaUrl: 'http://example.com/3.m3u8',
        positionMs: 65000,
      );
      expect(store.lastSession?.title, '短剧 · 第3集');
      expect(store.lastSession?.mediaUrl, 'http://example.com/3.m3u8');
      expect(store.lastSession?.positionMs, 65000);

      final store2 = await _newStore(dir);
      expect(store2.lastSession?.mediaUrl, 'http://example.com/3.m3u8');
      expect(store2.lastSession?.title, '短剧 · 第3集');
      expect(store2.lastSession?.positionMs, 65000);
      final target = store2.lastSession?.resolveTarget();
      expect(target?.id, 'u1');
      expect(target?.name, '客厅电视');
      expect(target?.protocol, CastProtocol.dlna);
    });

    test('与 lastDevice 互不覆盖：记录后 touchLast，两键都在且记录原样', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_mix');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.recordSession(
        target: _target('u1'),
        title: 't',
        mediaUrl: 'http://example.com/1.m3u8',
        positionMs: 1000,
      );
      await store.touchLast(_target('u2'));

      final store2 = await _newStore(dir);
      expect(store2.lastDevice?.id, 'u2');
      expect(store2.lastSession?.mediaUrl, 'http://example.com/1.m3u8');
      expect(store2.lastSession?.positionMs, 1000);
    });

    test('进度更新 10s 节流：窗口内忽略、窗外写入、再回窗口内又忽略', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_throttle');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.recordSession(
        target: _target('u1'),
        title: 't',
        mediaUrl: 'http://example.com/1.mp4',
      );
      final t0 = DateTime.now();
      await store.updateSessionPosition(1000, now: t0);
      expect(store.lastSession?.positionMs, 0, reason: '记录后 10s 内忽略');

      await store.updateSessionPosition(2000,
          now: t0.add(const Duration(seconds: 11)));
      expect(store.lastSession?.positionMs, 2000);

      await store.updateSessionPosition(3000,
          now: t0.add(const Duration(seconds: 15)));
      expect(store.lastSession?.positionMs, 2000, reason: '上次写入后又在窗口内');

      // 节流只改 positionMs：endedAt / 其余字段原样
      expect(store.lastSession?.mediaUrl, 'http://example.com/1.mp4');
    });

    test('断开/电视端停止：只更新 endedAt，不删记录（AC-1/R1.1）', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_end');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.recordSession(
        target: _target('u1'),
        title: 't',
        mediaUrl: 'http://example.com/1.mp4',
        positionMs: 120000,
      );
      final before = store.lastSession!;
      await store.markSessionEnded(
          now: before.endedAt.add(const Duration(minutes: 30)));
      final after = store.lastSession!;
      expect(after.mediaUrl, before.mediaUrl, reason: '记录保留供恢复');
      expect(after.positionMs, before.positionMs);
      expect(after.title, before.title);
      expect(after.endedAt.isAfter(before.endedAt), isTrue);

      final store2 = await _newStore(dir);
      expect(store2.lastSession, isNotNull, reason: '重启后仍可恢复');
      expect(store2.lastSession?.positionMs, 120000);
    });

    test('无记录时 updateSessionPosition / markSessionEnded 均 no-op', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_noop');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.updateSessionPosition(5000);
      await store.markSessionEnded();
      expect(store.lastSession, isNull);
      expect(_castFile(dir).readAsStringSync(), isNot(contains('lastSession')));
    });
  });

  group('控制器会话记录埋点（AC-1/AC-3）', () {
    test('投送成功写全量：record 带 URL/标题/目标（源 URL，非产物）', () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      await controller.castTo(_target('d1'), _media());
      expect(recorder.calls, hasLength(1));
      expect(
        recorder.calls.single,
        'record:http://192.168.1.10/1.m3u8|测试 · 第1集|0|d1',
      );
      expect(recorder.lastSession, isNotNull);
      controller.dispose();
    });

    test('恢复链路不记封面（R4，11-07-cast-cover-art）：记录结构无封面键、'
        '恢复投送 DIDL 不带 albumArtURI', () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      await controller.castTo(
        _target('d1'),
        const CastMedia(
          url: 'http://192.168.1.10/1.mp4',
          title: '带封面 · 第1集',
          coverUrl: 'http://192.168.1.10/cover.jpg',
        ),
      );
      expect(recorder.lastSession, isNotNull);
      // 记录结构不动：五键原样，无封面键（重启恢复后电视端无封面可接受）。
      final keys = recorder.lastSession!.toJson().keys.toSet();
      expect(
        keys,
        containsAll(<String>[
          'targetPersistJson',
          'title',
          'mediaUrl',
          'positionMs',
          'endedAt',
        ]),
      );
      expect(keys, isNot(contains('cover')));
      controller.dispose();

      // 恢复重走标准序列：记录无封面 → 重建 CastMedia 无封面 → DIDL 不出标签。
      final resumeTransport = _CapturingCompatTransport();
      final controller2 = CastController(
        transportFactory: (_) => resumeTransport,
        sessionRecorder: recorder,
      );
      expect(await controller2.resumeLastSession(), isTrue);
      expect(resumeTransport.lastRequest, isNotNull);
      expect(resumeTransport.lastRequest!.didl.albumArtUrl, isNull);
      controller2.dispose();
    });

    test('轮询进度按节流写入恢复记录（controller → CastStore）', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_poll');
      addTearDown(() => dir.delete(recursive: true));
      final store = CastStore(
        testDirectory: dir,
        sessionPositionThrottle: const Duration(milliseconds: 200),
      );
      await store.loadFromDisk();
      final transport = FakeTransport()
        ..pollResult = const CastPoll(
            transportState: 'PLAYING', position: Duration(seconds: 42));
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: store,
      );
      await controller.castTo(_target('d1'), _media());
      // 1s 轮询节拍 + 节流窗口（200ms）余量。
      await Future<void>.delayed(const Duration(milliseconds: 1400));
      expect(store.lastSession?.positionMs, 42000);
      controller.dispose();
    });

    test('手动断开：记录保留且收尾更新 endedAt（controller.disconnect 链路）',
        () async {
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      await controller.castTo(_target('d1'), _media());
      final endedAtBefore = recorder.lastSession!.endedAt;
      await controller.disconnect();
      expect(recorder.calls, contains('ended'));
      expect(recorder.lastSession, isNotNull, reason: '断开不删记录');
      expect(recorder.lastSession!.endedAt
          .isBefore(endedAtBefore.add(const Duration(seconds: 5))), isTrue);
      controller.dispose();
    });
  });

  group('恢复链路（AC-2）', () {
    test('resumeLastSession：重建 target → setUri → play → seek(记录位置)',
        () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      controller.sessionRecorder = _MemoryRecorder()
        ..lastSession = CastSessionRecord(
          targetPersistJson: _target('d1').toPersistJson(),
          title: '短剧 · 第2集',
          mediaUrl: 'http://192.168.1.10/2.m3u8',
          positionMs: 95000,
          endedAt: DateTime.now(),
        );

      final ok = await controller.resumeLastSession();

      expect(ok, isTrue);
      expect(controller.state, CastSessionState.casting);
      expect(controller.currentDevice?.id, 'd1');
      expect(transport.calls.first,
          startsWith('setUri:http://192.168.1.10/2.m3u8'));
      // 标准序列顺序：setUri → play → seek（position 95s > 3s）。
      final setUriIndex =
          transport.calls.indexWhere((c) => c.startsWith('setUri'));
      final playIndex = transport.calls.indexOf('play');
      final seekIndex = transport.calls.indexOf('seek:0:01:35.000000');
      expect(seekIndex, greaterThan(playIndex));
      expect(playIndex, greaterThan(setUriIndex));
      controller.dispose();
    });

    test('重启读回 → 新 store 实例 → resume 全链路（AC-1/AC-2）', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_resume');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.recordSession(
        target: _target('d1'),
        title: '短剧 · 第2集',
        mediaUrl: 'http://192.168.1.10/2.m3u8',
        positionMs: 95000,
      );

      final store2 = await _newStore(dir);
      final transport = FakeTransport();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: store2,
      );
      final ok = await controller.resumeLastSession();
      expect(ok, isTrue);
      expect(transport.calls.first,
          startsWith('setUri:http://192.168.1.10/2.m3u8'));
      expect(transport.calls, contains('seek:0:01:35.000000'));
      // 恢复成功后重写记录：同 URL 同标题，位置保留。
      expect(store2.lastSession?.mediaUrl, 'http://192.168.1.10/2.m3u8');
      expect(store2.lastSession?.positionMs, 95000);
      controller.dispose();
    });

    test('恢复成功位置 ≤3s：只有 setUri + play，不 seek', () async {
      final transport = FakeTransport();
      final controller = CastController(transportFactory: (_) => transport);
      controller.sessionRecorder = _MemoryRecorder()
        ..lastSession = CastSessionRecord(
          targetPersistJson: _target('d1').toPersistJson(),
          title: 't',
          mediaUrl: 'http://192.168.1.10/1.mp4',
          positionMs: 2000,
          endedAt: DateTime.now(),
        );
      await controller.resumeLastSession();
      expect(transport.calls, contains('play'));
      expect(transport.calls.where((c) => c.startsWith('seek')), isEmpty);
      controller.dispose();
    });

    test('无记录 / 损坏目标 / 空 URL → false（R1.4）', () async {
      final controller =
          CastController(transportFactory: (_) => FakeTransport());
      expect(await controller.resumeLastSession(), isFalse,
          reason: '未注入 recorder');
      controller.sessionRecorder = _MemoryRecorder();
      expect(await controller.resumeLastSession(), isFalse, reason: '无记录');
      controller.sessionRecorder = _MemoryRecorder()
        ..lastSession = CastSessionRecord(
          targetPersistJson: <String, dynamic>{
            'protocol': 'dlna',
            'udn': '',
            'control_url': '',
          },
          title: 't',
          mediaUrl: 'http://x/1.mp4',
          endedAt: DateTime.now(),
        );
      expect(await controller.resumeLastSession(), isFalse,
          reason: '目标无法重建');
      controller.sessionRecorder = _MemoryRecorder()
        ..lastSession = CastSessionRecord(
          targetPersistJson: _target('d1').toPersistJson(),
          title: 't',
          mediaUrl: '',
          endedAt: DateTime.now(),
        );
      expect(await controller.resumeLastSession(), isFalse, reason: '空 URL');
      controller.dispose();
    });

    test('恢复失败（设备未响应）：异常上抛、状态回 idle、记录保留可重试（R1.3）',
        () async {
      final transport = FakeTransport()..setUriError = SoapException('设备未响应');
      final recorder = _MemoryRecorder()
        ..lastSession = CastSessionRecord(
          targetPersistJson: _target('d1').toPersistJson(),
          title: 't',
          mediaUrl: 'http://192.168.1.10/1.m3u8',
          positionMs: 5000,
          endedAt: DateTime.now(),
        );
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      await expectLater(
        controller.resumeLastSession(),
        throwsA(isA<SoapException>()),
      );
      expect(controller.state, CastSessionState.idle);
      expect(recorder.lastSession, isNotNull, reason: '失败不删记录（电视开机后可重试）');
      controller.dispose();
    });
  });

  group('损坏 JSON 清理（AC-3/R1.4）', () {
    test('结构损坏（缺字段）：载入即静默清理内存与落盘键', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_bad1');
      addTearDown(() => dir.delete(recursive: true));
      _castFile(dir).writeAsStringSync(
        '{"version":4,"lastDevice":{"udn":"u1","name":"x","control_url":"http://a/c","location":"http://a/d"},"lastSession":{"broken":true}}',
      );
      final store = await _newStore(dir);
      expect(store.lastSession, isNull);
      expect(store.lastDevice?.id, 'u1', reason: '设备记忆不受影响');

      final reread =
          jsonDecode(_castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(reread.containsKey('lastSession'), isFalse, reason: '落盘键已清理');
      expect(reread['version'], 4);
    });

    test('lastSession 非对象（数组/字符串）：清理', () async {
      for (final raw in [
        '{"version":4,"lastSession":[]}',
        '{"version":4,"lastSession":"junk"}',
      ]) {
        final dir =
            await Directory.systemTemp.createTemp('cast_session_bad2');
        addTearDown(() => dir.delete(recursive: true));
        _castFile(dir).writeAsStringSync(raw);
        final store = await _newStore(dir);
        expect(store.lastSession, isNull, reason: raw);
        final reread = jsonDecode(_castFile(dir).readAsStringSync())
            as Map<String, dynamic>;
        expect(reread.containsKey('lastSession'), isFalse, reason: raw);
      }
    });

    test('目标无法重建（controlUrl 为空）：记录清理', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_bad3');
      addTearDown(() => dir.delete(recursive: true));
      _castFile(dir).writeAsStringSync(
        '{"version":4,"lastSession":{"targetPersistJson":{"protocol":"dlna","udn":"u1","control_url":""},"title":"t","mediaUrl":"http://x/1.mp4","positionMs":1,"endedAt":1730000000000}}',
      );
      final store = await _newStore(dir);
      expect(store.lastSession, isNull);
      final reread =
          jsonDecode(_castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(reread.containsKey('lastSession'), isFalse);
    });

    test('mediaUrl 为空：记录清理', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_bad4');
      addTearDown(() => dir.delete(recursive: true));
      _castFile(dir).writeAsStringSync(
        '{"version":4,"lastSession":{"targetPersistJson":{"protocol":"dlna","udn":"u1","control_url":"http://a/c"},"title":"t","mediaUrl":"","endedAt":1730000000000}}',
      );
      final store = await _newStore(dir);
      expect(store.lastSession, isNull);
    });

    test('备份导出不含 lastSession，其它键原样（R1 约束）', () async {
      final dir = await Directory.systemTemp.createTemp('cast_session_backup');
      addTearDown(() => dir.delete(recursive: true));
      final store = await _newStore(dir);
      await store.recordSession(
        target: _target('u1'),
        title: 't',
        mediaUrl: 'http://example.com/1.m3u8',
      );
      await store.touchLast(_target('u1'));
      final data = await store.exportData();
      expect(data.containsKey('lastSession'), isFalse);
      expect(data.containsKey('lastDevice'), isTrue);
      expect(data.containsKey('pinned'), isTrue);
      // 落盘文件本身仍保留（本机恢复可用）。
      expect(_castFile(dir).readAsStringSync(), contains('lastSession'));
    });
  });

  group('恢复卡片显示/隐藏（AC-4）', () {
    final target = _target('u1');
    CastSessionRecord record(DateTime endedAt) => CastSessionRecord(
          targetPersistJson: target.toPersistJson(),
          title: '第3集',
          mediaUrl: 'http://x/3.mp4',
          endedAt: endedAt,
        );

    test('有记录且空闲 → 显示', () {
      expect(
        castResumeCardVisible(record: record(DateTime(2026, 11, 7)), sessionIdle: true),
        isTrue,
      );
    });

    test('无记录 → 隐藏', () {
      expect(
        castResumeCardVisible(record: null, sessionIdle: true),
        isFalse,
      );
    });

    test('有活动会话 → 隐藏', () {
      expect(
        castResumeCardVisible(record: record(DateTime(2026, 11, 7)), sessionIdle: false),
        isFalse,
      );
    });

    test('记录损坏（目标无法重建）→ 隐藏', () {
      final broken = CastSessionRecord(
        targetPersistJson: const {'protocol': 'dlna', 'udn': '', 'control_url': ''},
        title: 't',
        mediaUrl: 'http://x/1.mp4',
        endedAt: DateTime(2026, 11, 7),
      );
      expect(
        castResumeCardVisible(record: broken, sessionIdle: true),
        isFalse,
      );
    });

    test('文案格式：「上次投到 <设备名>：<标题>（HH:mm）· 恢复」', () {
      final r = record(DateTime(2026, 11, 7, 21, 5));
      expect(
        castResumeCardText(record: r, target: target),
        '上次投到 客厅电视：第3集（21:05）· 恢复',
      );
      final r2 = record(DateTime(2026, 11, 7, 9, 8));
      expect(
        castResumeCardText(record: r2, target: target),
        '上次投到 客厅电视：第3集（09:08）· 恢复',
      );
    });
  });

  // 注意：本组必须在文件最后——ensureInitialized 的测试绑定会接管
  // HttpClient，污染同 isolate 里后续测试的原始网络请求。镜像会话的
  // dispose 路径会触到 MirrorController（MethodChannel），需要测试绑定
  //（同 cast_controller_test 的镜像组约定）。
  group('镜像会话不记录（AC-3/R1.3；文件末尾：需要测试绑定）', () {
    test('castTo 成功也不写恢复记录，断开也不动记录', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final transport = FakeTransport();
      final recorder = _MemoryRecorder();
      final controller = CastController(
        transportFactory: (_) => transport,
        sessionRecorder: recorder,
      );
      await controller.castTo(
        _target('d1'),
        const CastMedia(
            url: 'http://192.168.1.5:18380/stream.ts', title: '屏幕镜像', isMirror: true),
      );
      expect(controller.state, CastSessionState.casting);
      expect(recorder.calls.where((c) => c.startsWith('record')), isEmpty);
      expect(recorder.lastSession, isNull);
      await controller.disconnect();
      expect(recorder.calls, isNot(contains('ended')), reason: '未记录的会话收尾不触发 endedAt 更新');
      expect(recorder.lastSession, isNull);
      controller.dispose();
    });
  });
}
