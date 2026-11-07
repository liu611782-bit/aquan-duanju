import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/local_media_server.dart';

void main() {
  group('isVirtualAdapterName（M0.5 纯函数，表驱动）', () {
    test('虚拟网卡名全部命中', () {
      for (final name in [
        'vEthernet (Default Switch)',
        'vEthernet (WSL)',
        'WSL',
        'Hyper-V Virtual Ethernet Adapter',
        'VMware Network Adapter VMnet1',
        'VirtualBox Host-Only Network',
        'TAP-Windows Adapter V9',
        'Tailscale',
        'ZeroTier One [network-id]',
      ]) {
        expect(LocalMediaServer.isVirtualAdapterName(name), isTrue,
            reason: name);
      }
    });

    test('物理网卡名不误伤', () {
      for (final name in [
        '以太网',
        'Ethernet',
        'WLAN',
        'Wi-Fi',
        '本地连接',
        'Realtek PCIe GbE Family Controller',
        'Intel(R) Wi-Fi 6 AX201 160MHz',
      ]) {
        expect(LocalMediaServer.isVirtualAdapterName(name), isFalse,
            reason: name);
      }
    });
  });

  group('rankInterfaceAddresses（M0.5 纯函数，表驱动）', () {
    test('192.168 > 10 > 172.16-31，虚拟网卡与非私网跳过', () {
      final ranked = LocalMediaServer.rankInterfaceAddresses(const [
        ('vEthernet (WSL)', '172.29.80.1'),
        ('Tailscale', '100.64.0.1'),
        ('VirtualBox Host-Only', '192.168.56.1'),
        ('以太网 2', '10.0.0.5'),
        ('WLAN', '192.168.1.7'),
        ('以太网 3', '172.20.10.2'),
        ('回环', '127.0.0.1'),
      ]);
      expect(ranked, ['192.168.1.7', '10.0.0.5', '172.20.10.2']);
    });

    test('与目标同 /24 的地址优先（dart_cast network_utils 思路）', () {
      final ranked = LocalMediaServer.rankInterfaceAddresses(const [
        ('以太网', '192.168.2.5'),
        ('WLAN', '10.0.0.5'),
      ], target: '10.0.0.8');
      expect(ranked.first, '10.0.0.5',
          reason: '电视在 10.0.0.x 网段，10.0.0.5 才是它可达的源地址');
    });

    test('同 /24 优先不越过优先级分组语义（目标 192.168 网段）', () {
      final ranked = LocalMediaServer.rankInterfaceAddresses(const [
        ('以太网', '192.168.2.5'),
        ('WLAN', '192.168.1.7'),
      ], target: '192.168.1.8');
      expect(ranked, ['192.168.1.7', '192.168.2.5']);
    });

    test('全部是虚拟网卡 → 返回空（调用方走最后兜底）', () {
      expect(
        LocalMediaServer.rankInterfaceAddresses(const [
          ('vEthernet (WSL)', '172.29.80.1'),
          ('TAP-Windows Adapter V9', '10.6.0.1'),
        ]),
        isEmpty,
      );
    });
  });

  group('resolveRouteSourceIp（M0.5 路由源 IP）', () {
    test('回环目标：路由源就是回环（全平台确定，不依赖具体路由实现）', () async {
      final ip = await LocalMediaServer.resolveRouteSourceIp('127.0.0.1');
      expect(ip, '127.0.0.1');
    });

    test('Windows FFI：到本机自身地址的路由源就是该地址（实测行布局）', () async {
      if (!Platform.isWindows) return;
      final lan = await LocalMediaServer.resolveLanIPv4();
      if (lan == null) return; // 无私网地址的机器（最小环境）跳过
      final routed = LocalMediaServer.windowsRouteSourceIp(
        InternetAddress(lan),
      );
      expect(routed, lan,
          reason: 'GetBestInterface(自身地址) → 该接口行 → 该行地址；'
              'null 说明行布局匹配失败');
    });

    test('空目标：回退全局枚举（结果随机器而定，只断言不抛出）', () async {
      final ip = await LocalMediaServer.resolveRouteSourceIp('');
      // 任何结果都合法（有私网 = 私网；无 = null）；关键是超时/异常路径不抛。
      expect(ip, anyOf(isNull, isA<String>()));
    });
  });

  group('urlFor 的 per-device IP（M0.5-1）', () {
    late LocalMediaServer server;
    late File media;

    setUp(() async {
      media = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}lms_test_${DateTime.now().microsecondsSinceEpoch}.mp4');
      await media.writeAsString('0123456789ABCDEF');
      server = LocalMediaServer(hostOverride: '192.168.1.5');
    });

    tearDown(() async {
      await server.stop();
      try {
        await media.delete();
      } catch (_) {}
    });

    test('带 targetHost：URL host = 路由源 IP（127.0.0.1）', () async {
      final url = await server.urlFor(media.path, targetHost: '127.0.0.1');
      expect(url, isNotNull);
      final uri = Uri.parse(url!);
      expect(uri.host, '127.0.0.1', reason: '到目标设备的路由源 IP');
      expect(uri.port, server.port);
      expect(uri.path, startsWith('/m/'));
      // 广播形态变了，伺服不受影响（bind anyIPv4）。
      final res = await HttpClient()
          .getUrl(Uri.parse(url))
          .then((r) => r.close());
      expect(res.statusCode, 200);
      final body = await res.transform(utf8.decoder).join();
      expect(body, '0123456789ABCDEF');
    });

    test('不带 targetHost：保持全局 hostOverride 形态（回归）', () async {
      final url = await server.urlFor(media.path);
      expect(Uri.parse(url!).host, '192.168.1.5');
    });
  });

  group('URL 形态与 DLNA 响应头（M1-4 / M1-9）', () {
    late Directory dir;
    late File mp4;
    late File m3u8;
    late LocalMediaServer server;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('lms_m1');
      mp4 = File('${dir.path}${Platform.pathSeparator}ep1.mp4');
      await mp4.writeAsString('0123456789ABCDEF');
      m3u8 = File('${dir.path}${Platform.pathSeparator}local.m3u8');
      await m3u8.writeAsString('#EXTM3U\n#EXTINF:4.0,\nseg0.ts\n');
      // 127.0.0.1：本机回环即可请求（192.168.x 假地址在本机不可达）。
      server = LocalMediaServer(hostOverride: '127.0.0.1');
    });

    tearDown(() async {
      await server.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('AC-10/URL 形态：/m/<token>/video.mp4（不暴露真实文件名）', () async {
      final url = await server.urlFor(mp4.path);
      final uri = Uri.parse(url!);
      expect(uri.pathSegments, hasLength(3), reason: '/m/<token>/<fileName>');
      expect(uri.pathSegments.last, 'video.mp4');
      expect(uri.path.contains('ep1'), isFalse, reason: '不暴露真实文件名');
      // 3 段路由正常伺服。
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      expect(res.statusCode, 200);
      expect(res.headers.contentType?.mimeType, 'video/mp4');
      expect(await res.transform(utf8.decoder).join(), '0123456789ABCDEF');
    });

    test('HLS 本地文件 → /m/<token>/index.m3u8 + 清单 Content-Type', () async {
      final url = await server.urlFor(m3u8.path);
      expect(Uri.parse(url!).pathSegments.last, 'index.m3u8');
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      expect(res.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl');
    });

    test('路由兼容：旧裸 /m/<token> 继续伺服', () async {
      final url = await server.urlFor(mp4.path);
      final bare = url!.substring(0, url.lastIndexOf('/'));
      final res =
          await HttpClient().getUrl(Uri.parse(bare)).then((r) => r.close());
      expect(res.statusCode, 200);
      expect(await res.transform(utf8.decoder).join(), '0123456789ABCDEF');
    });

    test('bare 配方：URL 退回旧形态 /m/<token>', () async {
      final url = await server.urlFor(mp4.path,
          urlSuffixMode: CastUrlSuffixMode.bare);
      expect(Uri.parse(url!).pathSegments, hasLength(2));
      final res = await HttpClient().getUrl(Uri.parse(url)).then((r) => r.close());
      expect(res.statusCode, 200);
    });

    test('DLNA 响应头：媒体路由 Streaming 恒带、contentFeatures 条件化、'
        '本地文件恒声明 Accept-Ranges', () async {
      final url = await server.urlFor(mp4.path);
      final client = HttpClient();

      final res = await client.getUrl(Uri.parse(url!)).then((r) => r.close());
      expect(res.headers.value('transferMode.dlna.org'), 'Streaming');
      expect(res.headers.value('realTimeInfo.dlna.org'), 'DLNA.ORG_TLAG=*');
      expect(res.headers.value('contentFeatures.dlna.org'), isNull,
          reason: '设备未索要不回');
      expect(res.headers.value('accept-ranges'), 'bytes',
          reason: '本地文件路由恒真支持 206');

      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('getcontentFeatures.dlna.org', '1');
      final withFeatures = await req.close();
      expect(withFeatures.headers.value('contentFeatures.dlna.org'),
          'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000');
      client.close();
    });

    test('Range 206 + DLNA 响应头并存', () async {
      final url = await server.urlFor(mp4.path);
      final req = await HttpClient().getUrl(Uri.parse(url!));
      req.headers.set('Range', 'bytes=2-5');
      final res = await req.close();
      expect(res.statusCode, 206);
      expect(res.headers.value('content-range'), 'bytes 2-5/16');
      expect(res.headers.value('transferMode.dlna.org'), 'Streaming');
      expect(res.headers.value('accept-ranges'), 'bytes');
    });

    test('M5-1 字幕第三通道：登记字幕的本地文件响应带 CaptionInfo.sec', () async {
      const caption = 'http://192.168.1.5:18280/p/subtoken/subtitle.srt';
      final url = await server.urlFor(mp4.path, subtitleUrl: caption);
      final res =
          await HttpClient().getUrl(Uri.parse(url!)).then((r) => r.close());
      expect(res.headers.value('captioninfo.sec'), caption);

      // 未登记字幕不产生噪声。
      final plain = await server.urlFor(m3u8.path);
      final res2 =
          await HttpClient().getUrl(Uri.parse(plain!)).then((r) => r.close());
      expect(res2.headers.value('captioninfo.sec'), isNull);
    });
  });
}
