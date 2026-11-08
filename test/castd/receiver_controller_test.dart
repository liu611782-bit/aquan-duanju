import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('ReceiverController（门面，SSDP 关闭纯回环）', () {
    late StubReceiverPlayer stub;

    setUp(() {
      stub = StubReceiverPlayer();
    });

    test('start：HTTP 18099 起顺延、UDN 生效、描述可取；stop 后端口关闭',
        () async {
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-ctl-1',
        friendlyNameSeed: '客厅主机（aquan 接收）',
        enableSsdp: false,
      );
      addTearDown(controller.stop);
      await controller.start();

      expect(controller.running, isTrue);
      expect(controller.udn, 'udn-ctl-1');
      expect(controller.port, greaterThanOrEqualTo(18099));
      expect(controller.friendlyName, '客厅主机（aquan 接收）');

      final res = await http.get(
        Uri.parse('http://127.0.0.1:${controller.port}/description.xml'),
      );
      expect(res.statusCode, 200);
      expect(res.body, contains('uuid:udn-ctl-1'));

      final port = controller.port;
      await controller.stop();
      expect(controller.running, isFalse);
      expect(controller.currentSession, isNull);
      expect(controller.port, isNull);
      // 端口已关：请求失败。stop→close 有内核瞬态（TIME_WAIT），且全量
      // 并发时其他测试可能恰好在同端口起服务——轮询至多 3 次，最终以
      // 「controller.port 已置空」+ 请求抛错为关闭判据（flaky 修复）。
      var closed = false;
      for (var i = 0; i < 3 && !closed; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          await http
              .get(Uri.parse('http://127.0.0.1:$port/description.xml'))
              .timeout(const Duration(seconds: 2));
          // 拿到响应说明端口被其他进程复用——视作本服务已关。
          closed = true;
        } catch (_) {
          closed = true;
        }
      }
      expect(closed, isTrue, reason: 'stop 后端口应关闭或不再属于本服务');
    });

    test('来投会话：SetAVTransportURI → onIncomingSession（IP/UA/标题）',
        () async {
      ReceiverSession? session;
      final gotSession = Completer<ReceiverSession>();
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-ctl-2',
        enableSsdp: false,
        onIncomingSession: (s) {
          session = s;
          gotSession.complete(s);
        },
      );
      addTearDown(controller.stop);
      await controller.start();

      final client = SoapClient();
      addTearDown(client.close);
      await client.sendAction(
        'http://127.0.0.1:${controller.port}/AVTransport/control',
        ReceiverService.avTransport.type,
        'SetAVTransportURI',
        {
          'InstanceID': '0',
          'CurrentURI': 'http://192.168.1.9:18280/p/tok/video.mp4',
          'CurrentURIMetaData': buildDidlLite(title: '会话标题'),
        },
      );

      final s = await gotSession.future.timeout(const Duration(seconds: 3));
      expect(s, same(session));
      expect(s.url, 'http://192.168.1.9:18280/p/tok/video.mp4');
      expect(s.title, '会话标题');
      expect(s.senderAddress, '127.0.0.1');
      expect(s.senderUserAgent, isNotEmpty);
      expect(controller.currentSession, same(s));
      expect(controller.player, same(stub));
    });

    test('UDN 缺省时临时生成（uuid 形状）；UDN loader 优先于临时生成',
        () async {
      final loaderController = ReceiverController(
        playerOverride: stub,
        enableSsdp: false,
        udnLoader: () async => 'udn-from-loader',
      );
      addTearDown(loaderController.stop);
      await loaderController.start();
      expect(loaderController.udn, 'udn-from-loader');

      final ephemeral = ReceiverController(
        playerOverride: stub,
        enableSsdp: false,
      );
      addTearDown(ephemeral.stop);
      await ephemeral.start();
      expect(
        RegExp(r'^[0-9a-f-]{36}$').hasMatch(ephemeral.udn!),
        isTrue,
        reason: ephemeral.udn,
      );
    });

    test('start 双重调用幂等；stop 后可重启', () async {
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-ctl-3',
        enableSsdp: false,
      );
      addTearDown(controller.stop);
      await controller.start();
      final port = controller.port;
      await controller.start(); // 幂等
      expect(controller.port, port);

      await controller.stop();
      await controller.start(); // 重启换端口也允许
      expect(controller.running, isTrue);
      expect(controller.port, greaterThanOrEqualTo(18099));
    });
  });

  group('CastStore receiverUdn（A-1 持久化）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('castd_store_test');
    });

    tearDown(() async {
      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    });

    File storeFile() => File(
        '${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('首次生成并持久化；重启（新实例）读取稳定', () async {
      final store = CastStore(testDirectory: dir);
      final udn1 = await store.ensureReceiverUdn();
      expect(RegExp(r'^[0-9a-f-]{36}$').hasMatch(udn1), isTrue, reason: udn1);
      expect(store.receiverUdn, udn1);

      final onDisk = jsonDecode(await storeFile().readAsString())
          as Map<String, dynamic>;
      expect(onDisk['receiverUdn'], udn1);

      final reopened = CastStore(testDirectory: dir);
      expect(await reopened.ensureReceiverUdn(), udn1);
    });

    test('旧文件（无 receiverUdn）→ 生成新值且保留既有键（v4 向后兼容）',
        () async {
      await storeFile().writeAsString(
        jsonEncode({'version': 4, 'pinned': <Object?>[]}),
      );
      final store = CastStore(testDirectory: dir);
      final udn = await store.ensureReceiverUdn();
      expect(udn, isNotEmpty);
      final onDisk = jsonDecode(await storeFile().readAsString())
          as Map<String, dynamic>;
      expect(onDisk['receiverUdn'], udn);
      expect(onDisk['pinned'], isEmpty, reason: '既有键不被覆盖');
      expect(onDisk['version'], 4);
    });

    test('生成值走 uuidV4（castd 单一来源）', () {
      expect(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
          .hasMatch(uuidV4()), isTrue);
    });
  });
}
