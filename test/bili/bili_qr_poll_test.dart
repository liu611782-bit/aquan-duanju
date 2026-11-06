import 'dart:convert';

import 'package:aquan_duanju/core/bili/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用固定 JSON 响应构造会话：扫码轮询只关心响应体。
BiliSession _session(
  Object payload, {
  Map<String, String>? headers,
}) {
  final bytes = utf8.encode(jsonEncode(payload));
  return BiliSession(
    client: MockClient((_) async => http.Response.bytes(
          bytes,
          200,
          headers: headers ??
              const {'content-type': 'application/json; charset=utf-8'},
        )),
  );
}

void main() {
  group('BiliSession.pollQrLogin 读 data.code 而不是外层 code', () {
    test('86101 未扫码 → waiting（不能误判成登录成功）', () async {
      final session = _session({
        'code': 0,
        'message': 'OK',
        'ttl': 1,
        'data': {
          'url': '',
          'refresh_token': '',
          'timestamp': 0,
          'code': 86101,
          'message': '未扫码',
        },
      });
      final poll = await session.pollQrLogin('k');
      expect(poll.state, BiliQrState.waiting);
      expect(session.isLoggedIn, isFalse);
    });

    test('86090 已扫码待确认 → scanned', () async {
      final session = _session({
        'code': 0,
        'data': {'url': '', 'code': 86090, 'message': '已扫码未确认'},
      });
      expect((await session.pollQrLogin('k')).state, BiliQrState.scanned);
    });

    test('86038 已过期 → expired', () async {
      final session = _session({
        'code': 0,
        'data': {'url': '', 'code': 86038, 'message': '二维码已失效'},
      });
      expect((await session.pollQrLogin('k')).state, BiliQrState.expired);
    });

    test('data.code=0 登录成功 → confirmed，Cookie 从回调 url 提取', () async {
      final session = _session({
        'code': 0,
        'data': {
          'url': 'https://passport.biligame.com/crossDomain'
              '?DedeUserID=42&SESSDATA=s%2Bx&bili_jct=jct&gourl=x',
          'code': 0,
          'message': '',
        },
      });
      final poll = await session.pollQrLogin('k');
      expect(poll.state, BiliQrState.confirmed);
      expect(session.sessdata, 's+x');
      expect(session.userId, '42');
      expect(session.biliJct, 'jct');
      expect(session.isLoggedIn, isTrue);
    });

    test('外层 code != 0（风控/接口错误）→ failed，不当成扫码状态', () async {
      final session = _session({'code': -352, 'message': '风控校验失败'});
      expect((await session.pollQrLogin('k')).state, BiliQrState.failed);
    });

    test('data 缺失 → failed', () async {
      final session = _session({'code': 0, 'message': 'OK'});
      expect((await session.pollQrLogin('k')).state, BiliQrState.failed);
    });

    test('未知 data.code → waiting（保持二维码，不关闭弹窗）', () async {
      final session = _session({
        'code': 0,
        'data': {'url': '', 'code': 12345, 'message': '???'},
      });
      expect((await session.pollQrLogin('k')).state, BiliQrState.waiting);
    });
  });
}
