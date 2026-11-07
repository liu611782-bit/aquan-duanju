
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  group('CastReceiverService（开关/会话/页面导航，SSDP 关闭纯回环）', () {
    late StubReceiverPlayer stub;
    late ReceiverController controller;
    late CastReceiverService service;
    int udnLoads = 0;

    setUp(() {
      stub = StubReceiverPlayer();
      udnLoads = 0;
      controller = ReceiverController(
        playerOverride: stub,
        enableSsdp: false,
        // forTest 注入外部 controller：UDN loader 直接挂在 controller 上
        // （生产单例才经 service.udnLoader 延迟接线）。
        udnLoader: () async {
          udnLoads++;
          return 'udn-svc-1';
        },
      );
      service = CastReceiverService.forTest(controller: controller);
    });

    /// 用自家发送端 SOAP 语义投一集（真实 loopback HTTP）。
    Future<void> postSetUri(String url, String title) async {
      final client = SoapClient();
      try {
        await client.sendAction(
          'http://127.0.0.1:${controller.port}/AVTransport/control',
          ReceiverService.avTransport.type,
          'SetAVTransportURI',
          {
            'InstanceID': '0',
            'CurrentURI': url,
            'CurrentURIMetaData': buildDidlLite(title: title),
          },
        );
      } finally {
        client.close();
      }
    }

    test('setEnabled：开 → start + UDN loader + 名称生效；关 → 停止 + 引擎 Stop',
        () async {
      expect(service.enabled, isFalse);
      expect(await service.setEnabled(true, name: '客厅接收'), isTrue);
      expect(controller.running, isTrue);
      expect(service.enabled, isTrue);
      expect(controller.udn, 'udn-svc-1');
      expect(udnLoads, 1);
      expect(controller.friendlyName, '客厅接收');

      await service.setEnabled(false);
      expect(controller.running, isFalse);
      expect(service.enabled, isFalse);
      expect(service.port, isNull);
      expect(service.session.value, isNull);
      // B-3：开关关闭 → 引擎 Stop 语义（STOPPED，幂等可重复）。
      expect(stub.stopCount, 1);
      await service.setEnabled(false);
      expect(stub.stopCount, 1, reason: '关闭路径幂等，不重复 Stop 引擎');
    });

    test('来投：页未开 → openSessionPage 恰一次；新投替换 → 会话更新不重开页',
        () async {
      final opened = <ReceiverSession>[];
      service.openSessionPage = (s) {
        opened.add(s);
        return true;
      };
      await service.setEnabled(true, name: '客厅接收');
      addTearDown(() => service.setEnabled(false));

      await postSetUri('http://192.168.1.9:18280/p/tok1/e1.mp4', '第 1 集');
      expect(opened, hasLength(1));
      expect(
        service.session.value?.url,
        'http://192.168.1.9:18280/p/tok1/e1.mp4',
      );
      expect(service.session.value?.title, '第 1 集');

      // 新投替换：引擎换源（第二次 load），会话更新，页面不关不重开。
      await postSetUri('http://192.168.1.9:18280/p/tok2/e2.mp4', '第 2 集');
      expect(opened, hasLength(1), reason: '新投替换不关页也不重开页');
      expect(stub.loadCount, 2);
      expect(
        stub.loadedUri.toString(),
        'http://192.168.1.9:18280/p/tok2/e2.mp4',
      );
      expect(
        service.session.value?.url,
        'http://192.168.1.9:18280/p/tok2/e2.mp4',
      );
      expect(service.session.value?.title, '第 2 集');
    });

    test('页关闭后再来投 → 重新开页；开关关闭且页开着 → closeSessionPage',
        () async {
      var openCount = 0;
      var closeCount = 0;
      service.openSessionPage = (_) {
        openCount++;
        return true;
      };
      service.closeSessionPage = () => closeCount++;
      await service.setEnabled(true, name: '客厅接收');
      addTearDown(() => service.setEnabled(false));

      await postSetUri('http://192.168.1.9:18280/p/tok1/e1.mp4', '第 1 集');
      expect(openCount, 1);

      // 用户手动关页（播放页 dispose 回调）。
      service.notifyPageClosed();
      await postSetUri('http://192.168.1.9:18280/p/tok3/e3.mp4', '第 3 集');
      expect(openCount, 2, reason: '页已关闭，新会话应重开页');

      // 开关关闭且页开着 → 关页回调。
      await service.setEnabled(false);
      expect(closeCount, 1);
      expect(openCount, 2);
    });

    test('rename：运行中改名即时生效（描述 XML 下一次请求读到新名）', () async {
      await service.setEnabled(true, name: '');
      addTearDown(() => service.setEnabled(false));
      final defaultName = controller.friendlyName;
      expect(defaultName, isNotEmpty);

      service.rename('卧室主机（aquan 接收）');
      expect(controller.friendlyName, '卧室主机（aquan 接收）');
      final res =
          await http.get(Uri.parse('http://127.0.0.1:${controller.port}/description.xml'));
      expect(res.statusCode, 200);
      expect(res.body, contains('卧室主机（aquan 接收）'));

      service.rename('');
      expect(controller.friendlyName, defaultName);
    });
  });

  group('ReceiverController（Phase B 增量）', () {
    test('playerFactory：首次 start 才创建引擎；重启复用同一实例', () async {
      var created = 0;
      StubReceiverPlayer? createdPlayer;
      final controller = ReceiverController(
        playerFactory: () {
          created++;
          createdPlayer ??= StubReceiverPlayer();
          return createdPlayer!;
        },
        udnSeed: 'udn-factory',
        enableSsdp: false,
      );
      addTearDown(controller.stop);
      expect(created, 0);
      expect(controller.playerOrNull, isNull);

      await controller.start();
      expect(created, 1);
      final player = controller.playerOrNull;
      expect(player, isNotNull);

      await controller.stop();
      await controller.start();
      expect(created, 1, reason: '重启复用，不重建引擎');
      expect(controller.playerOrNull, same(player));
    });

    test('friendlyNameOverride 优先于 seed；空 override 回落', () {
      final controller = ReceiverController(friendlyNameSeed: '种子名');
      expect(controller.friendlyName, '种子名');
      controller.friendlyNameOverride = '用户名';
      expect(controller.friendlyName, '用户名');
      controller.friendlyNameOverride = '';
      expect(controller.friendlyName, '种子名');
    });
  });
}
