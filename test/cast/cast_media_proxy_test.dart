import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_proxy.dart';
import 'package:aquan_duanju/core/cast/cast_media_type.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';

void main() {
  late HttpServer upstream;
  late CastMediaProxy proxy;
  // path → {referer, range}（HttpHeaders 无 keys 迭代，按需捕获断言所需头）。
  final upstreamHeaders = <String, Map<String, String?>>{};

  setUp(() async {
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      upstreamHeaders[req.uri.path] = {
        'referer': req.headers.value('referer'),
        'range': req.headers.value('range'),
      };
      final range = req.headers.value('range');
      req.response.headers.contentType =
          ContentType('application', 'octet-stream');
      final body = utf8.encode('0123456789ABCDEF');
      if (req.uri.path == '/list.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        req.response.write('#EXTM3U\n'
            '#EXT-X-KEY:METHOD=AES-128,URI="/secret.key",IV=0x1\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=1000000\n'
            '/720p/list.m3u8\n'
            '#EXTINF:4.0,\n'
            '/seg1.ts\n');
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
      if (req.uri.path == '/sub.srt') {
        req.response.headers.contentType =
            ContentType('application', 'x-subrip', charset: 'utf-8');
        req.response.write('1\n00:00:01,000 --> 00:00:03,000\n你好世界\n');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/gone') {
        req.response.statusCode = 404;
        await req.response.close();
        return;
      }
      if (req.uri.path == '/error-page') {
        req.response.headers.contentType = ContentType.html;
        req.response.write('<!DOCTYPE html><html><body>403 blocked</body></html>');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/disguised.ts') {
        // 上游把 .ts 伪装成 image/png（dart_cast media_proxy 实证场景）。
        req.response.headers.contentType = ContentType('image', 'png');
        req.response.add(utf8.encode('0123456789ABCDEF'));
        await req.response.close();
        return;
      }
      if (req.uri.path == '/rawts') {
        // 无扩展名地址返回 TS 字节（嗅探判定用）。
        final bytes = List<int>.filled(256, 0)..[0] = 0x47..[188] = 0x47;
        req.response.headers.contentType =
            ContentType('application', 'octet-stream');
        req.response.add(bytes);
        await req.response.close();
        return;
      }
      if (req.uri.path == '/late-html') {
        if (req.headers.value('range') != null) {
          // 登记期嗅探（带 Range）→ 二进制 TS sync 特征，登记成功。
          final bytes = List<int>.filled(256, 0)..[0] = 0x47..[188] = 0x47;
          req.response.statusCode = 206;
          req.response.headers.set('Content-Range', 'bytes 0-255/256');
          req.response.add(bytes);
          await req.response.close();
          return;
        }
        // 正式取流（无 Range）→ 源站返回 HTML 错误页。
        req.response.headers.contentType = ContentType.html;
        req.response.write('<!DOCTYPE html><html><body>expired</body></html>');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/huge.m3u8') {
        req.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        // 超过 2MB 的异常清单。
        req.response.write('#EXTM3U\n${'x' * (3 * 1024 * 1024)}');
        await req.response.close();
        return;
      }
      if (req.uri.path == '/forbidden-without-header') {
        if (upstreamHeaders[req.uri.path]?['referer'] == null) {
          req.response.statusCode = 403;
          await req.response.close();
          return;
        }
      }
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d+)?').firstMatch(range)!;
        final start = int.parse(m.group(1)!);
        var end = m.group(2) == null ? body.length - 1 : int.parse(m.group(2)!);
        // 嗅探请求带 bytes=0-8191：真实服务器会把终点钳到文件末尾。
        if (end >= body.length) end = body.length - 1;
        req.response.statusCode = 206;
        req.response.headers.set('Content-Range',
            'bytes $start-$end/${body.length}');
        req.response.add(body.sublist(start, end + 1));
        await req.response.close();
        return;
      }
      req.response.add(body);
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

  test('直链代理：注入头、透传字节、Range 206', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/forbidden-without-header',
      headers: {'Referer': 'http://origin/'},
    );
    expect(proxied, isNotNull);

    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.statusCode, 200,
        reason: '上游没收到 Referer 会回 403；200 说明头已注入');
    final text = await res.transform(utf8.decoder).join();
    expect(text, '0123456789ABCDEF');
    upstreamHeaders.clear();

    // Range 透传：206 + Content-Range + 区间字节。
    final req = await client.getUrl(localOf(proxied));
    req.headers.set('Range', 'bytes=2-5');
    final ranged = await req.close();
    expect(ranged.statusCode, 206);
    expect(ranged.headers.value('content-range'), 'bytes 2-5/16');
    final chunk = await ranged.transform(utf8.decoder).join();
    expect(chunk, '2345');
    expect(upstreamHeaders['/forbidden-without-header']?['range'], 'bytes=2-5');
    client.close();
  });

  test('HLS 清单改写：变体/分片/KEY 全部代理化，且可二次穿透', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
      headers: {'Referer': 'http://origin/'},
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    final playlist = await res.transform(utf8.decoder).join();
    expect(playlist, isNot(contains('/secret.key')),
        reason: 'KEY URI 必须被改写');
    // 两段机制（review §8.3）：子 URL 优先用本次请求的 Host 头——本测试
    // 用 127.0.0.1 取父清单，子 URL 也必须广播 127.0.0.1:port。
    final authority = 'http://127.0.0.1:${proxy.port}';
    expect(
        playlist, contains('#EXT-X-KEY:METHOD=AES-128,URI="$authority'));
    expect(playlist, contains('URI="$authority'), reason: '属性 URI 代理化');
    expect(playlist.contains('#EXTINF:4.0,\n$authority'), isTrue,
        reason: '裸分片行代理化');

    // 从改写后的清单里取一个代理 URL 再请求 → 二级清单再改写。
    final childMatch =
        RegExp(r'#EXT-X-STREAM-INF:BANDWIDTH=1000000\n(\S+)').firstMatch(playlist);
    final variant = await client
        .getUrl(localOf(childMatch!.group(1)!))
        .then((r) => r.close());
    final variantText = await variant.transform(utf8.decoder).join();
    expect(variantText.contains(authority), isTrue,
        reason: '嵌套清单同样被改写');
    client.close();
  });

  test('无 Host 头的请求：子 URL 退回登记时的设备 IP（两段机制第二段）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
    );
    final token = Uri.parse(proxied!).pathSegments[1];
    // 原始 socket 发不带 Host 头的请求（HttpClient 恒带 Host，只能手写）。
    final socket =
        await Socket.connect(InternetAddress.loopbackIPv4, proxy.port!);
    socket.add(utf8.encode('GET /p/$token HTTP/1.1\r\nConnection: close\r\n\r\n'));
    final text = await utf8.decoder.bind(socket).join();
    await socket.close();
    expect(text.contains('http://192.168.1.5:'), isTrue,
        reason: '无 Host 头时退回登记时的设备 IP（hostOverride）');
    expect(text, contains('#EXTM3U'));
  });

  test('register 带 targetHost：对外 URL host = 路由源 IP（AC-19）', () async {
    // 到 127.0.0.1 的路由源就是 127.0.0.1（回环探测在全平台确定）。
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
      targetHost: '127.0.0.1',
    );
    expect(Uri.parse(proxied!).host, '127.0.0.1',
        reason: '对外 URL 的 host 必须是到目标设备的路由源 IP');
    // host 只是广播形态：伺服 bind anyIPv4，走 127.0.0.1 照常拉到。
    final client = HttpClient();
    final res = await client.getUrl(Uri.parse(proxied)).then((r) => r.close());
    expect(res.statusCode, 200);
    client.close();
  });

  test('register 不带 targetHost：保持全局 hostOverride 形态（回归）', () async {
    final proxied =
        await proxy.register('http://127.0.0.1:${upstream.port}/seg1.ts');
    expect(Uri.parse(proxied!).host, '192.168.1.5');
  });

  test('SRT 字幕：拉取转 VTT 伺服（text/vtt + WEBVTT 头 + 毫秒点号）', () async {
    final proxied = await proxy.registerSubtitle(
      'http://127.0.0.1:${upstream.port}/sub.srt',
      headers: {'Referer': 'http://origin/'},
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.contentType?.mimeType, 'text/vtt');
    final text = await res.transform(utf8.decoder).join();
    expect(text.startsWith('WEBVTT'), isTrue);
    expect(text.contains('00:00:01.000 --> 00:00:03.000'), isTrue);
    expect(text.contains('你好世界'), isTrue);
    client.close();
  });

  test('响应不含安全头（x-frame-options 等会让部分渲染器拒播）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.value('x-frame-options'), isNull);
    expect(res.headers.value('x-content-type-options'), isNull);
    expect(res.headers.value('x-xss-protection'), isNull);
    client.close();
  });

  test('未登记 token → 404', () async {
    final client = HttpClient();
    final res = await client
        .getUrl(Uri.parse('http://127.0.0.1:${proxy.port}/p/unknown'))
        .then((r) => r.close());
    expect(res.statusCode, 404);
    client.close();
  });

  test('token 随机：连续登记不重复、不可由时间推导', () async {
    final a = await proxy.register('http://127.0.0.1:${upstream.port}/seg1.ts');
    final b = await proxy.register('http://127.0.0.1:${upstream.port}/seg1.ts');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b), reason: '同 URL 两次登记 token 必须不同（防猜）');
    // 旧 token 是时间戳 base36 + 序号；新 token 是 24B base64Url（含 -/_ 可能）。
    // URL 形态 /p/<token>/<fileName>（M1-3）：token 恒取 segments[1]。
    final tokenA = Uri.parse(a!).pathSegments[1];
    expect(tokenA.length, 32, reason: '24B base64Url 去掉 padding = 32 字符');
    expect(Uri.parse(a).pathSegments.last, 'stream.ts');
  });

  test('方法白名单：POST → 405', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    final client = HttpClient();
    final req = await client.openUrl('POST', localOf(proxied!));
    final res = await req.close();
    expect(res.statusCode, 405);
    client.close();
  });

  test('非法 Range → 416（不透传给上游）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    final client = HttpClient();
    for (final bad in ['bytes=abc', 'bytes=5-2', 'bytes=0-1,3-4']) {
      final req = await client.getUrl(localOf(proxied!));
      req.headers.set('Range', bad);
      final res = await req.close();
      expect(res.statusCode, 416, reason: '$bad 应被判非法');
      expect(upstreamHeaders['/seg1.ts']?['range'], isNot(bad),
          reason: '$bad 不应透传');
    }
    client.close();
  });

  test('登记期嗅探到 HTML → CastException（错误页在投屏前就拦截，M1-1）', () async {
    await expectLater(
      proxy.register('http://127.0.0.1:${upstream.port}/error-page'),
      throwsA(isA<Exception>()),
    );
  });

  test('取流期上游变 HTML → 502（不喂给电视防黑屏）', () async {
    // 登记期嗅探（带 Range）拿到 TS 字节 → 登记成功；正式取流才是 HTML。
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/late-html',
    );
    expect(proxied, isNotNull);
    expect(Uri.parse(proxied!).pathSegments.last, 'stream.ts');
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied)).then((r) => r.close());
    expect(res.statusCode, 502);
    client.close();
  });

  test('AC-10：HLS 投屏 URL 以 /index.m3u8 结尾（3 段路由 + 兼容旧裸 URL）',
      () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
      headers: {'Referer': 'http://origin/'},
    );
    expect(proxied, isNotNull);
    final uri = Uri.parse(proxied!);
    expect(uri.pathSegments, hasLength(3), reason: '/p/<token>/<fileName>');
    expect(uri.pathSegments.last, 'index.m3u8');
    expect(uri.path.endsWith('/index.m3u8'), isTrue, reason: 'AC-10');

    final client = HttpClient();
    // 新形态路由：3 段路径正常伺服。
    final res = await client.getUrl(localOf(proxied)).then((r) => r.close());
    expect(res.statusCode, 200);
    expect(res.headers.contentType?.mimeType, 'application/vnd.apple.mpegurl',
        reason: 'Content-Type 与 CastMediaType.mime 一致');
    final body = await res.transform(utf8.decoder).join();
    expect(body, contains('#EXTM3U'));
    // 一致性不变式：DIDL mime 段（resolver 对投屏 URL 的判定）
    // == 代理响应 Content-Type == 扩展名对应 mime。
    final didlMime = (await resolveCastMediaType(url: Uri.parse(proxied))).mime;
    expect(didlMime, 'application/vnd.apple.mpegurl');
    expect(didlMime, res.headers.contentType?.mimeType);
    // 旧形态路由（裸 /p/<token>）继续兼容。
    final bare =
        proxied.substring(0, proxied.lastIndexOf('/'));
    final legacy = await client.getUrl(localOf(bare)).then((r) => r.close());
    expect(legacy.statusCode, 200);
    expect((await legacy.transform(utf8.decoder).join()), contains('#EXTM3U'));
    client.close();
  });

  test('无扩展名 + hint：HLS hint → index.m3u8；无 hint → 嗅探 TS → stream.ts',
      () async {
    final hls = await proxy.register(
      'http://127.0.0.1:${upstream.port}/api/play?type=2',
      hintMime: 'application/vnd.apple.mpegurl',
    );
    expect(Uri.parse(hls!).pathSegments.last, 'index.m3u8', reason: 'hint 判 HLS');

    final ts = await proxy.register(
      'http://127.0.0.1:${upstream.port}/rawts',
    );
    expect(Uri.parse(ts!).pathSegments.last, 'stream.ts',
        reason: '无证据时嗅探上游前 8KB');
    // 嗅探判定的类型同时决定 Content-Type（与 DIDL 同源）。
    final client = HttpClient();
    final res = await client.getUrl(localOf(ts)).then((r) => r.close());
    expect(res.headers.contentType?.mimeType, 'video/mp2t');
    client.close();
  });

  test('伪装改写：上游 image/png + URL .ts → Content-Type video/mp2t', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/disguised.ts',
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.contentType?.mimeType, 'video/mp2t',
        reason: 'kind 已知时不信上游伪装的 image/*');
    client.close();
  });

  test('DLNA 响应头：transferMode 恒带、contentFeatures 条件化、清单不声明 Accept-Ranges',
      () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
    );
    final client = HttpClient();

    // 不索要 contentFeatures → 不回。
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.headers.value('transferMode.dlna.org'), 'Streaming');
    expect(res.headers.value('realTimeInfo.dlna.org'), 'DLNA.ORG_TLAG=*');
    expect(res.headers.value('contentFeatures.dlna.org'), isNull);
    expect(res.headers.value('accept-ranges'), isNull,
        reason: '清单路由不答 206 → 不声明 Accept-Ranges（诚实化）');

    // 索要 contentFeatures（getcontentFeatures.dlna.org: 1）→ 才回。
    final req = await client.getUrl(localOf(proxied));
    req.headers.set('getcontentFeatures.dlna.org', '1');
    final res2 = await req.close();
    expect(res2.headers.value('contentFeatures.dlna.org'),
        'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000');
    client.close();
  });

  test('直链响应头：Accept-Ranges 只在上游真答 206 时声明', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    final client = HttpClient();

    // 无 Range：上游 200 整流 → 不声明。
    final plain = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(plain.statusCode, 200);
    expect(plain.headers.value('accept-ranges'), isNull);
    expect(plain.headers.value('transferMode.dlna.org'), 'Streaming');
    expect(plain.headers.value('contentFeatures.dlna.org'), isNull);

    // 带 Range：上游 206 → 声明。
    final req = await client.getUrl(localOf(proxied));
    req.headers.set('Range', 'bytes=2-5');
    req.headers.set('getcontentFeatures.dlna.org', '1');
    final ranged = await req.close();
    expect(ranged.statusCode, 206);
    expect(ranged.headers.value('accept-ranges'), 'bytes');
    expect(ranged.headers.value('contentFeatures.dlna.org'), isNotNull);
    client.close();
  });

  test('字幕响应头：text/* 走 Interactive，不给 contentFeatures/realTimeInfo',
      () async {
    final proxied = await proxy.registerSubtitle(
      'http://127.0.0.1:${upstream.port}/sub.srt',
    );
    expect(Uri.parse(proxied!).pathSegments.last, 'subtitle.vtt');
    final client = HttpClient();
    final req = await client.getUrl(localOf(proxied));
    req.headers.set('getcontentFeatures.dlna.org', '1');
    final res = await req.close();
    expect(res.headers.contentType?.mimeType, 'text/vtt');
    expect(res.headers.value('transferMode.dlna.org'), 'Interactive');
    expect(res.headers.value('contentFeatures.dlna.org'), isNull);
    expect(res.headers.value('realTimeInfo.dlna.org'), isNull);
    expect(res.headers.value('accept-ranges'), isNull);
    client.close();
  });

  test('bare 配方：登记与清单子 URL 都退回旧裸 URL 形态', () async {
    final bare = await proxy.register(
      'http://127.0.0.1:${upstream.port}/list.m3u8',
      urlSuffixMode: CastUrlSuffixMode.bare,
    );
    expect(Uri.parse(bare!).pathSegments, hasLength(2), reason: 'bare = /p/<token>');

    final client = HttpClient();
    final res = await client.getUrl(localOf(bare)).then((r) => r.close());
    final playlist = await res.transform(utf8.decoder).join();
    expect(playlist.contains('.m3u8'), isFalse,
        reason: '子 URL 继承 bare 形态，不带扩展名段');
    client.close();
  });

  test('会话结束重登记：token 必须重新生成（stop 后旧 token 失效）', () async {
    final first = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    await proxy.stop(); // 模拟 _finishSession 清空代理条目
    final second = await proxy.register(
      'http://127.0.0.1:${upstream.port}/seg1.ts',
    );
    expect(Uri.parse(first!).pathSegments[1],
        isNot(Uri.parse(second!).pathSegments[1]),
        reason: '每次投屏重新生成 token（防电视端缓存旧片）');
    final client = HttpClient();
    final res = await client
        .getUrl(Uri.parse(
            'http://127.0.0.1:${proxy.port}/p/${Uri.parse(first).pathSegments[1]}/stream.ts'))
        .then((r) => r.close());
    expect(res.statusCode, 404, reason: '旧 token 已被 stop 清空');
    client.close();
  });

  test('上游 4xx → 502（错误归一）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/gone',
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.statusCode, 502);
    client.close();
  });

  test('超大清单 → 502（2MB 上限）', () async {
    final proxied = await proxy.register(
      'http://127.0.0.1:${upstream.port}/huge.m3u8',
    );
    final client = HttpClient();
    final res = await client.getUrl(localOf(proxied!)).then((r) => r.close());
    expect(res.statusCode, 502);
    client.close();
  });

  test('条目 LRU 上限：最旧 token 被淘汰 → 404', () async {
    final first = await proxy.register('http://127.0.0.1:${upstream.port}/a');
    for (var i = 0; i < CastMediaProxy.maxEntries; i++) {
      await proxy.register('http://127.0.0.1:${upstream.port}/fill/$i');
    }
    final client = HttpClient();
    final res = await client
        .getUrl(localOf(first!))
        .then((r) => r.close());
    expect(res.statusCode, 404, reason: '最旧条目应被 LRU 淘汰');
    client.close();
  });
}
