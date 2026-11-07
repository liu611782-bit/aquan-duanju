import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';
import 'package:aquan_duanju/core/castd/receiver_ssdp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ReceiverSsdp.parseSearch', () {
    const search = 'M-SEARCH * HTTP/1.1\r\n'
        'HOST: 239.255.255.250:1900\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: ssdp:all\r\n'
        '\r\n';

    test('标准 M-SEARCH：ST + MX（钳 0..5）', () {
      final s = ReceiverSsdp.parseSearch(search);
      expect(s, isNotNull);
      expect(s!.searchTarget, 'ssdp:all');
      expect(s.maxWaitSec, 2);
      expect(ReceiverSsdp.parseSearch(search.replaceFirst('MX: 2', 'MX: 99'))!
          .maxWaitSec, 5);
      expect(ReceiverSsdp.parseSearch(search.replaceFirst('MX: 2', 'MX: -3'))!
          .maxWaitSec, 0);
    });

    test('纯 \\n 分隔与大小写混合也识别', () {
      final loose = search.replaceAll('\r\n', '\n').replaceFirst('M-SEARCH', 'm-search');
      expect(ReceiverSsdp.parseSearch(loose), isNotNull);
    });

    test('非 M-SEARCH / 缺 MAN / 缺 ST → null', () {
      expect(ReceiverSsdp.parseSearch('NOTIFY * HTTP/1.1\r\nNT: upnp:event\r\n\r\n'),
          isNull);
      expect(ReceiverSsdp.parseSearch('HTTP/1.1 200 OK\r\nST: ssdp:all\r\n\r\n'),
          isNull);
      expect(
        ReceiverSsdp.parseSearch(search.replaceFirst('MAN: "ssdp:discover"\r\n', '')),
        isNull,
      );
      expect(ReceiverSsdp.parseSearch(search.replaceFirst('ST: ssdp:all\r\n', '')),
          isNull);
      expect(ReceiverSsdp.parseSearch('垃圾数据'), isNull);
    });
  });

  group('报文形状（AC-1）', () {
    const udn = 'test-udn-1';
    final all = ReceiverSsdp.targets(udn);

    test('targets：rootdevice / uuid / MediaRenderer / 三服务，USN 形状', () {
      expect(all.length, 6);
      expect(all[0].$1, 'upnp:rootdevice');
      expect(all[0].$2, 'uuid:$udn::upnp:rootdevice');
      expect(all[1].$1, 'uuid:$udn');
      expect(all[1].$2, 'uuid:$udn');
      expect(all[2].$1, ReceiverSsdp.mediaRenderer);
      expect(
        all[2].$2,
        'uuid:$udn::urn:schemas-upnp-org:device:MediaRenderer:1',
      );
      expect(all[3].$1, ReceiverSsdp.avTransport);
      expect(all[5].$1, ReceiverSsdp.connectionManager);
    });

    test('M-SEARCH 应答含 PRD R1.1 全部头，可被自家 parseSsdpHeaders 解析', () {
      final packet = ReceiverSsdp.searchResponse(
        all[2],
        'http://192.168.1.5:18099/description.xml',
        now: DateTime.utc(2026, 11, 7, 12, 0, 0),
      );
      expect(packet, endsWith('\r\n\r\n'));
      expect(packet.startsWith('HTTP/1.1 200 OK\r\n'), isTrue);
      final headers = parseSsdpHeaders(packet);
      expect(headers, isNotNull);
      expect(headers!['ST'], ReceiverSsdp.mediaRenderer);
      expect(
        headers['USN'],
        'uuid:$udn::urn:schemas-upnp-org:device:MediaRenderer:1',
      );
      expect(headers['LOCATION'], 'http://192.168.1.5:18099/description.xml');
      expect(headers['CACHE-CONTROL'], 'max-age=1800');
      expect(headers['DATE'], contains('Nov 2026'));
      expect(headers['EXT'], '');
      expect(headers['SERVER'], contains('UPnP/1.0'));
      expect(headers['SERVER'], contains('aquan-duanju'));
    });

    test('alive：NOTIFY * + HOST + NT/NTS/USN + LOCATION；byebye 无 LOCATION', () {
      final alive = ReceiverSsdp.alive(all[0], 'http://192.168.1.5:18099/description.xml');
      expect(alive.startsWith('NOTIFY * HTTP/1.1\r\n'), isTrue);
      final h = parseSsdpHeaders(alive)!;
      expect(h['HOST'], '239.255.255.250:1900');
      expect(h['NT'], 'upnp:rootdevice');
      expect(h['NTS'], 'ssdp:alive');
      expect(h['USN'], 'uuid:$udn::upnp:rootdevice');
      expect(h['CACHE-CONTROL'], 'max-age=1800');
      expect(h['LOCATION'], isNotEmpty);

      final bye = ReceiverSsdp.byeBye(all[0]);
      final hb = parseSsdpHeaders(bye)!;
      expect(hb['NTS'], 'ssdp:byebye');
      expect(hb.containsKey('LOCATION'), isFalse);
      expect(hb['USN'], 'uuid:$udn::upnp:rootdevice');
    });

    test('matches：ssdp:all 命中全部；具体 ST 命中一组；未知 ST 空', () {
      expect(ReceiverSsdp.matches(
        const SsdpSearchRequest('ssdp:all', 1),
        udn,
      ).length, 6);
      expect(ReceiverSsdp.matches(
        const SsdpSearchRequest('upnp:rootdevice', 1),
        udn,
      ).length, 1);
      expect(ReceiverSsdp.matches(
        const SsdpSearchRequest(
          'urn:schemas-upnp-org:service:AVTransport:1',
          1,
        ),
        udn,
      ).length, 1);
      expect(ReceiverSsdp.matches(
        const SsdpSearchRequest('uuid:$udn', 1),
        udn,
      ).length, 1);
      expect(ReceiverSsdp.matches(
        const SsdpSearchRequest('urn:schemas-upnp-org:device:InternetGatewayDevice:1', 1),
        udn,
      ), isEmpty);
    });
  });

  group('SsdpReplyGate', () {
    test('同源窗口限量、跨窗口重置、异源互不影响', () {
      var now = DateTime(2026, 11, 7);
      final gate = SsdpReplyGate(
        maxPerWindow: 3,
        window: const Duration(seconds: 1),
        now: () => now,
      );
      expect(gate.allow('10.0.0.1'), isTrue);
      expect(gate.allow('10.0.0.1'), isTrue);
      expect(gate.allow('10.0.0.1'), isTrue);
      expect(gate.allow('10.0.0.1'), isFalse);
      now = now.add(const Duration(milliseconds: 999));
      expect(gate.allow('10.0.0.1'), isFalse);
      now = now.add(const Duration(milliseconds: 1));
      expect(gate.allow('10.0.0.1'), isTrue);
      expect(gate.allow('10.0.0.2'), isTrue);
    });
  });

  group('searchReplyDelay', () {
    test('范围 [0, mx*1000]，mx 钳 0..5', () {
      final rng = Random(42);
      for (var i = 0; i < 50; i++) {
        expect(searchReplyDelay(2, rng).inMilliseconds, inInclusiveRange(0, 2000));
      }
      expect(searchReplyDelay(0, rng), Duration.zero);
      expect(searchReplyDelay(-1, rng), Duration.zero);
      expect(searchReplyDelay(99, rng).inMilliseconds, lessThanOrEqualTo(5000));
    });
  });

  group('ReceiverSsdpServer（真实 socket，组播 M-SEARCH）', () {
    test(
        'ssdp:all → 单播应答组，LOCATION 指向本机描述'
        '（组播回环环境相关，收不到则尽力而为跳过）', () async {
      final server = ReceiverSsdpServer(
        udn: 'test-udn-ssdp',
        httpPort: 18099,
        mxOverride: 0,
      );
      await server.start();
      addTearDown(server.stop);
      if (!server.answersSearches) {
        // 1900 被其它应用占用：降级为仅通告（蓝本同款），跳过收发断言。
        return;
      }
      // 组播发送（multicastLoopback 默认开）→ 本机组播成员（接收端监听
      // socket）收到；Windows 的 SSDPSRV 服务持有 1900 具体地址绑定，会
      // 抢走发往 127.0.0.1:1900 的单播，因此不能用单播自测。多网卡/TAP
      // 环境下组播回环是否送达本机监听取决于出接口与组成员关系——
      // 收不到时视为环境不支持，报文形状由纯函数用例覆盖。
      final client = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      addTearDown(client.close);
      final replies = <Map<String, String>>[];
      late final StreamSubscription<RawSocketEvent> sub;
      sub = client.listen((event) {
        if (event != RawSocketEvent.read) return;
        final d = client.receive();
        if (d == null) return;
        final headers = parseSsdpHeaders(utf8.decode(d.data));
        if (headers == null) return;
        replies.add(headers);
        if (replies.length >= 6) sub.cancel();
      });
      const searchPacket = 'M-SEARCH * HTTP/1.1\r\n'
          'HOST: 239.255.255.250:1900\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 0\r\n'
          'ST: ssdp:all\r\n'
          '\r\n';
      final group = InternetAddress(ReceiverSsdp.multicastAddress);
      // 三轮发送（间隔 300ms）：提高出接口与组成员关系对上的概率。
      for (var i = 0; i < 3 && replies.length < 6; i++) {
        client.send(utf8.encode(searchPacket), group, ReceiverSsdp.multicastPort);
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (replies.isEmpty) {
        return;
      }
      // LOCATION 指向本机某个网卡 IP + 设备描述路径。
      final location = Uri.parse(replies.first['LOCATION']!);
      expect(location.host, isNot('0.0.0.0'));
      expect(location.host, isNotEmpty);
      expect(location.path, '/description.xml');
      // USN 互不相同（每组一包；至少覆盖 rootdevice 与 uuid）。
      final usns = replies.map((h) => h['USN']).toSet();
      expect(usns.length, replies.length);
      expect(usns.first, startsWith('uuid:test-udn-ssdp'));
      // ST 回显与 M-SEARCH 匹配组的 NT 一致。
      expect(replies.every((h) => h['ST'] == h['NT']), isTrue);
    });
  });
}
