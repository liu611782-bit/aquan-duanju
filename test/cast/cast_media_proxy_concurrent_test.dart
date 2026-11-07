import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_proxy.dart';

/// 代理并发场景（R4，11-07-cast-reliability）：同一 token 并发两路 Range
/// 请求（0-99 / 100-199 各回正确字节段、互不串流）+ 并发父清单请求期间
/// 子清单改写正确（两路各自注册独立 token、二级穿透可用）。
/// 现有 cast_media_proxy_test 未覆盖并发面，这里锁死。
///
/// 夹具模式与 cast_media_proxy_test 相同：本地真实 HttpServer 作上游 +
/// hostOverride 假 IP 的代理实例；HTTP 客户端请求走回环地址。

void main() {
  late HttpServer upstream;
  late CastMediaProxy proxy;
  // path → 收到的 Range 头序列（断言透传）。
  final upstreamRanges = <String, List<String?>>{};
  // path → 请求计数（上游确实被取了两次）。
  final upstreamHits = <String, int>{};

  /// 400 字节测试体：字节 i = i % 256（0x00 与 0x64 可区分两段）。
  final body = List<int>.generate(400, (i) => i % 256);
  final segBody = List<int>.generate(64, (i) => i);

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      upstreamHits[req.uri.path] = (upstreamHits[req.uri.path] ?? 0) + 1;
      final range = req.headers.value('range');
      upstreamRanges.putIfAbsent(req.uri.path, () => []).add(range);
      req.response.headers.contentType =
          ContentType('application', 'octet-stream');
      if (req.uri.path == '/video.mp4') {
        if (range != null) {
          final m = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(range)!;
          final start = int.parse(m.group(1)!);
          final end =
              m.group(2) == null ? body.length - 1 : int.parse(m.group(2)!);
          req.response.statusCode = 206;
          req.response.headers.set(
              'Content-Range', 'bytes $start-$end/${body.length}');
          req.response.add(body.sublist(start, end + 1));
          await req.response.close();
          return;
        }
        req.response.add(body);
        await req.response.close();
        return;
      }
      if (req.uri.path == '/720p/seg-1.ts') {
        req.response.headers.contentType = ContentType('video', 'mp2t');
        req.response.add(segBody);
        await req.response.close();
        return;
      }
      if (req.uri.path == '/list.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            '/720p/list.m3u8\n');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/720p/list.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n#EXTINF:4.0,\n/720p/seg-1.ts\n');
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    });
    proxy = CastMediaProxy(
      hostOverride: '192.168.1.5',
      client: HttpClient()..connectionTimeout = const Duration(seconds: 2),
    );
    await proxy.start();
  });

  tearDown(() async {
    await proxy.stop();
    await upstream.close();
  });

  /// 代理登记返回的是 hostOverride 假 IP；本机客户端请求走回环地址。
  Uri localOf(String proxied) =>
      Uri.parse(proxied.replaceFirst('http://192.168.1.5:', 'http://127.0.0.1:'));

  Future<List<int>> readBytes(HttpClientResponse res) =>
      res.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));

  test('同一 token 并发两路 Range（0-99 / 100-199）：各回正确字节段，互不串流',
      () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/video.mp4',
    );
    expect(proxied, isNotNull);
    final token = Uri.parse(proxied!).pathSegments[1];

    Future<(int, String?, List<int>)> fetch(String range) async {
      final client = HttpClient();
      final req = await client.getUrl(localOf(proxied));
      req.headers.set('Range', range);
      final res = await req.close();
      final bytes = await readBytes(res);
      return (res.statusCode, res.headers.value('content-range'), bytes);
    }

    // 两路并发（各自独立连接；代理 Connection: close 不复用）。
    final results =
        await Future.wait([fetch('bytes=0-99'), fetch('bytes=100-199')]);

    final (statusA, rangeA, bytesA) = results[0];
    final (statusB, rangeB, bytesB) = results[1];
    expect(statusA, 206);
    expect(statusB, 206);
    expect(rangeA, 'bytes 0-99/400');
    expect(rangeB, 'bytes 100-199/400');
    // 字节内容精确匹配（两段内容可区分，互不串流、不错位）。
    expect(bytesA, body.sublist(0, 100));
    expect(bytesB, body.sublist(100, 200));

    // 上游两路 Range 原样透传（同一 token 两次独立取流）。
    final ranges = upstreamRanges['/video.mp4']!;
    expect(ranges, containsAll(<String?>['bytes=0-99', 'bytes=100-199']));
    expect(upstreamHits['/video.mp4'], 2);
    // token 未串改：两路请求的是同一登记条目。
    expect(token, Uri.parse(proxied).pathSegments[1]);
  });

  test('并发父清单请求期间子清单改写正确：两路各自独立 token，二级穿透可用',
      () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
    );
    expect(proxied, isNotNull);
    final client = HttpClient();

    Uri? variantOf(String playlist) {
      final m = RegExp(RegExp.escape('#EXT-X-STREAM-INF:BANDWIDTH=1000000\n') +
              r'(\S+)')
          .firstMatch(playlist);
      return m == null ? null : Uri.parse(m.group(1)!);
    }

    // 两路并发请求父清单（各自触发一次上游拉取 + 子 URL 注册）。
    Future<(int, String)> fetchParent() async {
      final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
      return (res.statusCode, await res.transform(utf8.decoder).join());
    }

    final parents = await Future.wait([fetchParent(), fetchParent()]);
    final childUrls = <Uri>[];
    for (final (status, playlist) in parents) {
      expect(status, 200);
      expect(playlist, contains('#EXTM3U'));
      // 变体行被改写为本代理地址（两段机制：优先本次请求 Host 头）。
      final variant = variantOf(playlist);
      expect(variant, isNotNull, reason: '父清单变体 URL 必须被改写出来');
      expect(variant!.host, '127.0.0.1');
      expect(variant.port, proxy.port);
      childUrls.add(variant);
    }
    expect(upstreamHits['/list.m3u8'], 2, reason: '两路父清单各自到上游拉取');
    expect(childUrls[0].pathSegments[1], isNot(childUrls[1].pathSegments[1]),
        reason: '两次父清单请求各自注册独立 token（同 URL 两次登记必不同）');

    // 各自的子清单 token 均有效（并发注册互不覆盖、互不丢失）。
    for (final childUrl in childUrls) {
      final res = await client.getUrl(localOf(childUrl.toString()))
          .then((r) => r.close());
      expect(res.statusCode, 200);
      final child = await res.transform(utf8.decoder).join();
      expect(child, contains('#EXTM3U'));
      // 二级清单同样被改写（分片行指向本代理）。
      final segLine = child
          .split('\n')
          .map((l) => l.trim())
          .firstWhere((l) => l.isNotEmpty && !l.startsWith('#'));
      final segUri = Uri.parse(segLine);
      expect(segUri.host, '127.0.0.1', reason: '子清单分片行必须代理化');
      expect(segUri.port, proxy.port);
      // 分片 token 可实际取流（200 且字节段完整）。
      final seg =
          await client.getUrl(localOf(segLine)).then((r) => r.close());
      expect(seg.statusCode, 200);
      expect(await readBytes(seg), segBody);
    }
    client.close();
  });
}
