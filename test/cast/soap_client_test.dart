import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/soap_client.dart';

void main() {
  group('buildEnvelope', () {
    test('action 与参数顺序', () {
      final envelope = buildEnvelope('urn:schemas-upnp-org:service:AVTransport:1',
          'SetAVTransportURI', {'InstanceID': '0', 'CurrentURI': 'http://x/1.m3u8'});
      expect(envelope, contains('<u:SetAVTransportURI'));
      expect(envelope, contains('xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"'));
      expect(envelope, contains('<InstanceID>0</InstanceID>'));
      expect(envelope, contains('<CurrentURI>http://x/1.m3u8</CurrentURI>'));
      expect(envelope, contains('SOAP-ENC'.isEmpty ? '' : 'encodingStyle'));
    });

    test('AC-12：xmlns:u 用传入的真实 serviceType（含版本）', () {
      final envelope = buildEnvelope(
          'urn:schemas-upnp-org:service:AVTransport:2', 'Play', {'Speed': '1'});
      expect(envelope, contains('xmlns:u="urn:schemas-upnp-org:service:AVTransport:2"'));
      expect(envelope, isNot(contains('AVTransport:1')));
    });
  });

  group('parseSoapResponse（多模式兜底）', () {
    test('标准响应元素', () {
      final body = '<s:Envelope><s:Body>'
          '<u:GetTransportInfoResponse xmlns:u="urn:x"> '
          '<CurrentTransportState>PLAYING</CurrentTransportState>'
          '<CurrentTransportStatus>OK</CurrentTransportStatus>'
          '</u:GetTransportInfoResponse></s:Body></s:Envelope>';
      final out = parseSoapResponse(body, 'GetTransportInfo');
      expect(out['CurrentTransportState'], 'PLAYING');
      expect(out['CurrentTransportStatus'], 'OK');
    });

    test('带命名空间前缀的返回字段', () {
      final body = '<Envelope><Body>'
          '<rcs:GetVolumeResponse><rcs:CurrentVolume>37</rcs:CurrentVolume>'
          '</rcs:GetVolumeResponse></Body></Envelope>';
      final out = parseSoapResponse(body, 'GetVolume');
      expect(out['CurrentVolume'], '37');
    });

    test('非法 XML 走正则兜底（含 GetMediaInfo.CurrentURI 归属校验字段）', () {
      const body = 'garbage <CurrentURI>http://tv/old.mp4</CurrentURI> tail';
      final out = parseSoapResponse(body, 'GetMediaInfo');
      expect(out['CurrentURI'], 'http://tv/old.mp4');
      const pos = 'noise <TrackURI>http://tv/new.mp4</TrackURI>';
      expect(parseSoapResponse(pos, 'GetPositionInfo')['TrackURI'],
          'http://tv/new.mp4');
    });

    test('空响应返回空 Map', () {
      expect(parseSoapResponse('<a></a>', 'Unknown'), isEmpty);
    });
  });

  group('parseSoapFault', () {
    test('UPnP fault（含 errorCode）', () {
      // 真实 UPnP fault 包在信封里且命名空间已声明。
      const body = '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
          '<s:Body><s:Fault><s:code>s:Sender</s:code>'
          '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
          '<errorCode>401</errorCode>'
          '<errorDescription>Invalid Action</errorDescription>'
          '</UPnPError></s:Fault></s:Body></s:Envelope>';
      final fault = parseSoapFault(body);
      expect(fault, isNotNull);
      expect(fault!.$1, contains('Sender'));
      expect(fault.$2, contains('401'));
    });

    test('无 fault 返回 null', () {
      expect(parseSoapFault('<a></a>'), isNull);
    });
  });

  group('时间格式', () {
    test('parseUpnpTime 容错', () {
      expect(parseUpnpTime('0:02:15.500'), const Duration(minutes: 2, seconds: 15, milliseconds: 500));
      expect(parseUpnpTime('1:00:00'), const Duration(hours: 1));
      expect(parseUpnpTime('12:34'), const Duration(minutes: 12, seconds: 34));
      expect(parseUpnpTime(''), isNull);
      expect(parseUpnpTime('NOT_IMPLEMENTED'), isNull);
      expect(parseUpnpTime('xx:yy'), isNull);
    });

    test('formatUpnpTime', () {
      expect(formatUpnpTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
          '1:02:03');
    });
  });

  group('真实 HTTP 往返（本地夹具；AC-12 / AC-26）', () {
    late HttpServer server;
    late Uri requestUri;
    var requestCount = 0;
    final soapActions = <String?>[];
    final bodies = <String>[];

    /// 每个测试注入的响应脚本：按请求序号给出 (status, body)。
    late List<(int, String)> Function(int nthRequest) responder;

    /// true = 处理请求时挂住 3s（超过 1s 客户端超时，触发 TimeoutException）。
    var hangRequest = false;

    setUp(() async {
      requestCount = 0;
      soapActions.clear();
      bodies.clear();
      hangRequest = false;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      requestUri = Uri.parse('http://127.0.0.1:${server.port}/ctrl');
      responder = (_) => const [];
      server.listen((req) async {
        final nth = requestCount++;
        soapActions.add(req.headers.value('SOAPACTION'));
        final body = await utf8.decoder.bind(req).join();
        bodies.add(body);
        if (hangRequest) {
          await Future<void>.delayed(const Duration(seconds: 3));
          req.response.statusCode = 200;
          req.response.write('<u:PlayResponse xmlns:u="urn:x"/>');
          await req.response.close();
          return;
        }
        final script = responder(nth);
        final (status, respBody) =
            script.isNotEmpty ? script[0] : (200, '<ok/>');
        req.response.headers.contentType =
            ContentType('text', 'xml', charset: 'utf-8');
        req.response.statusCode = status;
        req.response.write(respBody);
        await req.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    test('AC-12：SOAPACTION 恒带双引号，URN 用传入 serviceType', () async {
      final client = SoapClient();
      await client.sendAction(
        requestUri.toString(),
        'urn:schemas-upnp-org:service:AVTransport:2',
        'Play',
        {'Speed': '1'},
      );
      expect(soapActions.single,
          '"urn:schemas-upnp-org:service:AVTransport:2#Play"');
      // 请求体信封的 xmlns:u 同样用传入 serviceType。
      expect(bodies.single,
          contains('xmlns:u="urn:schemas-upnp-org:service:AVTransport:2"'));
      client.close();
    });

    test('AC-26：确定性 fault（带 faultCode）恰 1 次请求，不重试', () async {
      responder = (_) => <(int, String)>[
        (
          500,
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
              '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
              '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
              '<errorCode>401</errorCode></UPnPError></s:Fault></s:Body>'
              '</s:Envelope>'
        ),
      ];
      final client = SoapClient(timeout: const Duration(seconds: 2));
      await expectLater(
        client.sendAction(requestUri.toString(),
            'urn:schemas-upnp-org:service:AVTransport:1', 'SetAVTransportURI',
            {'CurrentURI': 'http://x/1'}),
        throwsA(isA<SoapException>()),
      );
      expect(requestCount, 1, reason: '确定性 fault 绝不重试（AC-26）');
      client.close();
    });

    test('AC-26：4xx 无 fault 也是确定性拒绝，恰 1 次请求', () async {
      responder = (_) => <(int, String)>[(403, '')];
      final client = SoapClient(timeout: const Duration(seconds: 2));
      await expectLater(
        client.sendAction(requestUri.toString(),
            'urn:schemas-upnp-org:service:AVTransport:1', 'Play', {}),
        throwsA(isA<SoapException>()),
      );
      expect(requestCount, 1);
      client.close();
    });

    test('5xx 无 fault：重试一次（共 2 次请求）', () async {
      responder = (_) => <(int, String)>[(504, ''), (504, '')];
      final client = SoapClient(timeout: const Duration(seconds: 2));
      await expectLater(
        client.sendAction(requestUri.toString(),
            'urn:schemas-upnp-org:service:AVTransport:1', 'Play', {}),
        throwsA(isA<SoapException>()),
      );
      expect(requestCount, 2, reason: '无 fault 的 5xx 是偶发故障，重试一次');
      client.close();
    });

    test('5xx 带 fault body：确定性拒绝，不重试', () async {
      responder = (_) => <(int, String)>[
        (
          500,
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
              '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
              '<faultstring>UPnPError</faultstring></s:Fault></s:Body>'
              '</s:Envelope>'
        ),
      ];
      final client = SoapClient(timeout: const Duration(seconds: 2));
      await expectLater(
        client.sendAction(requestUri.toString(),
            'urn:schemas-upnp-org:service:AVTransport:1', 'SetAVTransportURI',
            {'CurrentURI': 'http://x/1'}),
        throwsA(isA<SoapException>()),
      );
      expect(requestCount, 1, reason: '带 faultCode 的响应是确定性拒绝');
      client.close();
    });

    test('超时类异常重试 1 次（共 2 次请求）', () async {
      hangRequest = true;
      final client = SoapClient(timeout: const Duration(seconds: 1));
      await expectLater(
        client.sendAction(requestUri.toString(),
            'urn:schemas-upnp-org:service:AVTransport:1', 'Play', {}),
        throwsA(isA<SoapException>()),
      );
      expect(requestCount, 2, reason: '超时是瞬态失败，重试一次');
      client.close();
    });
  });
}
