/// Android 接收端平台桥 + 门面平台分支单测（R1.4 / A-6）。
///
/// 口径：测试宿主（flutter_tester）无法改 `Platform.isAndroid`，Android 分支
/// 经 `CastReceiverService.forTest(androidBridge: …)` 注入替身覆盖；真桥的
/// 通道收发用 mock messenger 验证（不依赖真通道 / 真设备）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/castd/receiver_android_bridge.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_service.dart';
import 'package:aquan_duanju/widgets/cast_receiver_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _castChannel = MethodChannel('aquan/cast');
const _castdChannel = MethodChannel('aquan/castd');

/// 桥替身：三态可编程（null=成功 / Exception=失败 / MissingPluginException=
/// 未实现），全路径记录调用。
class FakeBridge extends ReceiverAndroidBridge {
  FakeBridge({this.startError});

  /// 非 null → receiverStart 抛该错误。
  final Object? startError;

  final startedPorts = <int?>[];
  final titles = <String?>[];
  int startCount = 0;
  int stopCount = 0;

  @override
  Future<int?> receiverStart({int? port}) async {
    startCount++;
    startedPorts.add(port);
    final error = startError;
    if (error != null) throw error;
    return port;
  }

  @override
  Future<void> receiverStop() async {
    stopCount++;
  }

  @override
  Future<void> pushSessionTitle(String? title) async {
    titles.add(title);
  }

  /// 测试直触 receiverPause 事件回调（模拟 Kotlin→Dart 音频焦点被抢占）。
  Future<void> simulatePause() async {
    await onPauseRequested?.call();
  }
}

ReceiverController _controller(StubReceiverPlayer stub) => ReceiverController(
      playerOverride: stub,
      udnSeed: 'udn-bridge',
      enableSsdp: false,
    );

