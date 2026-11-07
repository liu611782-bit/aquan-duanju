import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

void main() {
  group('M-POST 回退（go2tv 蓝本：405 → M-POST + MAN ns=01）', () {
    late HttpServer server;
    final methods = <String>[];
    final mpostHeaders = <HttpHeaders>[];
    setUp(() async {
      methods.clear();
      mpostHeaders.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        methods.add(req.method);
        if (req.method == 'M-POST') mpostHeaders.add(req.headers);
        final body = await utf8.decoder.bind(req).join();
        req.response.headers.contentType =
            ContentType('text', 'xml', charset: 'utf-8');
        if (req.method == 'POST') {
          // 设备强制 M-POST：对 POST 一律回 405。
          req.response.statusCode = 405;
          await req.response.close();
          return;
        }
        expect(req.method, 'M-POST');
        req.response.statusCode = 200;
        req.response.write('<u:GetTransportInfoResponse '
            'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
            '<CurrentTransportState>PLAYING</CurrentTransportState>'
            '</u:GetTransportInfoResponse>');
        await req.response.close();
        assert(body.isNotEmpty);
      });
    });

    tearDown(() async => server.close());

    test('POST 405 后自动改发 M-POST 并解析成功', () async {
      final client = SoapClient(timeout: const Duration(seconds: 2));
      final values = await client.sendAction(
        'http://127.0.0.1:${server.port}/ctrl',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      expect(values['CurrentTransportState'], 'PLAYING');
      expect(methods, ['POST', 'M-POST']);
    });

    test('M-POST 头符合 UPnP 1.1 规范（MAN ns=01 + 01-SOAPACTION）', () async {
      final client = SoapClient(timeout: const Duration(seconds: 2));
      await client.sendAction(
        'http://127.0.0.1:${server.port}/ctrl',
        'urn:schemas-upnp-org:service:AVTransport:1',
        'GetTransportInfo',
        {'InstanceID': '0'},
      );
      expect(mpostHeaders, hasLength(1));
      final h = mpostHeaders.first;
      expect(h.value('MAN'),
          '"http://schemas.xmlsoap.org/soap/envelope/"; ns=01');
      expect(
        h.value('01-SOAPACTION'),
        '"urn:schemas-upnp-org:service:AVTransport:1#GetTransportInfo"',
      );
      // 逐跳头不得出现（本实现从不设置，显式校验防回归）。
      expect(h.value('Connection'), isNull);
      expect(h.value('Keep-Alive'), isNull);
    });
  });

  group('字幕标签（DIDL 字幕投送；M2 v2 三件套）', () {
    test('subtitleUrl 非空时 DIDL 含 sec 扩展与地址', () {
      final didl = buildDidlLite(
        title: '第1集',
        subtitleUrl: Uri.parse('http://192.168.1.5:18280/p/sub1'),
      );
      expect(didl.contains('xmlns:sec="http://www.sec.co.kr/"'), isTrue);
      expect(didl.contains(
          '<sec:CaptionInfoEx sec:type="srt">http://192.168.1.5:18280/p/sub1</sec:CaptionInfoEx>'),
          isTrue);
      expect(didl.contains('<dc:title>第1集</dc:title>'), isTrue);
    });

    test('subtitleUrl 为空时不带 sec 节点', () {
      final didl = buildDidlLite(title: '第1集');
      expect(didl.contains('sec:'), isFalse);
    });
  });
}
