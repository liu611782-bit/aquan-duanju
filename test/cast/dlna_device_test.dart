import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

void main() {
  group('parseDeviceDescription', () {
    const description = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.23:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>客厅电视</friendlyName>
    <modelName>MI TV 3</modelName>
    <UDN>uuid:abcd-1234</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/AVT</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/RCS</controlURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/dev/abcd-1234/ctrl/CM</controlURL>
      </service>
    </serviceList>
  </device>
</root>
''';

    test('解析设备信息 + 相对 controlURL 按 URLBase 还原', () {
      final device =
          parseDeviceDescription(description, 'http://192.168.1.23:49152/desc.xml');
      expect(device, isNotNull);
      expect(device!.friendlyName, '客厅电视');
      expect(device.modelName, 'MI TV 3');
      expect(device.udn, 'uuid:abcd-1234');
      expect(device.controlUrl, 'http://192.168.1.23:49152/dev/abcd-1234/ctrl/AVT');
      expect(device.renderingControlUrl,
          'http://192.168.1.23:49152/dev/abcd-1234/ctrl/RCS');
    });

    test('无 URLBase 时按 LOCATION 还原相对路径', () {
      final withoutBase = description.replaceFirst(
          '<URLBase>http://192.168.1.23:49152</URLBase>', '');
      final device = parseDeviceDescription(
          withoutBase, 'http://192.168.1.23:49152/desc.xml');
      expect(device!.controlUrl,
          'http://192.168.1.23:49152/dev/abcd-1234/ctrl/AVT');
    });

    test('没有 AVTransport 服务 → null（非投屏目标）', () {
      final noAvt = description.replaceFirst(
          RegExp(r'<service>.*?AVTransport.*?</service>', dotAll: true), '');
      expect(parseDeviceDescription(noAvt, 'http://x/desc.xml'), isNull);
    });

    test('非法 XML → null', () {
      expect(parseDeviceDescription('<不是xml', 'http://x/'), isNull);
    });
  });

  group('buildDidlLite', () {
    test('标题转义 + 可选时长', () {
      final didl = buildDidlLite(title: '剧名 · <第3集> "特别版"');
      expect(didl, contains('&lt;第3集&gt;'));
      expect(didl, contains('&quot;特别版&quot;'));
      expect(didl, isNot(contains('duration=')));

      final withDuration =
          buildDidlLite(title: 'x', duration: '0:02:15.000');
      expect(withDuration, contains('duration="0:02:15.000"'));
      expect(withDuration, contains('object.item.videoItem'));
    });
  });

  group('embedded device / ConnectionManager / manufacturer', () {
    const embedded = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <URLBase>http://192.168.1.77:49152</URLBase>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaServer:1</deviceType>
    <friendlyName>根设备（不是渲染器）</friendlyName>
    <manufacturer>RootVendor</manufacturer>
    <modelName>RootModel</modelName>
    <UDN>uuid:root-device</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/cm/control</controlURL>
      </service>
    </serviceList>
    <deviceList>
      <device>
        <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
        <friendlyName>客厅盒子</friendlyName>
        <manufacturer>HiSilicon</manufacturer>
        <modelName>Hisilicon MediaRenderer</modelName>
        <UDN>uuid:embedded-renderer</UDN>
        <serviceList>
          <service>
            <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
            <controlURL>/avt/control</controlURL>
            <eventSubURL>/avt/event</eventSubURL>
          </service>
          <service>
            <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
            <controlURL>/rcs/control</controlURL>
          </service>
        </serviceList>
      </device>
    </deviceList>
  </device>
</root>
''';

    test('用命中 AVTransport 的 embedded device 的 friendlyName/UDN/manufacturer',
        () {
      final device = parseDeviceDescription(
          embedded, 'http://192.168.1.77:49152/desc.xml');
      expect(device, isNotNull);
      expect(device!.friendlyName, '客厅盒子');
      expect(device.udn, 'uuid:embedded-renderer');
      expect(device.modelName, 'Hisilicon MediaRenderer');
      expect(device.manufacturer, 'HiSilicon');
      expect(device.controlUrl, 'http://192.168.1.77:49152/avt/control');
      expect(device.renderingControlUrl,
          'http://192.168.1.77:49152/rcs/control');
      expect(device.eventSubUrl, 'http://192.168.1.77:49152/avt/event');
    });

    test('ConnectionManager controlURL 被带出（GetProtocolInfo 预检用）', () {
      final device = parseDeviceDescription(
          embedded, 'http://192.168.1.77:49152/desc.xml');
      expect(device!.connectionManagerUrl,
          'http://192.168.1.77:49152/cm/control');
    });

    test('只有 ConnectionManager 而无 AVTransport → 仍返回 null', () {
      const cmOnly = '''
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>仅连接管理</friendlyName>
    <UDN>uuid:cm-only</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <controlURL>/cm/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      expect(parseDeviceDescription(cmOnly, 'http://x/desc.xml'), isNull);
    });

    test('缺 manufacturer 的旧描述 → 缺省空串', () {
      const plain = '''
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <friendlyName>老电视</friendlyName>
    <UDN>uuid:plain</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>/avt/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final device =
          parseDeviceDescription(plain, 'http://192.168.1.23:49152/desc.xml');
      expect(device!.manufacturer, '');
      expect(device.connectionManagerUrl, '');
    });
  });

  group('v1/v2 JSON 往返', () {
    test('缺新字段的旧 json 可读，缺省空串；新写入带字段', () {
      final old = DlnaDevice.fromPersistJson(<String, dynamic>{
        'udn': 'uuid:old',
        'name': '旧电视',
        'model': 'X',
        'control_url': 'http://192.168.1.9/ctrl',
        'rendering_control_url': '',
        'location': 'http://192.168.1.9/desc.xml',
      });
      expect(old.manufacturer, '');
      expect(old.connectionManagerUrl, '');
      expect(old.eventSubUrl, '');

      final json = old.toPersistJson();
      expect(json['manufacturer'], '');
      expect(json['connection_manager_url'], '');
      // CastTarget 侧仍能按 dlna 解析（v1 无 protocol 字段）。
      final target = CastTarget.fromPersistJson(json);
      expect(target?.protocol, CastProtocol.dlna);
      expect(target?.manufacturer, '');
      expect(target?.id, 'uuid:old', reason: 'id 语义不变：dlna = UDN');
    });

    test('新字段往返不丢', () {
      final device = DlnaDevice(
        udn: 'uuid:new',
        friendlyName: '新电视',
        modelName: 'M',
        manufacturer: 'Vendor',
        controlUrl: 'http://192.168.1.9/ctrl',
        connectionManagerUrl: 'http://192.168.1.9/cm',
      );
      final back = DlnaDevice.fromPersistJson(device.toPersistJson());
      expect(back.manufacturer, 'Vendor');
      expect(back.connectionManagerUrl, 'http://192.168.1.9/cm');
      expect(CastTarget.dlna(back).manufacturer, 'Vendor');
    });
  });
}
