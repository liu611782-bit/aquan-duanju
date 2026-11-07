import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/dlna_transport.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/store/stores.dart';

DlnaDevice _dlna(String udn, String host) => DlnaDevice(
      udn: udn,
      friendlyName: '客厅电视',
      controlUrl: 'http://$host:49152/ctrl',
      location: 'http://$host:49152/desc.xml',
    );

class FakeTransport implements CastTransport {
  FakeTransport({this.failSetUri = false});

  final List<String> calls = [];
  bool failSetUri;
  Uri? lastUri;

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url');
    lastUri = url;
    if (failSetUri) {
      throw SoapException('SetAVTransportURI 失败 HTTP 500',
          faultCode: 'UPnPError');
    }
  }

  @override
  Future<void> play() async => calls.add('play');
  @override
  Future<void> pause() async => calls.add('pause');
  @override
  Future<void> stop() async => calls.add('stop');
  @override
  Future<void> seekTo(Duration position) async => calls.add('seek');
  @override
  Future<void> setVolume(int percent) async => calls.add('volume:$percent');
  @override
  Future<void> setMute(bool muted) async => calls.add('mute:$muted');
  @override
  Future<CastPoll> poll() async =>
      const CastPoll(transportState: 'PLAYING', position: Duration(seconds: 5));
  @override
  void close() {}
}

