import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/widgets/cast_panel.dart';

/// 会话抽屉（_CastSessionSheet）交互 widget 测试（R2，11-07-cast-reliability）。
///
/// 搭建方式参照 cast_session_resume_test：真 CastController + 注入的假
/// transport 工厂驱动到 casting 态，经 [castSessionSheetForTest] 构造抽屉
/// （库私有类的测试注入点）。覆盖面为 UI 层此前仅靠控制器级测试的部分：
/// 进度条拖动（乐观 seek / 失败回读+提示）、上下集按钮（调用与置灰态）、
/// 静音乐观切换。

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
    );

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

const CastMedia _media1 =
    CastMedia(url: 'http://192.168.1.10/1.mp4', title: '测试 · 第1集');
const CastMedia _media2 =
    CastMedia(url: 'http://192.168.1.10/2.mp4', title: '测试 · 第2集');

/// 假 transport：脚本化 poll 结果与故障注入（与 cast_session_resume_test
/// 同款，另补 seek/静音故障与 poll 计数）。
class FakeTransport implements CastTransport {
  FakeTransport();

  final List<String> calls = [];
  final List<bool> mutes = [];
  int pollCount = 0;
  CastPoll pollResult =
      const CastPoll(transportState: 'RUNNING', position: Duration(seconds: 30));
  Object? seekError;
  Object? muteError;

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
  Future<void> seekTo(Duration position) async {
    calls.add('seek:$position');
    if (seekError != null) throw seekError!;
  }

  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');

  @override
  Future<void> setMute(bool muted) async {
    mutes.add(muted);
    if (muteError != null) throw muteError!;
  }

  @override
  Future<CastPoll> poll() async {
    pollCount++;
    return pollResult;
  }

  @override
  void close() {}
}

/// 搭建 casting 态控制器 + 泵抽屉，跑完断言后在测试体内 dispose（轮询
/// Timer 必须在用例结束前取消，否则 pending-timer 断言先于 addTearDown）。
Future<void> _withSheet(
  WidgetTester tester,
  FakeTransport transport,
  Future<void> Function(CastController controller, FakeTransport transport)
      body, {
  void Function(CastController controller)? setup,
}) async {
  final controller = CastController(transportFactory: (_) => transport);
  try {
    // 连播/跳集队列在生产里于发起投屏时注入（先注入再 castTo）。
    setup?.call(controller);
    await controller.castTo(_target('d1'), _media1);
    // 驱动一次轮询：远端回报位置/时长（进度条仅在有真实时长时渲染）。
    transport.pollResult = const CastPoll(
      transportState: 'PLAYING',
      position: Duration(seconds: 30),
      duration: Duration(seconds: 100),
    );
    await controller.forceRefresh();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: castSessionSheetForTest(controller: controller),
      ),
    ));
    await tester.pump();
    await body(controller, transport);
  } finally {
    controller.dispose();
  }
}

/// 进度条 Slider（max = 时长秒数 100；音量条 max 恒为 1.0）。
Slider _progressSlider(WidgetTester tester) => tester.widget<Slider>(
    find.byWidgetPredicate((w) => w is Slider && w.max > 1));

