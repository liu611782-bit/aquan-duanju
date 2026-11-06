import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:aquan_duanju/core/sources/media_proxy.dart';

void main() {
  late HttpServer upstream;
  late http.Client client;
  final seenRanges = <String?>[];
  final seenReferers = <String?>[];

  setUp(() async {
    seenRanges.clear();
    seenReferers.clear();
    upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    upstream.listen((req) async {
      seenRanges.add(req.headers.value('Range'));
      seenReferers.add(req.headers.value('Referer'));
      req.response.headers.contentType = ContentType('video', 'mp2t');
      req.response.add(List<int>.generate(128 * 1024, (i) => i & 0xff));
      await req.response.close();
    });
    final io = HttpClient()..findProxy = (_) => 'DIRECT';
    client = IOClient(io);
    addTearDown(() async {
      client.close();
      await upstream.close(force: true);
      await MediaProxy.instance.shutdown();
    });
  });

  String proxyUrl({Map<String, String> headers = const {}}) =>
      MediaProxy.instance.wrap(
        'http://127.0.0.1:${upstream.port}/seg.ts',
        headers: headers,
      );

  test('不带 Range 时上游不再收到空 Range 头，且分片流式完整', () async {
    await MediaProxy.instance.acquire();
    final res = await client.get(Uri.parse(proxyUrl()));
    expect(res.statusCode, 200);
    expect(seenRanges, [null]);
    expect(res.bodyBytes.length, 128 * 1024);
  });

  test('Range / 源级 Referer 透传，DLNA 与 CORS 响应头齐全', () async {
    await MediaProxy.instance.acquire();
    final res = await client.get(
      Uri.parse(proxyUrl(headers: const {'Referer': 'https://r.example/'})),
      headers: const {'Range': 'bytes=0-15'},
    );
    expect(seenRanges.last, 'bytes=0-15');
    expect(seenReferers.last, 'https://r.example/');
    expect(
      res.headers.entries.any((e) =>
          e.key.toLowerCase() == 'transfermode.dlna.org' &&
          e.value == 'Streaming'),
      isTrue,
    );
    expect(
      res.headers.entries.any(
          (e) => e.key.toLowerCase() == 'access-control-allow-origin'),
      isTrue,
    );
  });

  test('同一上游 URL 复用稳定 wrapped 地址', () async {
    await MediaProxy.instance.acquire();
    expect(proxyUrl(), proxyUrl());
  });
}
