import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:multicast_dns/multicast_dns.dart';

import 'package:aquan_duanju/core/cast/airplay/airplay_transport.dart';
import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/mdns_discovery.dart';
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

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    calls.add('setUri:$url');
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

/// mDNS 假客户端：按 query 类型回固定记录（记录收到的 query 供断言）。
class _FakeMdnsClient implements MDnsClient {
  _FakeMdnsClient({this.ptrNames = const []});

  final List<String> ptrNames;
  final queries = <String>[];

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {}

  @override
  Stream<T> lookup<T extends ResourceRecord>(ResourceRecordQuery query,
      {Duration timeout = const Duration(seconds: 5)}) {
    queries.add(
        '${query.resourceRecordType}:${query.fullyQualifiedName}');
    switch (query.resourceRecordType) {
      case ResourceRecordType.serverPointer:
        return Stream.fromIterable([
          for (final name in ptrNames) PtrResourceRecord(name, 100, domainName: name),
        ]).cast<T>();
      case ResourceRecordType.service:
        return Stream.value(SrvResourceRecord(
          query.fullyQualifiedName,
          100,
          target: 'dev.local',
          port: 7000,
          priority: 0,
          weight: 0,
        )).cast<T>();
      case ResourceRecordType.addressIPv4:
        return Stream.value(IPAddressResourceRecord(
          query.fullyQualifiedName,
          100,
          address: InternetAddress('192.168.1.77'),
        )).cast<T>();
      case ResourceRecordType.text:
        return Stream.value(TxtResourceRecord(
          query.fullyQualifiedName,
          100,
          text: 'deviceid=AA:BB:CC:DD:EE:FF\nam=AppleTV3,2\nsrcvers=220.68\n',
        )).cast<T>();
      default:
        return const Stream.empty();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('mDNS `_airplay._tcp` 发现', () {
    test('PTR→SRV→A→TXT 解析 → AirPlayDeviceInfo（deviceid/am）', () async {
      final client = _FakeMdnsClient(
        ptrNames: ['客厅 Apple TV._airplay._tcp.local'],
      );
      final devices = await MdnsDiscovery.discoverAirplay(
        clientOverride: client,
        rounds: 1,
      ).toList();
      expect(devices, hasLength(1));
      final d = devices.first;
      expect(d.host, '192.168.1.77');
      expect(d.port, 7000);
      expect(d.name, '客厅 Apple TV');
      expect(d.deviceId, 'AA:BB:CC:DD:EE:FF');
      expect(d.modelName, 'AppleTV3,2');
      // 查询的就是 _airplay 服务类型（一期不收 _raop）。
      expect(client.queries.first,
          '${ResourceRecordType.serverPointer}:_airplay._tcp.local');
    });

    test('串入的 `_raop` / 其它类型 PTR 被过滤（宁缺勿错）', () async {
      final client = _FakeMdnsClient(ptrNames: [
        '卧室音箱._raop._tcp.local',
        'not-airplay._googlecast._tcp.local',
      ]);
      final devices = await MdnsDiscovery.discoverAirplay(
        clientOverride: client,
        rounds: 1,
      ).toList();
      expect(devices, isEmpty);
    });
  });

  group('AirPlayDeviceInfo → CastTarget', () {
    test('id 稳定：优先 deviceid，缺省回落 host:port', () {
      const info = AirPlayDeviceInfo(
        host: '192.168.1.77',
        port: 7000,
        name: '客厅 Apple TV',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        modelName: 'AppleTV3,2',
      );
      final t = CastTarget.airplay(info);
      expect(t.id, 'airplay:AA:BB:CC:DD:EE:FF');
      expect(t.protocol, CastProtocol.airplay);
      expect(t.host, '192.168.1.77');
      expect(t.name, '客厅 Apple TV');
      expect(t.modelName, 'AppleTV3,2');

      const noId = AirPlayDeviceInfo(host: '192.168.1.78', port: 7000);
      expect(CastTarget.airplay(noId).id, 'airplay:192.168.1.78:7000');
      // name 为空回落 host。
      expect(CastTarget.airplay(noId).name, '192.168.1.78');
      // 同 host:port 等价（upsert 语义）。
      expect(CastTarget.airplay(info), CastTarget.airplay(info));
    });

    test('持久化往返：新值 airplay 往返一致', () {
      const info = AirPlayDeviceInfo(
        host: '192.168.1.77',
        port: 7000,
        name: '客厅 Apple TV',
        deviceId: 'AA:BB:CC:DD:EE:FF',
        modelName: 'AppleTV3,2',
      );
      final json = CastTarget.airplay(info).toPersistJson();
      expect(json['protocol'], 'airplay');
      final restored = CastTarget.fromPersistJson(json);
      expect(restored?.protocol, CastProtocol.airplay);
      expect(restored?.id, 'airplay:AA:BB:CC:DD:EE:FF');
      expect(restored?.host, '192.168.1.77');
      expect(restored?.name, '客厅 Apple TV');
      expect(restored?.modelName, 'AppleTV3,2');
    });

    test('旧 JSON（dlna/chromecast）读取不受新枚举影响', () {
      final dlna = CastTarget.fromPersistJson({
        'udn': 'u1',
        'name': '旧电视',
        'control_url': 'http://192.168.1.9/ctrl',
        'location': 'http://192.168.1.9/desc.xml',
      });
      expect(dlna?.protocol, CastProtocol.dlna);
      final cast = CastTarget.fromPersistJson({
        'protocol': 'chromecast',
        'host': '192.168.1.50',
        'port': 8009,
        'name': '谷歌电视',
      });
      expect(cast?.protocol, CastProtocol.chromecast);
    });
  });

  group('transport 工厂与同 IP 降级链', () {
    test('defaultTransportFactory 按 airplay 分派', () {
      const info = AirPlayDeviceInfo(host: '192.168.1.77', port: 7000);
      final transport = defaultTransportFactory(CastTarget.airplay(info));
      expect(transport, isA<AirPlayTransport>());
    });

    test('降级链位次：dlna → chromecast → airplay（airplay 末位）', () async {
      // 同 IP 三协议：dlna 失败 → 应落 chromecast（跳过末位的 airplay）。
      final transports = <CastProtocol, FakeTransport>{
        CastProtocol.dlna: FakeTransport()..failSetUri = true,
        CastProtocol.chromecast: FakeTransport(),
        CastProtocol.airplay: FakeTransport(),
      };
      final controller = CastController(
        transportFactory: (t) => transports[t.protocol]!,
        mdnsDiscover: () => Stream.value(
          const CastDeviceInfo(host: '192.168.1.9', name: '谷歌电视'),
        ),
        airplayDiscover: () => Stream.value(
          const AirPlayDeviceInfo(host: '192.168.1.9', name: '客厅 Apple TV'),
        ),
      );
      addTearDown(controller.dispose);
      controller.startScan();
      await Future<void>.delayed(Duration.zero);
      controller.stopScan();
      expect(controller.devices, hasLength(2));

      await controller.castTo(
        CastTarget.dlna(_dlna('d1', '192.168.1.9')),
        const CastMedia(url: 'http://x/1.mp4', title: 't'),
      );
      expect(controller.currentDevice?.protocol, CastProtocol.chromecast,
          reason: 'dlna 失败 → 同 IP chromecast（airplay 排末位不参与首轮降级）');
      expect(transports[CastProtocol.airplay]!.calls, isEmpty);
    });

    test('只剩 airplay 可降级时投 airplay', () async {
      final chromecast = FakeTransport()..failSetUri = true;
      final airplay = FakeTransport();
      final controller = CastController(
        transportFactory: (t) => switch (t.protocol) {
          CastProtocol.chromecast => chromecast,
          CastProtocol.airplay => airplay,
          _ => FakeTransport()..failSetUri = true,
        },
        airplayDiscover: () => Stream.value(
          const AirPlayDeviceInfo(host: '192.168.1.9', name: '客厅 Apple TV'),
        ),
      );
      addTearDown(controller.dispose);
      controller.startScan();
      await Future<void>.delayed(Duration.zero);
      controller.stopScan();

      await controller.castTo(
        CastTarget.chromecast(const CastDeviceInfo(
          host: '192.168.1.9',
          name: '谷歌电视',
        )),
        const CastMedia(url: 'http://x/1.mp4', title: 't'),
      );
      expect(controller.currentDevice?.protocol, CastProtocol.airplay,
          reason: 'chromecast 失败 → 同 IP airplay（末位兜底）');
      expect(airplay.calls.first, startsWith('setUri:'));
    });
  });

  group('CastStore lastDevice 持久化（airplay）', () {
    test('airplay 设备往返；旧 dlna/chromecast 读取不变', () async {
      final dir = await Directory.systemTemp.createTemp('cast_store_airplay');
      addTearDown(() => dir.delete(recursive: true));

      final store = CastStore(testDirectory: dir);
      await store.loadFromDisk();
      const info = AirPlayDeviceInfo(
        host: '192.168.1.77',
        port: 7000,
        name: '客厅 Apple TV',
        deviceId: 'AA:BB:CC:DD:EE:FF',
      );
      await store.touchLast(CastTarget.airplay(info));
      expect(store.lastDevice?.protocol, CastProtocol.airplay);
      expect(store.lastDevice?.id, 'airplay:AA:BB:CC:DD:EE:FF');

      final store2 = CastStore(testDirectory: dir);
      await store2.loadFromDisk();
      expect(store2.lastDevice?.protocol, CastProtocol.airplay);
      expect(store2.lastDevice?.host, '192.168.1.77');
      expect(store2.lastDevice?.name, '客厅 Apple TV');
      expect(store2.lastDevice?.modelName, '');
    });

    test('无 deviceid 的 airplay 设备：id 用 host:port 往返', () async {
      final dir = await Directory.systemTemp.createTemp('cast_store_airplay2');
      addTearDown(() => dir.delete(recursive: true));
      final store = CastStore(testDirectory: dir);
      await store.loadFromDisk();
      await store.touchLast(CastTarget.airplay(
        const AirPlayDeviceInfo(host: '192.168.1.80', port: 7000, name: 'UxPlay'),
      ));
      final store2 = CastStore(testDirectory: dir);
      await store2.loadFromDisk();
      expect(store2.lastDevice?.id, 'airplay:192.168.1.80:7000');
    });
  });
}
