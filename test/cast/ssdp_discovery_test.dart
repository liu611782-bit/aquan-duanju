import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';

/// 可注入的描述拉取器：按 URL 计数、可整体切换为失败（预算/复活/复检用）。
class _FakeFetcher implements DescriptionFetcher {
  final Map<String, int> calls = {};
  bool failAll = false;

  @override
  Future<String> fetchDescription(String url) async {
    calls[url] = (calls[url] ?? 0) + 1;
    if (failAll) {
      throw const HttpException('模拟设备离线');
    }
    return _deviceDescription;
  }
}

const String _location = 'http://192.168.1.23:49152/desc.xml';
const String _usn =
    'uuid:abcd-1234::urn:schemas-upnp-org:device:MediaRenderer:1';
const String _udn = 'uuid:abcd-1234';

const String _deviceDescription = '''
<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
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
    </serviceList>
  </device>
</root>
''';

String _notifyAlive({String usn = _usn, String? location}) =>
    'NOTIFY * HTTP/1.1\r\nNTS: ssdp:alive\r\n'
    'LOCATION: ${location ?? _location}\r\nUSN: $usn\r\n\r\n';

String _notifyByebye({String usn = _usn}) =>
    'NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: $usn\r\n\r\n';

void main() {
  group('buildSearchPacket', () {
    test('M-SEARCH 报文格式（CineFlow 同款）', () {
      final packet =
          buildSearchPacket('urn:schemas-upnp-org:device:MediaRenderer:1');
      expect(packet.startsWith('M-SEARCH * HTTP/1.1\r\n'), isTrue);
      expect(packet, contains('HOST: 239.255.255.250:1900'));
      expect(packet, contains('MAN: "ssdp:discover"'));
      expect(packet, contains('MX: 2'));
      expect(packet, contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1'));
      expect(packet.endsWith('\r\n\r\n'), isTrue);
    });

    test('M8：M-SEARCH 带 USER-AGENT 三连（MRDLNA 实证带 UA 更稳）', () {
      final packet = buildSearchPacket('upnp:rootdevice');
      expect(packet, contains('USER-AGENT: aquan-duanju/'));
      expect(packet, contains('UPnP/1.1'));
      expect(packet, contains('HX-USER-AGENT: aquan-duanju/'));
      expect(packet, contains('X-USER-AGENT: aquan-duanju/'));
    });
  });

  group('ssdpSearchTargets（M8 ST 集合）', () {
    test('既有三目标保留，追加 AVTransport:1', () {
      expect(ssdpSearchTargets,
          contains('urn:schemas-upnp-org:device:MediaRenderer:1'));
      expect(ssdpSearchTargets, contains('upnp:rootdevice'));
      expect(ssdpSearchTargets, contains('ssdp:all'));
      expect(ssdpSearchTargets,
          contains('urn:schemas-upnp-org:service:AVTransport:1'));
    });
  });

  group('multicastBindCandidates（M8 多网卡）', () {
    InternetAddress v4(String s) =>
        InternetAddress(s, type: InternetAddressType.IPv4);

    test('虚拟网卡 / 回环 / IPv6 不参与绑定，普通网卡保留', () {
      final candidates = SsdpDiscovery.multicastBindCandidates([
        ('以太网', [v4('192.168.1.5')]),
        ('vEthernet (WSL)', [v4('172.20.0.1')]),
        ('VMware Network Adapter VMnet8', [v4('192.168.88.1')]),
        ('Tailscale', [v4('100.64.0.2')]),
        ('lo', [InternetAddress.loopbackIPv4]),
        ('WLAN 6', [InternetAddress('fe80::1', type: InternetAddressType.IPv6)]),
      ]);
      expect(candidates.map((c) => c.$2.address), ['192.168.1.5']);
    });

    test('同网卡多 IPv4 地址都保留', () {
      final candidates = SsdpDiscovery.multicastBindCandidates([
        ('以太网', [v4('192.168.1.5'), v4('10.0.0.5')]),
      ]);
      expect(candidates.length, 2);
    });
  });

  group('SsdpDiscovery 状态机（注入报文驱动）', () {
    late SsdpDiscovery discovery;
    late _FakeFetcher fetcher;
    late List<SsdpEvent> events;

    setUp(() {
      fetcher = _FakeFetcher();
      discovery = SsdpDiscovery(clientFactory: () => fetcher);
      events = <SsdpEvent>[];
      // start() 在绑定前同步创建事件控制器：先订阅再注入报文（broadcast
      // 控制器不会给后到的监听器补发事件）。
      discovery.start().listen(events.add, cancelOnError: false);
      return Future<void>.delayed(const Duration(milliseconds: 20));
    });

    tearDown(() {
      return discovery.stop();
    });

    Future<void> settle() =>
        Future<void>.delayed(const Duration(milliseconds: 20));

    test('M8 复活路径：byebye 移出设备时同步清理 LOCATION，复线可重新拉描述',
        () async {
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      expect(events.whereType<SsdpDeviceFound>().length, 1);
      expect(fetcher.calls[_location], 1);

      discovery.handlePacketForTest(_notifyByebye());
      await settle();
      expect(events.whereType<SsdpDeviceOffline>().length, 1);

      // 复线：alive NOTIFY 再次到达 → 重新拉描述、重新入表。
      // （修复前：location 永留 pending，这里被挡回，设备永远消失。）
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      expect(events.whereType<SsdpDeviceFound>().length, 2,
          reason: '复线设备应重新被发现');
      expect(fetcher.calls[_location], 2);
    });

    test('M8 复活路径（TTL 清理/复检）：连得上续期，连不上立即离线且可复活',
        () async {
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      expect(events.whereType<SsdpDeviceFound>().length, 1);

      // TTL 到期 → 描述 URL 复检成功（设备只是不发明语了）→ 续期保留。
      discovery.expireDeviceForTest(_udn);
      discovery.sweepForTest();
      await settle();
      expect(discovery.devices.map((d) => d.udn), contains(_udn));
      expect(events.whereType<SsdpDeviceOffline>(), isEmpty,
          reason: '描述 URL 连得上：不应判离线');
      expect(fetcher.calls[_location], 2, reason: '复检走了一次 GET');

      // 复检失败（连不上）→ 立即离线（不干等下一轮 TTL），复活路径就位。
      fetcher.failAll = true;
      discovery.expireDeviceForTest(_udn);
      discovery.sweepForTest();
      await settle();
      expect(events.whereType<SsdpDeviceOffline>().length, 1);
      expect(discovery.devices.map((d) => d.udn), isNot(contains(_udn)));

      // 复线：立即重新拉描述入表。
      fetcher.failAll = false;
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      expect(events.whereType<SsdpDeviceFound>().length, 2);
    });

    test('M8 回环过滤：127.x 源的报文不计入设备列表', () async {
      discovery.handlePacketForTest(
        _notifyAlive(),
        source: InternetAddress.loopbackIPv4,
      );
      await settle();
      expect(fetcher.calls, isEmpty);
      expect(discovery.devices, isEmpty);
      expect(events.whereType<SsdpDeviceFound>(), isEmpty);
    });

    test('M8 发现期预算：同一 LOCATION 最多 2 次 GET，之后换下一条 advertisement',
        () async {
      fetcher.failAll = true;
      // 第 1、2 次 NOTIFY 各触发一次拉取（失败放行重试）。
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      // 第 3 次起被预算挡回（不再打同一个 URL）。
      discovery.handlePacketForTest(_notifyAlive());
      await settle();
      expect(fetcher.calls[_location] ?? 0, maxFetchAttemptsPerUrl);
      expect(discovery.devices, isEmpty);
      expect(events.whereType<SsdpDeviceFound>(), isEmpty);
    });
  });

  group('parseSsdpHeaders', () {
    test('M-SEARCH 响应（大小写混合键 → 统一大写键）', () {
      const text = 'HTTP/1.1 200 OK\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'EXT:\r\n'
          'location: http://192.168.1.23:49152/description.xml\r\n'
          'ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n'
          'USN: uuid:abc::urn:1\r\n'
          '\r\n';
      final headers = parseSsdpHeaders(text);
      expect(headers, isNotNull);
      expect(headers!['LOCATION'], 'http://192.168.1.23:49152/description.xml');
      expect(headers['USN'], 'uuid:abc::urn:1');
    });

    test('NOTIFY alive / byebye', () {
      const alive = 'NOTIFY * HTTP/1.1\r\nNTS: ssdp:alive\r\n'
          'LOCATION: http://x/desc.xml\r\nUSN: uuid:1\r\n\r\n';
      const byebye =
          'NOTIFY * HTTP/1.1\r\nNTS: ssdp:byebye\r\nUSN: uuid:1\r\n\r\n';
      expect(parseSsdpHeaders(alive)!['NTS'], 'ssdp:alive');
      expect(parseSsdpHeaders(byebye)!['NTS'], 'ssdp:byebye');
    });

    test('非 SSDP 报文 → null', () {
      expect(parseSsdpHeaders('random udp garbage'), isNull);
    });
  });
}
