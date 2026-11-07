import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/gena_subscriber.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_ssdp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 真实 socket 测试（回环）；命令行已剥代理环境变量。
void main() {
  late ReceiverController controller;
  late StubReceiverPlayer stub;
  late String controlUrl;
  late String eventUrl;

  setUp(() async {
    stub = StubReceiverPlayer();
    controller = ReceiverController(
      playerOverride: stub,
      udnSeed: 'test-udn-http',
      friendlyNameSeed: '测试接收',
      enableSsdp: false,
    );
    await controller.start();
    final port = controller.port!;
    controlUrl = 'http://127.0.0.1:$port/AVTransport/control';
    eventUrl = 'http://127.0.0.1:$port/AVTransport/event';
  });

  tearDown(() async {
    await controller.stop();
  });

  group('路由', () {
    test('GET description.xml：200 + text/xml + SERVER 头', () async {
      final res = await http.get(
        Uri.parse('http://127.0.0.1:${controller.port}/description.xml'),
      );
      expect(res.statusCode, 200);
      expect(res.headers['content-type'], contains('text/xml'));
      expect(res.headers['server'], ReceiverSsdp.serverProduct);
      expect(res.body, contains('测试接收'));
      expect(res.body, contains('uuid:test-udn-http'));
    });

    test('GET SCPD：200；未知路径 404；GET control 405；POST event 405', () async {
      final base = 'http://127.0.0.1:${controller.port}';
      expect(
        (await http.get(Uri.parse('$base/AVTransport/scpd.xml'))).statusCode,
        200,
      );
      expect(
        (await http.get(Uri.parse('$base/ConnectionManager/scpd.xml')))
            .statusCode,
        200,
      );
      expect((await http.get(Uri.parse('$base/nope'))).statusCode, 404);
      expect((await http.get(Uri.parse(controlUrl))).statusCode, 405);
      expect((await http.post(Uri.parse(eventUrl))).statusCode, 405);
      // 伺服面收敛：不回显任意文件路径。
      expect(
        (await http.get(Uri.parse('$base/../windows/win.ini'))).statusCode,
        isNot(200),
      );
    });

    test('超大请求体拒绝（>256KB）', () async {
      final client = HttpClient();
      try {
        final req = await client.postUrl(Uri.parse(controlUrl));
        req.headers.set('Content-Type', 'text/xml; charset="utf-8"');
        req.headers.set(
          'SOAPACTION',
          '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
        );
        req.add(utf8.encode('x' * (256 * 1024 + 1)));
        final res = await req.close();
        expect(res.statusCode, 500);
        await res.drain<void>();
      } finally {
        client.close(force: true);
      }
    });
  });

  group('SOAP 1.1（自家 SoapClient 全链路互操作）', () {
    test('SetAVTransportURI → Play → GetTransportInfo=PLAYING → Pause/Stop',
        () async {
      final client = SoapClient();
      addTearDown(client.close);
      final avt = ReceiverService.avTransport.type;

      await client.sendAction(controlUrl, avt, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': 'http://192.168.1.9:18280/p/tok/video.mp4',
        'CurrentURIMetaData': buildDidlLite(title: '互操作集'),
      });
      expect(stub.loadedTitle, '互操作集');

      await client.sendAction(controlUrl, avt, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });
      var info = await client.sendAction(
        controlUrl,
        avt,
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      expect(info['CurrentTransportState'], 'PLAYING');

      await client.sendAction(controlUrl, avt, 'Pause', {'InstanceID': '0'});
      info = await client.sendAction(
        controlUrl,
        avt,
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      expect(info['CurrentTransportState'], 'PAUSED_PLAYBACK');

      await client.sendAction(controlUrl, avt, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': '0:01:30',
      });
      expect(stub.seeks.single, const Duration(minutes: 1, seconds: 30));

      await client.sendAction(controlUrl, avt, 'Stop', {'InstanceID': '0'});
      info = await client.sendAction(
        controlUrl,
        avt,
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      expect(info['CurrentTransportState'], 'STOPPED');
    });

    test('fault：无 URI 的 Play → SoapException 带 UPnP fault', () async {
      final client = SoapClient();
      addTearDown(client.close);
      await expectLater(
        client.sendAction(controlUrl, ReceiverService.avTransport.type, 'Play',
            {'InstanceID': '0'}),
        throwsA(isA<SoapException>().having(
          (e) => e.faultCode,
          'faultCode',
          isNotNull,
        )),
      );
    });

    test('RenderingControl / ConnectionManager 走各自 controlURL', () async {
      final client = SoapClient();
      addTearDown(client.close);
      final port = controller.port;
      final rcs = await client.sendAction(
        'http://127.0.0.1:$port/RenderingControl/control',
        ReceiverService.renderingControl.type,
        'SetVolume',
        {'InstanceID': '0', 'Channel': 'Master', 'DesiredVolume': '42'},
      );
      expect(stub.volume, 42);
      expect(rcs, isEmpty);
      final cm = await client.sendAction(
        'http://127.0.0.1:$port/ConnectionManager/control',
        ReceiverService.connectionManager.type,
        'GetProtocolInfo',
        {},
      );
      expect(cm['Sink'], contains('video/mp4'));
    });
  });

  group('SOAP 1.2（application/soap+xml 兼容）', () {
    test('无 SOAPACTION 头、Content-Type action 参数：仍可解析并应答', () async {
      final client = HttpClient();
      try {
        // 先 SetAVTransportURI（否则 Play 无 URI 回 fault 500）。
        final set = await client.postUrl(Uri.parse(controlUrl));
        set.headers.set('Content-Type', 'text/xml; charset="utf-8"');
        set.headers.set(
          'SOAPACTION',
          '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
        );
        set.add(utf8.encode(buildEnvelope(
          ReceiverService.avTransport.type,
          'SetAVTransportURI',
          {'InstanceID': '0', 'CurrentURI': 'http://x/v.mp4'},
        )));
        final setRes = await set.close();
        expect(setRes.statusCode, 200);

        final req = await client.postUrl(Uri.parse(controlUrl));
        req.headers.set(
          'Content-Type',
          'application/soap+xml; charset=utf-8; '
              'action="urn:schemas-upnp-org:service:AVTransport:1#Play"',
        );
        req.add(utf8.encode('<?xml version="1.0" encoding="utf-8"?>'
            '<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" '
            's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
            '<s:Body><u:Play '
            'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
            '<InstanceID>0</InstanceID></u:Play></s:Body></s:Envelope>'));
        final res = await req.close();
        expect(res.statusCode, 200);
        final body = await res.transform(utf8.decoder).join();
        expect(parseSoapResponse(body, 'Play'), isEmpty);
        expect(parseSoapFault(body), isNull);
      } finally {
        client.close(force: true);
      }
    });

    test('坏请求体且无 SOAPACTION 头 → 400', () async {
      final res = await http.post(
        Uri.parse(controlUrl),
        headers: {
          'Content-Type': 'text/xml; charset="utf-8"',
        },
        body: 'not-xml-at-all',
      );
      // 体不可解析且头不可回退 → 400；带合法 SOAPACTION 头时动作名仍可
      // 从头回退解析（走 710 fault，不在此断言）。
      expect(res.statusCode, 400);
    });
  });

  group('GENA 路由（AC-4）', () {
    test('SUBSCRIBE 回 SID/TIMEOUT；未知续订 412；UNSUBSCRIBE 200', () async {
      final client = HttpClient();
      try {
        // 订阅（CALLBACK 指向一个已关闭端口：投递失败会移除，不影响本断言）。
        final req = await client.openUrl('SUBSCRIBE', Uri.parse(eventUrl));
        req.headers.set('CALLBACK', '<http://127.0.0.1:1/cb>');
        req.headers.set('NT', 'upnp:event');
        req.headers.set('TIMEOUT', 'Second-300');
        final res = await req.close();
        expect(res.statusCode, 200);
        final sid = res.headers.value('sid');
        expect(sid, startsWith('uuid:'));
        expect(res.headers.value('timeout'), 'Second-300');

        // 续订（带 SID）。
        final renew = await client.openUrl('SUBSCRIBE', Uri.parse(eventUrl));
        renew.headers.set('SID', sid!);
        renew.headers.set('TIMEOUT', 'Second-600');
        final renewRes = await renew.close();
        expect(renewRes.statusCode, 200);
        expect(renewRes.headers.value('sid'), sid);

        // 未知 SID 续订 → 412。
        final bad = await client.openUrl('SUBSCRIBE', Uri.parse(eventUrl));
        bad.headers.set('SID', 'uuid:unknown');
        expect((await bad.close()).statusCode, 412);

        // 缺 CALLBACK 的新订阅 → 412。
        final noCallback = await client.openUrl('SUBSCRIBE', Uri.parse(eventUrl));
        noCallback.headers.set('NT', 'upnp:event');
        expect((await noCallback.close()).statusCode, 412);

        // UNSUBSCRIBE。
        final unsub = await client.openUrl('UNSUBSCRIBE', Uri.parse(eventUrl));
        unsub.headers.set('SID', sid);
        expect((await unsub.close()).statusCode, 200);
      } finally {
        client.close(force: true);
      }
    });

    test('GenaSubscriber 全链路：订阅接收端 → Play 事件到达', () async {
      final subscriber = GenaSubscriber(eventUrl, hostOverride: '127.0.0.1');
      addTearDown(subscriber.stop);
      final gotPlaying = Completer<CastPoll>();
      final sub = subscriber.events.listen((poll) {
        if (poll.transportState == 'PLAYING' && !gotPlaying.isCompleted) {
          gotPlaying.complete(poll);
        }
      });
      addTearDown(sub.cancel);
      expect(await subscriber.subscribe(), isTrue);

      final client = SoapClient();
      addTearDown(client.close);
      await client.sendAction(controlUrl, ReceiverService.avTransport.type,
          'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '',
      });
      await client.sendAction(
        controlUrl,
        ReceiverService.avTransport.type,
        'Play',
        {'InstanceID': '0'},
      );

      // 接收端 1s 检查窗内推送；GenaSubscriber 解析 LastChange 成 CastPoll。
      final poll = await gotPlaying.future.timeout(const Duration(seconds: 5));
      expect(poll.transportState, 'PLAYING');
    });
  });
}
