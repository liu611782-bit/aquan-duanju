import 'package:aquan_duanju/core/castd/receiver_admission.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_service.dart';
import 'package:aquan_duanju/widgets/cast_receiver_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('CastReceiverTile：非桌面平台整块隐藏（B-4 守卫）', (tester) async {
    final service = CastReceiverService.forTest(
      controller: ReceiverController(playerOverride: StubReceiverPlayer()),
    );
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CastReceiverTile(supported: false, service: service),
      ),
    ));
    expect(find.text('允许其他设备投到本机'), findsNothing);
  });

  testWidgets('CastReceiverTile：开关状态与 start/stop 联动，副标题显示端口', (tester) async {
    final stub = StubReceiverPlayer();
    final controller = ReceiverController(
      playerOverride: stub,
      udnSeed: 'udn-tile-1',
      enableSsdp: false,
    );
    final service = CastReceiverService.forTest(controller: controller);
    addTearDown(() => service.setEnabled(false));
    final persisted = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CastReceiverTile(
          service: service,
          supported: true,
          onPersistEnabled: persisted.add,
          receiverName: '我的接收名',
        ),
      ),
    ));

    // 默认关。
    Switch switchWidget() => tester.widget<Switch>(find.byType(Switch));
    expect(find.text('允许其他设备投到本机'), findsOneWidget);
    expect(switchWidget().value, isFalse);

    // 开关切换走真实 loopback HTTP（SSDP 关闭）：tap 后先放行真实异步
    // I/O（pumpAndSettle 只等帧，不等 socket），再断言。
    Future<void> toggleAndWait() async {
      await tester.tap(find.byType(Switch));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
      await tester.pumpAndSettle();
    }

    // 开：start 生效，副标题带接收名与端口。
    await toggleAndWait();
    expect(service.enabled, isTrue);
    expect(controller.running, isTrue);
    expect(switchWidget().value, isTrue);
    expect(persisted, [true]);
    expect(find.textContaining('我的接收名'), findsOneWidget);
    expect(find.textContaining('端口'), findsOneWidget);

    // 关：stop 生效 + 引擎 Stop（B-3）。
    await toggleAndWait();
    expect(service.enabled, isFalse);
    expect(controller.running, isFalse);
    expect(stub.stopCount, 1);
    expect(persisted, [true, false]);
  });

  testWidgets('CastReceiverTile：启动失败 → 开关回弹 + 固定中文提示', (tester) async {
    // 确定性失败：setEnabled(true) 直接抛（端口/网络类故障在真实环境
    // 由 ErrorLog 记录，这里只验证 UI 回弹与提示）。
    final service = _FailingReceiverService();
    final persisted = <bool>[];

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CastReceiverTile(
          service: service,
          supported: true,
          onPersistEnabled: persisted.add,
        ),
      ),
    ));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(service.enabled, isFalse);
    expect(persisted, [true, false], reason: '启动失败回滚持久化');
    expect(find.text('接收端启动失败，请稍后再试'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('CastReceiverTile：投送准入三选生效；管理允许列表可删可清', (tester) async {
    final service = CastReceiverService.forTest(
      controller: ReceiverController(playerOverride: StubReceiverPlayer()),
    );
    service.admission.allowDevice('192.168.1.9', userAgent: 'Bidebar/1.0');
    service.admission.denyDevice('192.168.1.10', userAgent: 'handset/1');
    final modes = <String>[];
    var listsChanged = 0;

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CastReceiverTile(
          service: service,
          supported: true,
          admissionMode: 'anyone',
          onAdmissionModeChanged: modes.add,
          onAdmissionListsChanged: (_, __) => listsChanged++,
        ),
      ),
    ));

    // 设置页形态两行常驻（开关不开也有）：三选 + 管理入口。
    expect(find.text('投送准入'), findsOneWidget);
    expect(find.text('管理允许列表'), findsOneWidget);
    expect(find.text('任何人可投'), findsOneWidget);

    // 三选：选「每次询问」→ 运行态写策略 + 落盘回调。
    await tester.tap(find.text('投送准入'));
    await tester.pumpAndSettle();
    expect(find.textContaining('仅允许列表'), findsOneWidget);
    await tester.tap(find.textContaining('每次询问'));
    await tester.pumpAndSettle();
    expect(service.admission.mode, ReceiverAdmissionMode.ask);
    expect(modes, ['ask']);

    // 管理允许列表：允许/拒绝两个分区都显示，条目带 IP/UA。
    await tester.tap(find.text('管理允许列表'));
    await tester.pumpAndSettle();
    expect(find.text('允许名单（1）'), findsOneWidget);
    expect(find.text('拒绝名单（每次询问记住）（1）'), findsOneWidget);
    expect(find.text('192.168.1.9'), findsOneWidget);
    expect(find.textContaining('Bidebar/1.0'), findsOneWidget);

    // 单删允许条目 → 策略变化 + 落盘回调。
    await tester.tap(find.byTooltip('删除此条目').first);
    await tester.pumpAndSettle();
    expect(service.admission.allowEntries, isEmpty);
    expect(listsChanged, 1);
    expect(find.text('允许名单（1）'), findsNothing);

    // 清空拒绝名单。
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(service.admission.denyEntries, isEmpty);
    expect(listsChanged, 2);
    expect(find.text('暂无记录。开启「每次询问」后，勾选「记住此设备」的设备会出现在这里'),
        findsOneWidget);
  });
}

/// 开关打开即抛异常的替身（确定性失败注入）。
class _FailingReceiverService extends CastReceiverService {
  _FailingReceiverService()
      : super.forTest(controller: ReceiverController(enableSsdp: false));

  @override
  Future<bool> setEnabled(bool value, {String? name}) async {
    if (!value) return false;
    throw Exception('模拟端口绑定失败');
  }
}
