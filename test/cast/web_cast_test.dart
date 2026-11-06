import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:aquan_duanju/core/cast/web_cast.dart';

http.Client directClient() {
  final io = HttpClient()..findProxy = (_) => 'DIRECT';
  return IOClient(io);
}

WebCastService service({required bool allowRemote}) => WebCastService(
      hostOverride: '127.0.0.1',
      defaultPort: 0,
      remoteChecker: (_) => allowRemote,
    );

void main() {
  test('页面可访问、含 video 与标题，token 32 字符且重新 start 会更换', () async {
    final cast = service(allowRemote: true);
    final a = await cast.start(
        url: 'https://cdn.example.com/a.mp4', title: '测试影片');
    expect(a, isNotNull);
    expect(a!.token.length, 32);

    final client = directClient();
    addTearDown(client.close);
    final res = await client.get(Uri.parse(a.url));
    expect(res.statusCode, 200);
    expect(res.body, contains('<video'));
    expect(res.body, contains('测试影片'));

    await cast.stop();
    final b = await cast.start(
        url: 'https://cdn.example.com/b.mp4', title: '测试影片2');
    expect(b!.token, isNot(a.token));
    await cast.stop();
  });

  test('非 site-local 来源一律 403', () async {
    final cast = service(allowRemote: false);
    final handle = await cast.start(
        url: 'https://cdn.example.com/a.mp4', title: 'x');
    expect(handle, isNotNull);
    final client = directClient();
    addTearDown(client.close);
    final res = await client.get(Uri.parse(handle!.url));
    expect(res.statusCode, 403);
    await cast.stop();
  });

  test('未知 token 404；stop 幂等且清空 current', () async {
    final cast = service(allowRemote: true);
    final handle = await cast.start(
        url: 'https://cdn.example.com/a.mp4', title: 'x');
    expect(cast.current, isNotNull);
    final client = directClient();
    addTearDown(client.close);
    final bad = Uri.parse(
        'http://127.0.0.1:${handle!.port}/w/not-the-token');
    expect((await client.get(bad)).statusCode, 404);

    await cast.stop();
    await cast.stop();
    expect(cast.current, isNull);
    expect(cast.running, isFalse);
  });
}
