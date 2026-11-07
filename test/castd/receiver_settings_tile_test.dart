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
