import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

void main() {
  const udn = '3f2a1b9c-1111-4222-8333-000000000001';
  final xml = receiverDeviceDescription(
    friendlyName: 'DESKTOP-ABC（aquan 接收）',
    udn: udn,
  );

  group('设备描述 ←→ 自家 DlnaDevice 解析回归（AC-2 硬门槛）', () {
    test('完整 LOCATION：friendlyName / UDN / 三服务 controlURL / eventSubURL', () {
      final location = 'http://192.168.1.5:18099/description.xml';
      final device = parseDeviceDescription(xml, location);
      expect(device, isNotNull);
      expect(device!.friendlyName, 'DESKTOP-ABC（aquan 接收）');
      expect(device.udn, 'uuid:$udn');
      expect(device.modelName, 'aquan-duanju');
      expect(device.manufacturer, 'aquan');
      expect(
        device.serviceType,
        'urn:schemas-upnp-org:service:AVTransport:1',
      );
      expect(device.controlUrl, 'http://192.168.1.5:18099/AVTransport/control');
      expect(
        device.renderingControlUrl,
        'http://192.168.1.5:18099/RenderingControl/control',
      );
      expect(
        device.connectionManagerUrl,
        'http://192.168.1.5:18099/ConnectionManager/control',
      );
      expect(device.eventSubUrl, 'http://192.168.1.5:18099/AVTransport/event');
    });

    test('authority-only LOCATION + 相对 controlURL：解析基址仍正确', () {
      final device = parseDeviceDescription(xml, 'http://192.168.1.5:18099');
      expect(device, isNotNull);
      expect(device!.controlUrl, 'http://192.168.1.5:18099/AVTransport/control');
      expect(
        device.renderingControlUrl,
        'http://192.168.1.5:18099/RenderingControl/control',
      );
      expect(device.eventSubUrl, 'http://192.168.1.5:18099/AVTransport/event');
    });

    test('扁平单 device（无 embedded），friendlyName 转义可还原', () {
      final doc = XmlDocument.parse(xml);
      expect(doc.rootElement.name.local, 'root');
      final devices = doc.rootElement.descendantElements
          .where((e) => e.name.local == 'device')
          .toList();
      expect(devices.length, 1, reason: '保持扁平形状，解析器认领路径最短');
      final services = doc.rootElement.descendantElements
          .where((e) => e.name.local == 'serviceType')
          .map((e) => e.innerText)
          .toList();
      expect(services.length, 3);
      expect(
        receiverDeviceDescription(friendlyName: '带"<&>"的名字', udn: udn),
        contains('带&quot;&lt;&amp;&gt;&quot;的名字'),
      );
    });
  });

  group('SCPD', () {
    test('三份 SCPD 均为良构 XML 且动作齐全', () {
      final avtActions = _actionNames(ReceiverService.avTransport);
      expect(
        avtActions,
        containsAll(<String>[
          'SetAVTransportURI',
          'Play',
          'Pause',
          'Stop',
          'Seek',
          'GetTransportInfo',
          'GetPositionInfo',
          'GetMediaInfo',
        ]),
      );
      expect(
        _actionNames(ReceiverService.renderingControl),
        containsAll(<String>['GetVolume', 'SetVolume', 'GetMute', 'SetMute']),
      );
      expect(
        _actionNames(ReceiverService.connectionManager),
        containsAll(<String>['GetProtocolInfo']),
      );
    });

    test('TransportState 变量覆盖五个状态（设计状态机表）', () {
      final doc = XmlDocument.parse(receiverScpd(ReceiverService.avTransport));
      final variable = doc.rootElement.descendantElements.firstWhere(
        (e) =>
            e.name.local == 'stateVariable' &&
            e.childElements.any((c) =>
                c.name.local == 'name' && c.innerText == 'TransportState'),
      );
      final allowed = variable.descendantElements
          .where((e) => e.name.local == 'allowedValue')
          .map((e) => e.innerText)
          .toList();
      expect(
        allowed,
        containsAll(<String>[
          'NO_MEDIA_PRESENT',
          'TRANSITIONING',
          'PLAYING',
          'PAUSED_PLAYBACK',
          'STOPPED',
        ]),
      );
      // LastChange 是事件化变量（GENA 初始事件依赖）。
      final lastChange = doc.rootElement.descendantElements.firstWhere(
        (e) =>
            e.name.local == 'stateVariable' &&
            e.childElements.any((c) =>
                c.name.local == 'name' && c.innerText == 'LastChange'),
      );
      expect(
        lastChange.getAttribute('sendEvents'),
        'yes',
      );
    });
  });

  group('uuidV4 / Sink 声明', () {
    test('uuid v4 形状与随机性', () {
      final pattern = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      final a = uuidV4();
      final b = uuidV4();
      expect(pattern.hasMatch(a), isTrue, reason: a);
      expect(pattern.hasMatch(b), isTrue, reason: b);
      expect(a, isNot(b));
    });

    test('Sink 覆盖发送端常用容器清单（HLS / TS / MP4 / MKV）', () {
      for (final mime in <String>[
        'video/mp4',
        'video/x-matroska',
        'video/MP2T',
        'application/vnd.apple.mpegurl',
        'application/dash+xml',
        'video/x-flv',
      ]) {
        expect(receiverSinkProtocolInfo.split(','), contains('http-get:*:$mime:*'));
      }
    });
  });
}

List<String> _actionNames(ReceiverService service) {
  final doc = XmlDocument.parse(receiverScpd(service));
  return doc.rootElement.descendantElements
      .where((e) => e.name.local == 'action')
      .map(
        (a) => a.childElements
            .firstWhere((c) => c.name.local == 'name')
            .innerText,
      )
      .toList();
}