/// 用原始 socket POST 一发 SetAVTransportURI（真实 loopback HTTP）。
///
/// 不走 SoapClient：本文件为验 mock messenger 装了 TestWidgetsFlutterBinding，
/// 该绑定会把所有 HttpClient 劫持成 400 回包（Socket.connect / HttpServer
/// 不受影响）；参数转义口径与 SoapClient 相同（DIDL 作为 XML 参数转义）。
Future<void> postSetUri(ReceiverController controller,
    {required String url, required String title}) async {
  const serviceType = 'urn:schemas-upnp-org:service:AVTransport:1';
  String escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');
  final body = '<s:Envelope '
      'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:SetAVTransportURI xmlns:u="$serviceType">'
      '<InstanceID>0</InstanceID>'
      '<CurrentURI>${escape(url)}</CurrentURI>'
      '<CurrentURIMetaData>${escape(buildDidlLite(title: title))}</CurrentURIMetaData>'
      '</u:SetAVTransportURI></s:Body></s:Envelope>';
  final payload = 'POST /AVTransport/control HTTP/1.1\r\n'
      'Host: 127.0.0.1:${controller.port}\r\n'
      'Content-Type: text/xml; charset="utf-8"\r\n'
      'SOAPACTION: "$serviceType#SetAVTransportURI"\r\n'
      'Content-Length: ${utf8.encode(body).length}\r\n'
      'Connection: close\r\n\r\n$body';
  final socket = await Socket.connect('127.0.0.1', controller.port!);
  try {
    socket.add(utf8.encode(payload));
    await socket.flush();
    final reply = await socket.cast<List<int>>().transform(utf8.decoder).join();
    expect(reply, contains('200'), reason: 'SetAVTransportURI 应成功');
  } finally {
    socket.destroy();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ReceiverAndroidBridge（真桥 + mock messenger，不依赖真通道）', () {
    test('receiverStart 传端口并回显；receiverStop / setSessionMeta 参数正确', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, (call) async {
        calls.add(call);
        if (call.method == 'receiverStart') {
          return (call.arguments as Map)['port'] as int;
        }
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, null));

      final bridge = ReceiverAndroidBridge();
      expect(await bridge.receiverStart(port: 18123), 18123);
      await bridge.pushSessionTitle('第 1 集');
      await bridge.receiverStop();

      expect(
        calls.map((c) => c.method).toList(),
        ['receiverStart', 'setSessionMeta', 'receiverStop'],
      );
      expect(calls[0].arguments, {'port': 18123});
      expect(calls[1].arguments, {'title': '第 1 集'});
    });

    test('receiverPause 事件（aquan/castd）→ onPauseRequested 回调', () async {
      final bridge = ReceiverAndroidBridge();
      var pauses = 0;
      bridge.onPauseRequested = () async => pauses++;
      bridge.listen();

      // 模拟 Kotlin→Dart 事件（mirror_controller_test 的 pushEvent 口径）。
      final codec = _castdChannel.codec;
      final encoded = codec.encodeMethodCall(const MethodCall('receiverPause'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(_castdChannel.name, encoded, (_) {});
      expect(pauses, 1);

      // 非 receiverPause 事件静默忽略。
      final other = codec.encodeMethodCall(const MethodCall('other'));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(_castdChannel.name, other, (_) {});
      expect(pauses, 1);
    });

    test('未实现：receiverStart 原样抛 MissingPluginException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, (call) async {
        throw MissingPluginException(call.method);
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, null));
      final bridge = ReceiverAndroidBridge();
      await expectLater(
        bridge.receiverStart(port: 1),
        throwsA(isA<MissingPluginException>()),
      );
    });

    test('receiverStop / pushSessionTitle 失败静默（尽力而为，不上抛）', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, (call) async {
        throw Exception('boom');
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_castChannel, null));
      final bridge = ReceiverAndroidBridge();
      await bridge.receiverStop();
      await bridge.pushSessionTitle('x');
    });
  });

  group('CastReceiverService × Android 桥（三态回滚，R1.4）', () {
    test('成功：接收端运行 + 前台服务带端口起 + 来投推标题；关闭停服务', () async {
      final stub = StubReceiverPlayer();
      final controller = _controller(stub);
      final bridge = FakeBridge();
      final service = CastReceiverService.forTest(
        controller: controller,
        androidBridge: bridge,
      );
      addTearDown(() => service.setEnabled(false));

      expect(await service.setEnabled(true, name: '客厅接收'), isTrue);
      expect(controller.running, isTrue);
      expect(service.enabled, isTrue);
      expect(bridge.startCount, 1);
      expect(bridge.startedPorts.single, controller.port,
          reason: '前台服务启动应携带 Dart HTTP 监听端口');

      // 来投 → 通知栏标题推送（真 loopback SOAP，口径同 receiver_service_test）。
      await postSetUri(
        controller,
        url: 'http://192.168.1.9:18280/p/tok1/e1.mp4',
        title: '第 1 集',
      );
      expect(bridge.titles, ['第 1 集']);

      await service.setEnabled(false);
      expect(controller.running, isFalse);
      expect(bridge.stopCount, 1);
      expect(stub.stopCount, 1, reason: '关闭路径照旧停引擎');
      expect(service.session.value, isNull);
    });

    test('失败：回滚已起的接收端栈（controller 停止）并上抛', () async {
      final controller = _controller(StubReceiverPlayer());
      final service = CastReceiverService.forTest(
        controller: controller,
        androidBridge:
            FakeBridge(startError: Exception('前台服务启动失败')),
      );

      await expectLater(service.setEnabled(true), throwsA(isA<Exception>()));
      expect(controller.running, isFalse, reason: '桥失败必须回滚本地栈');
      expect(service.enabled, isFalse);
      expect(service.session.value, isNull);
      expect(controller.port, isNull, reason: 'HTTP/SSDP 栈已随回滚下线');
    });

    test('未实现（MissingPluginException）：同样回滚并上抛', () async {
      final controller = _controller(StubReceiverPlayer());
      final service = CastReceiverService.forTest(
        controller: controller,
        androidBridge:
            FakeBridge(startError: MissingPluginException('receiverStart')),
      );

      await expectLater(
        service.setEnabled(true),
        throwsA(isA<MissingPluginException>()),
      );
      expect(controller.running, isFalse);
      expect(service.enabled, isFalse);
    });

    test('receiverPause 事件 → 引擎 pause（PAUSED_PLAYBACK，恢复不自动续播）', () async {
      final stub = StubReceiverPlayer();
      final controller = _controller(stub);
      final bridge = FakeBridge();
      final service = CastReceiverService.forTest(
        controller: controller,
        androidBridge: bridge,
      );
      addTearDown(() => service.setEnabled(false));
      await service.setEnabled(true);

      stub.state = kTransportPlaying;
      await bridge.simulatePause();
      expect(stub.pauseCount, 1);
      expect(stub.status().transportState, kTransportPaused);

      // 焦点回归不自动续播（R1.3：恢复靠用户手动 / 发送端 Play）。
      await Future<void>.delayed(Duration.zero);
      expect(stub.playCount, 0);
      expect(stub.status().transportState, kTransportPaused);
    });
  });

  group('平台分支矩阵（R1.4）', () {
    test('receiverPlatformSupported = 桌面 ∨ Android（守卫纯函数）', () {
      // flutter_tester 宿主不可改 Platform 布尔：桌面分支在宿主上直接验证，
      // Android 分支由 forTest 注入桥的路径覆盖（生产 Android 上必为 true）。
      final desktop =
          Platform.isWindows || Platform.isMacOS || Platform.isLinux;
      expect(
        receiverPlatformSupported(),
        desktop || Platform.isAndroid,
        reason: '守卫表达式必须是「桌面 ∨ Android」',
      );
    });

    test('platformSupportedForTest 覆盖判定（模拟 Android 可用 / iOS 隐藏）', () {
      final original = CastReceiverService.platformSupportedForTest;
      addTearDown(() => CastReceiverService.platformSupportedForTest = original);
      CastReceiverService.platformSupportedForTest = true;
      expect(CastReceiverService.platformSupported, isTrue);
      CastReceiverService.platformSupportedForTest = false;
      expect(CastReceiverService.platformSupported, isFalse);
    });
  });

  testWidgets('CastReceiverTile：Android 桥失败 → 开关回滚 + 固定中文提示', (tester) async {
    final controller = _controller(StubReceiverPlayer());
    final service = CastReceiverService.forTest(
      controller: controller,
      androidBridge:
          FakeBridge(startError: MissingPluginException('receiverStart')),
    );
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

    // tap 后先放行真实异步 I/O（controller.start 绑定真实端口，桥才失败），
    // 再断言回滚（同 receiver_settings_tile_test 口径）。
    await tester.tap(find.byType(Switch));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle();

    expect(controller.running, isFalse, reason: 'Android 桥失败回滚本地栈');
    expect(persisted, [true, false], reason: '启动失败回滚持久化');
    expect(find.text('接收端启动失败，请稍后再试'), findsOneWidget);
  });
}