void main() {
  group('进度条拖动（R2）', () {
    testWidgets('onChangeEnd → seekTo(拖动乐观值)，拖动中显示乐观位置不回跳',
        (tester) async {
      await _withSheet(tester, FakeTransport(), (controller, transport) async {
        // 初始位置 30s。
        expect(find.text('00:30'), findsWidgets);

        final slider = _progressSlider(tester);
        slider.onChangeStart!(30.0);
        await tester.pump();
        slider.onChanged!(50.0);
        await tester.pump();
        // 拖动中：乐观值 00:50，轮询值 00:30 不再显示。
        expect(find.text('00:50'), findsWidgets);
        expect(find.text('00:30'), findsNothing);

        slider.onChangeEnd!(50.0);
        await tester.pump();
        await tester.pump();

        // seekTo 收到的是拖动乐观值（秒）；松手后乐观对齐保留。
        expect(transport.calls.last, 'seek:0:00:50.000000');
        expect(find.text('00:50'), findsWidgets,
            reason: '松手后乐观对齐保留（等下一次轮询校正）');
      });
    });

    testWidgets('seekTo 抛异常 → forceRefresh 回读真实位置 + 固定提示',
        (tester) async {
      final transport = FakeTransport()..seekError = Exception('Seek 401');
      await _withSheet(tester, transport, (controller, transport) async {
        final pollsBefore = transport.pollCount;

        final slider = _progressSlider(tester);
        slider.onChangeEnd!(50.0);
        await tester.pump();
        await tester.pump();

        // 失败提示（固定文案）。
        expect(find.text('该设备不支持拖动进度'), findsOneWidget);
        // 回读：失败后立即轮询一次真实位置。
        expect(transport.pollCount, greaterThan(pollsBefore),
            reason: 'seek 失败必须 forceRefresh 回读');
        // 面板位置回到电视真实值（不漂移到乐观值）。
        expect(find.text('00:30'), findsWidgets);
        expect(find.text('00:50'), findsNothing);
        expect(controller.remotePosition.inSeconds, 30,
            reason: '回读后位置回到电视真实值（插值仅毫秒级抖动）');
      });
    });
  });

  group('上一集/下一集按钮（R2）', () {
    testWidgets('回调未注入 → 两按钮置灰', (tester) async {
      await _withSheet(tester, FakeTransport(), (controller, transport) async {
        expect(
          tester.widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '上一集'))
              .onPressed,
          isNull,
          reason: 'onEpisodeJump 未注入时上一集置灰',
        );
        expect(
          tester.widget<OutlinedButton>(
                  find.widgetWithText(OutlinedButton, '下一集'))
              .onPressed,
          isNull,
          reason: 'onNextEpisode 未注入时下一集置灰',
        );
      });
    });

    testWidgets('下一集 → advanceNextEpisode（连投链路推送 setUri+play，会话保持）',
        (tester) async {
      final transport = FakeTransport();
      await _withSheet(tester, transport, (controller, transport) async {
        await tester.tap(find.widgetWithText(OutlinedButton, '下一集'));
        await tester.pump();
        await tester.pump();

        expect(transport.calls, contains('setUri:http://192.168.1.10/2.mp4'));
        expect(transport.calls.where((c) => c == 'play'), hasLength(2),
            reason: '换集在同一 transport 上重新 play（连投不回 idle）');
        expect(controller.state, CastSessionState.casting);
        expect(controller.currentMedia?.url, 'http://192.168.1.10/2.mp4');
      }, setup: (c) => c.onNextEpisode = () async => _media2);
    });

    testWidgets('上一集 → jumpEpisode(-1)（注入跳集队列后可点）', (tester) async {
      final transport = FakeTransport();
      final deltas = <int>[];
      await _withSheet(tester, transport, (controller, transport) async {
        await tester.tap(find.widgetWithText(OutlinedButton, '上一集'));
        await tester.pump();
        await tester.pump();

        expect(deltas, [-1], reason: '上一集固定传 delta=-1');
        expect(transport.calls, contains('setUri:http://192.168.1.10/2.mp4'));
        expect(controller.state, CastSessionState.casting);
      },
          setup: (c) =>
              c.onEpisodeJump = (delta) async {
                deltas.add(delta);
                return _media2;
              });
    });

    testWidgets('提供器返回 null（越界）→ 会话保持 + 固定文案提示', (tester) async {
      await _withSheet(tester, FakeTransport(), (controller, transport) async {
        await tester.tap(find.widgetWithText(OutlinedButton, '下一集'));
        await tester.pump();
        await tester.pump();
        expect(find.text('下一集不可用'), findsOneWidget);
        expect(controller.state, CastSessionState.casting,
            reason: '手动换集失败不归一为远端停止，会话保持');

        await tester.tap(find.widgetWithText(OutlinedButton, '上一集'));
        await tester.pump();
        await tester.pump();
        expect(find.text('上一集不可用'), findsOneWidget);
        expect(controller.state, CastSessionState.casting);
      },
          setup: (c) {
            c.onNextEpisode = () async => null;
            c.onEpisodeJump = (delta) async => null;
          });
    });
  });

  group('静音按钮（R2）', () {
    // 静音按钮（图标子级；音量条两端的 volume_up/down 小图标不在按钮内）。
    Finder muteButton() => find.ancestor(
          matching: find.byType(OutlinedButton),
          of: find.byWidgetPredicate((w) =>
              w is Icon &&
              (w.icon == Icons.volume_up || w.icon == Icons.volume_off)),
        );

    testWidgets('乐观切换：成功即翻图标并透传 setMute', (tester) async {
      final transport = FakeTransport();
      await _withSheet(tester, transport, (controller, transport) async {
        Icon muteIcon() => tester.widget<Icon>(find.descendant(
              of: muteButton(),
              matching: find.byType(Icon),
            ));
        expect(muteIcon().icon, Icons.volume_up, reason: '初始未静音');

        // 开静音：乐观切换（成功即翻，不等远端轮询对齐）。
        await tester.tap(muteButton());
        await tester.pump();
        await tester.pump();

        expect(transport.mutes, [true]);
        expect(muteIcon().icon, Icons.volume_off);

        // 再点取消静音。
        await tester.tap(muteButton());
        await tester.pump();
        await tester.pump();
        expect(transport.mutes, [true, false]);
        expect(muteIcon().icon, Icons.volume_up);
      });
    });

    testWidgets('setMute 抛异常（DLNA 无 RenderingControl）→ 吞掉且不翻图标',
        (tester) async {
      final transport = FakeTransport()..muteError = Exception('no RCS');
      await _withSheet(tester, transport, (controller, transport) async {
        Icon muteIcon() => tester.widget<Icon>(find.descendant(
              of: muteButton(),
              matching: find.byType(Icon),
            ));

        await tester.tap(muteButton());
        await tester.pump();
        await tester.pump();

        expect(transport.mutes, [true], reason: '调用已透传');
        expect(muteIcon().icon, Icons.volume_up, reason: '失败不乐观翻图标');
      });
    });
  });
}