void main() {
  test('同 IP 双协议降级：DLNA 失败 → 同 host Chromecast 重试成功', () async {
    final dlnaFail = FakeTransport()..failSetUri = true;
    final castOk = FakeTransport();
    final controller = CastController(
      transportFactory: (t) =>
          t.protocol == CastProtocol.chromecast ? castOk : dlnaFail,
      mdnsDiscover: () => Stream.value(
        const CastDeviceInfo(host: '192.168.1.50', name: '客厅电视'),
      ),
    );
    // 种入 mDNS 发现的 Chromecast 目标（与 DLNA 目标同 IP）。
    controller.startScan();
    await Future<void>.delayed(Duration.zero);
    controller.stopScan();

    final dlnaTarget = CastTarget.dlna(_dlna('d1', '192.168.1.50'));
    await controller.castTo(
      dlnaTarget,
      const CastMedia(url: 'http://x/1.mp4', title: 't'),
    );
    expect(controller.currentDevice?.protocol, CastProtocol.chromecast,
        reason: 'DLNA 失败后应自动换同 IP 的 Chromecast');
    expect(castOk.calls.first, startsWith('setUri:'));
    controller.dispose();
  });

  test('无同 IP 备选时不降级，失败原样上抛', () async {
    final fail = FakeTransport()..failSetUri = true;
    final controller = CastController(transportFactory: (_) => fail);
    await expectLater(
      controller.castTo(
        CastTarget.dlna(_dlna('d1', '10.0.0.9')),
        const CastMedia(url: 'http://x/1.mp4', title: 't'),
      ),
      throwsA(isA<SoapException>()),
    );
    expect(controller.state, CastSessionState.idle);
    controller.dispose();
  });

  test('headers 非空且配置代理：投出的是代理 URL，媒体记录同步替换', () async {
    final transport = FakeTransport();
    final controller = CastController(
      transportFactory: (_) => transport,
      proxyResolver: (url, headers) async =>
          'http://192.168.1.5:18280/p/t1?u=${Uri.encodeComponent(url)}',
    );
    await controller.castTo(
      CastTarget.dlna(_dlna('d1', '192.168.1.7')),
      const CastMedia(
        url: 'http://origin/1.m3u8',
        title: 't',
        headers: {'Referer': 'http://origin/'},
      ),
    );
    expect(transport.lastUri.toString(), contains('/p/t1'));
    expect(controller.currentMedia?.url, contains('/p/t1'));
    controller.dispose();
  });

  test('本地文件优先于代理：localPath 走 LocalMediaServer', () async {
    final transport = FakeTransport();
    final controller = CastController(
      transportFactory: (_) => transport,
      proxyResolver: (url, _) async => 'http://192.168.1.5:18280/p/t1',
    );
    await controller.castTo(
      CastTarget.dlna(_dlna('d1', '192.168.1.7')),
      const CastMedia(url: 'ignored', title: 't', localPath: '/tmp/a.mp4'),
    );
    // 测试环境拿不到私网地址时 urlFor 为 null → 抛 CastException；
    // 无论哪条路径都不应使用代理 URL。
    final served = transport.lastUri;
    if (served != null) {
      expect(served.toString(), isNot(contains('/p/t1')));
    }
    controller.dispose();
  });

  test('CastStore v2：v1 旧 json（无 protocol）按 DLNA 解析', () async {
    final dir = await Directory.systemTemp.createTemp('cast_store_v1');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}${Platform.pathSeparator}aquan_cast.json').writeAsStringSync(
      '{"version":1,"lastDevice":{"udn":"u1","name":"旧电视","model":"X",'
      '"control_url":"http://192.168.1.9/ctrl","rendering_control_url":"",'
      '"location":"http://192.168.1.9/desc.xml"},"pinned":[]}',
    );
    final store = CastStore(testDirectory: dir);
    await store.loadFromDisk();
    expect(store.lastDevice?.protocol, CastProtocol.dlna);
    expect(store.lastDevice?.id, 'u1');
    expect(store.lastDevice?.name, '旧电视');
  });

  test('CastStore v2 往返：chromecast 设备持久化后读回一致', () async {
    final dir = await Directory.systemTemp.createTemp('cast_store_v2');
    addTearDown(() => dir.delete(recursive: true));
    final store = CastStore(testDirectory: dir);
    await store.loadFromDisk();
    const info = CastDeviceInfo(host: '192.168.1.50', port: 8009, name: '谷歌电视');
    await store.touchLast(CastTarget.chromecast(info));
    expect(store.lastDevice?.protocol, CastProtocol.chromecast);
    expect(store.lastDevice?.id, 'cast:192.168.1.50:8009');

    final store2 = CastStore(testDirectory: dir);
    await store2.loadFromDisk();
    expect(store2.lastDevice?.protocol, CastProtocol.chromecast);
    expect(store2.lastDevice?.host, '192.168.1.50');
    expect(store2.lastDevice?.name, '谷歌电视');
  });

  test('DlnaTransport：metadata 被 fault 拒绝后去 metadata 重试一次', () async {
    // 用本地 HttpServer 模拟 controlUrl：第一次回 SOAP fault，第二次回正常。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    var setUriCount = 0;
    final bodies = <String>[];
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      bodies.add(body);
      if (body.contains('SetAVTransportURI')) setUriCount++;
      req.response.headers.contentType =
          ContentType('text', 'xml', charset: 'utf-8');
      // AC-26 重试收窄后 SoapClient 对确定性 fault 不再重试：第一次 fault
      // 即穿透到 DlnaTransport 的「去 metadata 重试」层。
      if (setUriCount == 1) {
        req.response.statusCode = 500;
        req.response.write(
            '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">'
            '<s:Body><s:Fault><faultcode>s:Client</faultcode>'
            '<faultstring>UPnPError</faultstring></s:Fault></s:Body></s:Envelope>');
      } else {
        req.response.statusCode = 200;
        req.response.write(
            '<u:SetAVTransportURIResponse '
            'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1"/>');
      }
      await req.response.close();
    });

    final transport = DlnaTransport(
      DlnaDevice(
        udn: 'u1',
        friendlyName: 't',
        controlUrl: 'http://127.0.0.1:${server.port}/ctrl',
      ),
      client: SoapClient(timeout: const Duration(seconds: 2)),
    );
    // SoapClient 不重试 fault（AC-26）→ 共 2 次 SetAVTransportURI（1 故障 + 1 空 metadata 重试）。
    await transport.setUri(Uri.parse('http://x/1.mp4'), title: 't');
    expect(setUriCount, 2, reason: 'fault 后应触发无 metadata 重试（恰一次）');
    final last = bodies.last;
    expect(last.contains('<CurrentURIMetaData></CurrentURIMetaData>'), isTrue,
        reason: '重试时 metadata 为空串');
    expect(bodies.first.contains('&lt;dc:title&gt;'), isTrue,
        reason: '首次请求带完整 DIDL metadata（信封内转义）');
  });
}
