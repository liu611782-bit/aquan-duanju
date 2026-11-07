import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_renderer.dart';
import 'package:flutter_test/flutter_test.dart';


Map<String, String> _m(List<(String, String)> out) =>
    {for (final (k, v) in out) k: v};

void main() {
  late StubReceiverPlayer stub;
  late ReceiverRenderer renderer;
  final opened = <ReceiverMediaOpened>[];

  setUp(() {
    stub = StubReceiverPlayer();
    opened.clear();
    renderer = ReceiverRenderer(player: stub, onOpened: opened.add);
  });

  Future<List<(String, String)>> call(
    String action, [
    Map<String, String> args = const {'InstanceID': '0'},
  ]) =>
      renderer.handle(
        service: ReceiverService.avTransport,
        action: SoapActionRequest(action, args),
      );

  Future<String> transportState() async {
    final out = await call('GetTransportInfo');
    return _m(out)['CurrentTransportState']!;
  }

  group('AVT 状态机全转移表（AC-3）', () {
    test('NO_MEDIA_PRESENT → STOPPED → PLAYING ⇄ PAUSED_PLAYBACK → STOPPED',
        () async {
      expect(await transportState(), 'NO_MEDIA_PRESENT');

      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://192.168.1.9:18280/p/abc/video.mp4',
        'CurrentURIMetaData': '<DIDL-Lite><item><dc:title>第1集</dc:title>'
            '<upnp:class>object.item.videoItem</upnp:class></item></DIDL-Lite>',
      });
      expect(stub.loadCount, 1);
      expect(stub.loadedUri, Uri.parse('http://192.168.1.9:18280/p/abc/video.mp4'));
      expect(await transportState(), 'STOPPED', reason: '已加载待播');

      await call('Play', const {'InstanceID': '0', 'Speed': '1'});
      expect(stub.playCount, 1);
      expect(await transportState(), 'PLAYING');

      await call('Pause');
      expect(await transportState(), 'PAUSED_PLAYBACK');

      await call('Play');
      expect(await transportState(), 'PLAYING');

      await call('Stop');
      expect(stub.stopCount, 1);
      expect(await transportState(), 'STOPPED');
    });

    test('TRANSITIONING：引擎加载中如实上报（stub 直设状态）', () async {
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '',
      });
      stub.state = kTransportTransitioning; // 模拟引擎缓冲
      expect(await transportState(), 'TRANSITIONING');
      stub.state = kTransportPlaying;
      expect(await transportState(), 'PLAYING');
    });

    test('无 URI 时引擎实况归一 NO_MEDIA_PRESENT（design §4）', () async {
      stub.state = kTransportPlaying; // 引擎自嗨，但没有投送会话
      expect(await transportState(), 'NO_MEDIA_PRESENT');
    });

    test('新投替换当前会话（SetAVTransportURI 二次替换）', () async {
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/ep1.mp4',
        'CurrentURIMetaData': '',
      });
      await call('Play');
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/ep2.mp4',
        'CurrentURIMetaData': '',
      });
      expect(stub.loadCount, 2);
      expect(stub.loadedUri, Uri.parse('http://x/ep2.mp4'));
      expect(renderer.currentUri, 'http://x/ep2.mp4');
      expect(opened.length, 2);
      expect(await transportState(), 'STOPPED', reason: '替换后回到已加载待播');
    });

    test('DIDL 标题容错解析（含 CDATA 形态）', () async {
      final metadata = buildDidlLite(title: '第3集');
      await call('SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': metadata,
      });
      expect(stub.loadedTitle, '第3集');
      expect(opened.single.title, '第3集');
      // 坏 DIDL 不报错，标题为空。
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v2.mp4',
        'CurrentURIMetaData': '<<<不是XML',
      });
      expect(stub.loadedTitle, isNull);
    });
  });

  group('AVT fault 表（AC-3）', () {
    test('SetAVTransportURI 无 URI → 402', () async {
      await expectLater(
        call('SetAVTransportURI', const {'InstanceID': '0', 'CurrentURI': '  '}),
        throwsA(isA<ReceiverFault>()
            .having((f) => f.code, 'code', 402)),
      );
    });

    test('Play / Pause / GetMediaInfo 无 URI → 710', () async {
      for (final action in ['Play', 'Pause', 'GetMediaInfo']) {
        await expectLater(
          call(action),
          throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 710)),
          reason: action,
        );
      }
    });

    test('Seek：REL_BYTE → 401；非法 Target → 710；REL_TIME 成功', () async {
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '',
      });
      await expectLater(
        call('Seek', const {'InstanceID': '0', 'Unit': 'REL_BYTE', 'Target': '0:01:00'}),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 401)),
      );
      await expectLater(
        call('Seek', const {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': 'abc'}),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 710)),
      );
      await call('Seek', const {'InstanceID': '0', 'Unit': 'REL_TIME', 'Target': '0:01:23'});
      expect(stub.seeks.single, const Duration(minutes: 1, seconds: 23));
    });

    test('未知动作 → 401；Next/Previous → 701', () async {
      await expectLater(
        call('Nonsense'),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 401)),
      );
      for (final action in ['Next', 'Previous']) {
        await expectLater(
          call(action),
          throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 701)),
        );
      }
    });
  });

  group('RCS / CM', () {
    test('音量与静音', () async {
      var out = await renderer.handle(
        service: ReceiverService.renderingControl,
        action: const SoapActionRequest('GetVolume', {'InstanceID': '0', 'Channel': 'Master'}),
      );
      expect(_m(out)['CurrentVolume'], '100');
      await renderer.handle(
        service: ReceiverService.renderingControl,
        action: const SoapActionRequest('SetVolume', {'InstanceID': '0', 'Channel': 'Master', 'DesiredVolume': '37'}),
      );
      expect(stub.volume, 37);
      await expectLater(
        renderer.handle(
          service: ReceiverService.renderingControl,
          action: const SoapActionRequest('SetVolume', {'InstanceID': '0', 'Channel': 'Master', 'DesiredVolume': '101'}),
        ),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 402)),
      );
      await renderer.handle(
        service: ReceiverService.renderingControl,
        action: const SoapActionRequest('SetMute', {'InstanceID': '0', 'Channel': 'Master', 'DesiredMute': '1'}),
      );
      expect(stub.muted, isTrue);
      out = await renderer.handle(
        service: ReceiverService.renderingControl,
        action: const SoapActionRequest('GetMute', {'InstanceID': '0', 'Channel': 'Master'}),
      );
      expect(_m(out)['CurrentMute'], '1');
    });

    test('GetProtocolInfo：Sink 覆盖常用容器；未知动作 401', () async {
      final out = await renderer.handle(
        service: ReceiverService.connectionManager,
        action: const SoapActionRequest('GetProtocolInfo', {}),
      );
      final values = _m(out);
      expect(values['Sink'], contains('video/mp4'));
      expect(values['Sink'], contains('application/vnd.apple.mpegurl'));
      await expectLater(
        renderer.handle(
          service: ReceiverService.connectionManager,
          action: const SoapActionRequest('Nope', {}),
        ),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 401)),
      );
    });
  });

  group('GetPositionInfo / GetMediaInfo（AC-3 时长格式）', () {
    test('TrackDuration H:MM:SS（小时不补零）', () async {
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '',
      });
      // load 会清零 position：引擎实况在加载完成后读取。
      stub.duration = const Duration(hours: 1, minutes: 2, seconds: 3);
      stub.position = const Duration(minutes: 4, seconds: 5);
      final out = await call('GetPositionInfo');
      final values = _m(out);
      expect(values['Track'], '1');
      expect(values['TrackDuration'], '1:02:03');
      expect(values['RelTime'], '0:04:05');
      expect(values['TrackURI'], 'http://x/v.mp4');
      // 发送端时间解析互操作。
      expect(parseUpnpTime(values['TrackDuration']!),
          const Duration(hours: 1, minutes: 2, seconds: 3));
    });

    test('零时长/负时长钳 0', () {
      expect(formatUpnpClock(Duration.zero), '0:00:00');
      expect(formatUpnpClock(const Duration(seconds: -5)), '0:00:00');
      expect(parseUpnpClock('1:2:3'), const Duration(hours: 1, minutes: 2, seconds: 3));
      expect(parseUpnpClock('0:01:23.500'),
          const Duration(seconds: 83, milliseconds: 500));
      expect(parseUpnpClock('90'), const Duration(seconds: 90));
      expect(parseUpnpClock('abc'), isNull);
      expect(parseUpnpClock('1:2:3:4'), isNull);
      expect(parseUpnpClock(''), isNull);
    });

    test('GetMediaInfo 回显 URI 与 nrTracks=1', () async {
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '<DIDL-Lite/>',
      });
      final out = await call('GetMediaInfo');
      final values = _m(out);
      expect(values['NrTracks'], '1');
      expect(values['CurrentURI'], 'http://x/v.mp4');
      expect(values['PlayMedium'], 'NETWORK');
    });
  });

  group('SOAP 报文 ←→ 自家发送端解析互操作', () {
    test('响应可被 parseSoapResponse 解析（三模式第 1 模式）', () async {
      stub.duration = const Duration(minutes: 10);
      await call('SetAVTransportURI', const {
        'InstanceID': '0',
        'CurrentURI': 'http://x/v.mp4',
        'CurrentURIMetaData': '',
      });
      await call('Play');
      final body = soapResponseXml(
        ReceiverService.avTransport.type,
        'GetTransportInfo',
        await call('GetTransportInfo'),
      );
      final values = parseSoapResponse(body, 'GetTransportInfo');
      expect(values['CurrentTransportState'], 'PLAYING');
      expect(values['CurrentTransportStatus'], 'OK');
      expect(values['CurrentSpeed'], '1');
    });

    test('fault 可被 parseSoapFault 识别（含 UPnP errorCode）', () {
      final body = soapFaultXml(const ReceiverFault(402, 'Invalid Args'));
      final fault = parseSoapFault(body);
      expect(fault, isNotNull);
      expect(body, contains('<errorCode>402</errorCode>'));
      // UPnP 标准形状：faultcode s:Client + UPnPError 命名空间。
      expect(body, contains('urn:schemas-upnp-org:control-1-0'));
      expect(fault!.$1, 's:Client');
    });

    test('parseSoapRequest：SOAPACTION 头引号剥离 + 动作名回退', () {
      final action = parseSoapRequest(
        '<?xml version="1.0"?><s:Envelope '
        'xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>'
        '<u:Play xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '<InstanceID>0</InstanceID><Speed>1</Speed></u:Play>'
        '</s:Body></s:Envelope>',
        '"urn:schemas-upnp-org:service:AVTransport:1#Play"',
      );
      expect(action!.name, 'Play');
      expect(action.args['InstanceID'], '0');
      expect(action.args['Speed'], '1');

      // 体不可解析时回退 SOAPACTION 头。
      final fallback = parseSoapRequest('not-xml', '"urn:x#Stop"');
      expect(fallback!.name, 'Stop');
      expect(fallback.args, isEmpty);
      expect(parseSoapRequest('not-xml', null), isNull);
    });

    test('SOAP 1.2 信封（同构 Body）也可解析', () {
      final action = parseSoapRequest(
        '<?xml version="1.0"?><s:Envelope '
        'xmlns:s="http://www.w3.org/2003/05/soap-envelope"><s:Body>'
        '<u:Stop xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '<InstanceID>0</InstanceID></u:Stop></s:Body></s:Envelope>',
        null,
      );
      expect(action!.name, 'Stop');
    });

    test('串行排队：Play 不会插进 SetAVTransportURI 的加载窗口', () async {
      final slow = StubReceiverPlayer(loadDelay: const Duration(milliseconds: 60));
      final queued = ReceiverRenderer(player: slow);
      // 不 await Set，先占队列；紧随的 GetTransportInfo 必须等它完成。
      final setFuture = queued.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('SetAVTransportURI', {
          'InstanceID': '0',
          'CurrentURI': 'http://x/v.mp4',
          'CurrentURIMetaData': '',
        }),
      );
      final infoFuture = queued.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('GetTransportInfo', {'InstanceID': '0'}),
      );
      await setFuture;
      final out = await infoFuture;
      expect(
        _m(out)['CurrentTransportState'],
        'STOPPED',
        reason: '排队语义下查询发生在 load 完成之后',
      );
    });
  });
}
