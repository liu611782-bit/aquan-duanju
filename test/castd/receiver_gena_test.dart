import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/gena_subscriber.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_gena.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('GENA 报文纯函数（AC-4）', () {
    test('callbacks：抽取 <http://…> 并过滤非 http', () {
      expect(
        genaCallbacks('<http://10.0.0.5:18480/cb><http://10.0.0.5:18481/cb>'),
        const ['http://10.0.0.5:18480/cb', 'http://10.0.0.5:18481/cb'],
      );
      expect(genaCallbacks('<htt*p://bad><http://ok>'), const ['http://ok']);
      expect(genaCallbacks(null), isEmpty);
      expect(genaCallbacks(''), isEmpty);
    });

    test('timeoutSeconds：Second-N 钳制、缺省 300、infinite 回默认', () {
      expect(genaTimeoutSeconds('Second-300'), 300);
      expect(genaTimeoutSeconds('Second-30'), 60);
      expect(genaTimeoutSeconds('Second-99999'), 1800);
      expect(genaTimeoutSeconds('Second-infinite'), 300);
      expect(genaTimeoutSeconds(null), 300);
      expect(genaTimeoutSeconds('garbage'), 300);
    });

    test('AVT LastChange 被自家 parseAvtLastChange 解析（互操作）', () {
      final body = genaPropertySet(ReceiverService.avTransport, [
        ('TransportState', 'PLAYING'),
        ('CurrentTrackDuration', '0:04:00'),
        ('AVTransportURI', 'http://192.168.1.9:18280/p/ab/v.mp4'),
      ]);
      final poll = parseAvtLastChange(body);
      expect(poll, isNotNull);
      expect(poll!.transportState, 'PLAYING');
      expect(poll.duration, const Duration(minutes: 4));
      expect(body, contains('urn:schemas-upnp-org:metadata-1-0/AVT/'));
    });

    test('URL 含 & 转义后仍可解析', () {
      final body = genaPropertySet(ReceiverService.avTransport, [
        ('TransportState', 'STOPPED'),
        ('AVTransportURI', 'http://x/v.mp4?a=1&b=2'),
      ]);
      final poll = parseAvtLastChange(body);
      expect(poll!.transportState, 'STOPPED');
    });

    test('RCS LastChange：RCS 命名空间 + channel=Master；非 AVT 解析为 null', () {
      final body = genaPropertySet(ReceiverService.renderingControl, [
        ('Volume', '37'),
        ('Mute', '0'),
      ]);
      expect(body, contains('urn:schemas-upnp-org:metadata-1-0/RCS/'));
      // 内层 XML 整体转义进 LastChange。
      expect(body, contains('channel=&quot;Master&quot;'));
      expect(body, contains('&lt;Volume val=&quot;37&quot;'));
      expect(parseAvtLastChange(body), isNull, reason: 'RCS 事件不是 AVT 事件');
    });
  });

  group('ReceiverGena（假 callback 服务端到端，AC-4）', () {
    late StubReceiverPlayer stub;
    late ReceiverRenderer renderer;
    late ReceiverGena gena;
    late HttpServer callbackServer;
    final notifications = <HttpRequest, String>{};
    final bodies = <String>[];

    setUp(() async {
      notifications.clear();
      bodies.clear();
      stub = StubReceiverPlayer();
      renderer = ReceiverRenderer(player: stub);
      gena = ReceiverGena(
        renderer: renderer,
        initialEventDelay: const Duration(milliseconds: 30),
      );
      callbackServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      callbackServer.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        notifications[req] = body;
        bodies.add(body);
        await req.response.close();
      });
    });

    tearDown(() async {
      gena.stop();
      await callbackServer.close(force: true);
    });

    String callbackUrl() => 'http://127.0.0.1:${callbackServer.port}/cb';

    Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 250));

    test('subscribe：初始事件（SID/SEQ=0/LastChange）送达', () async {
      final result = gena.subscribe(
        ReceiverService.avTransport,
        null,
        '<${callbackUrl()}>',
        'Second-300',
      );
      expect(result, isNotNull);
      final (sid, seconds) = result!;
      expect(sid, startsWith('uuid:'));
      expect(seconds, 300);
      await pump();
      expect(bodies, isNotEmpty, reason: '初始事件（全量状态）应送达');
      final headers = notifications.keys.single.headers;
      expect(headers.value('sid'), sid);
      expect(headers.value('nt'), 'upnp:event');
      expect(headers.value('nts'), 'upnp:propchange');
      expect(headers.value('seq'), '0');
      final poll = parseAvtLastChange(bodies.first);
      expect(poll!.transportState, 'NO_MEDIA_PRESENT');
    });

    test('状态变化 → NOTIFY 推送（checkNow 驱动，seq 递增）', () async {
      final (sid, _) = gena.subscribe(
        ReceiverService.avTransport,
        null,
        '<${callbackUrl()}>',
        null,
      )!;
      await pump();
      expect(bodies.length, 1);

      await renderer.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('SetAVTransportURI', {
          'InstanceID': '0',
          'CurrentURI': 'http://x/v.mp4',
          'CurrentURIMetaData': '',
        }),
      );
      await renderer.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('Play', {'InstanceID': '0'}),
      );
      gena.checkNow();
      await pump();

      expect(bodies.length, 2, reason: '状态变化产生一次 NOTIFY');
      expect(notifications.keys.last.headers.value('sid'), sid);
      expect(notifications.keys.last.headers.value('seq'), '1');
      final poll = parseAvtLastChange(bodies.last);
      expect(poll!.transportState, 'PLAYING');

      // 无变化：再 checkNow 不重发。
      gena.checkNow();
      await pump();
      expect(bodies.length, 2);
    });

    test('续订：同 SID 刷新；未知 SID → null（412 语义）', () {
      final (sid, _) = gena.subscribe(
        ReceiverService.avTransport,
        null,
        '<${callbackUrl()}>',
        null,
      )!;
      final renewed = gena.subscribe(
        ReceiverService.avTransport,
        sid,
        null,
        'Second-600',
      );
      expect(renewed, isNotNull);
      expect(renewed!.$1, sid, reason: '续订保持 SID');
      expect(renewed.$2, 600);
      expect(
        gena.subscribe(ReceiverService.avTransport, 'uuid:unknown', null, null),
        isNull,
      );
    });

    test('unsubscribe 后不再推送', () async {
      final (sid, _) = gena.subscribe(
        ReceiverService.avTransport,
        null,
        '<${callbackUrl()}>',
        null,
      )!;
      await pump();
      expect(bodies.length, 1);
      gena.unsubscribe(sid);
      stub.state = kTransportPlaying;
      gena.checkNow();
      await pump();
      expect(bodies.length, 1);
    });

    test('投递失败（死 callback）静默移除订阅者', () async {
      gena.subscribe(
        ReceiverService.avTransport,
        null,
        '<http://127.0.0.1:1/dead>',
        null,
      );
      // 初始事件投递失败 → 订阅被移除；后续 checkNow 不崩溃不投递。
      await pump();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      stub.state = kTransportPlaying;
      gena.checkNow();
      await pump();
      expect(bodies, isEmpty);
    });
  });

  group('自家 GenaSubscriber 订阅接收端 NOTIFY（互操作，AC-4）', () {
    late StubReceiverPlayer stub;
    late ReceiverRenderer renderer;
    late ReceiverGena gena;
    late GenaSubscriber subscriber;
    late HttpServer eventSub;

    setUp(() {
      stub = StubReceiverPlayer();
      renderer = ReceiverRenderer(player: stub);
      gena = ReceiverGena(
        renderer: renderer,
        initialEventDelay: const Duration(milliseconds: 30),
      );
    });

    tearDown(() async {
      await subscriber.stop();
      gena.stop();
      await eventSub.close(force: true);
    });

    test('SUBSCRIBE → 初始事件 NO_MEDIA_PRESENT → Play 事件 PLAYING', () async {
      // 假 eventSub 端点（模拟接收端 HTTP 层路由）：
      // SUBSCRIBE → gena.subscribe 并回 SID/TIMEOUT；UNSUBSCRIBE → 退订。
      eventSub = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      eventSub.listen((req) async {
        if (req.method == 'SUBSCRIBE') {
          final result = gena.subscribe(
            ReceiverService.avTransport,
            req.headers.value('sid'),
            req.headers.value('callback'),
            req.headers.value('timeout'),
          );
          if (result == null) {
            req.response.statusCode = 412;
          } else {
            req.response.headers.set('SID', result.$1);
            req.response.headers.set('TIMEOUT', 'Second-${result.$2}');
          }
        } else {
          gena.unsubscribe(req.headers.value('sid'));
        }
        await req.response.close();
      });

      subscriber = GenaSubscriber(
        'http://127.0.0.1:${eventSub.port}/AVTransport/event',
        hostOverride: '127.0.0.1',
      );
      final gotFirst = Completer<CastPoll>();
      final sub = subscriber.events.listen((poll) {
        if (!gotFirst.isCompleted) gotFirst.complete(poll);
      });
      addTearDown(sub.cancel);

      expect(await subscriber.subscribe(), isTrue);
      final first = await gotFirst.future.timeout(const Duration(seconds: 3));
      expect(first.transportState, 'NO_MEDIA_PRESENT');

      // 状态变化 → 事件（手动 checkNow，不等 1s 定时器）。
      final gotPlaying = Completer<CastPoll>();
      final sub2 = subscriber.events.listen((poll) {
        if (poll.transportState == 'PLAYING' && !gotPlaying.isCompleted) {
          gotPlaying.complete(poll);
        }
      });
      addTearDown(sub2.cancel);
      await renderer.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('SetAVTransportURI', {
          'InstanceID': '0',
          'CurrentURI': 'http://x/v.mp4',
          'CurrentURIMetaData': '',
        }),
      );
      await renderer.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('Play', {'InstanceID': '0'}),
      );
      gena.checkNow();
      final playing = await gotPlaying.future.timeout(const Duration(seconds: 3));
      expect(playing.transportState, 'PLAYING');
    });
  });
}
