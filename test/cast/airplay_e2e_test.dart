import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/airplay/airplay_transport.dart';
import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';

/// 一条被假接收端收到的请求（脱敏记录：方法/路径/query/头/body）。
class _Req {
  const _Req({
    required this.method,
    required this.path,
    required this.query,
    required this.contentType,
    required this.body,
    required this.sessionId,
  });

  final String method;
  final String path;
  final Map<String, String> query;
  final String contentType;
  final String body;
  final String sessionId;

  bool get hasSessionId => sessionId.isNotEmpty;
}

/// 本地假 AirPlay 1 接收端：UxPlay / shairport-sync-video 形态的经典
/// `/play` 路径——`/play` 收 text/parameters、`/rate` `/scrub` `/stop`
/// 命中即 200、`/playback-info` 按 [state] 回 XML 或二进制 plist。
class _FakeAirPlayReceiver {
  HttpServer? _server;
  final requests = <_Req>[];

  /// 'empty'（未起播/加载中）| 'playing' | 'paused'
  String state = 'empty';

  /// true 时 /playback-info 回二进制 plist（AirPlay 2 接收端口径）。
  bool binaryInfo = false;

  double position = 0;

  Future<int> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      requests.add(_Req(
        method: req.method,
        path: req.uri.path,
        query: req.uri.queryParameters,
        contentType: req.headers.value('content-type') ?? '',
        body: body,
        sessionId: req.headers.value('x-apple-session-id') ?? '',
      ));
      switch (req.uri.path) {
        case '/play':
          state = 'playing';
          position = 0;
          await _reply(req);
        case '/rate':
          state = (double.tryParse(req.uri.queryParameters['value'] ?? '') ??
                      0) >
                  0
              ? 'playing'
              : 'paused';
          await _reply(req);
        case '/scrub':
          position =
              double.tryParse(req.uri.queryParameters['position'] ?? '') ?? 0;
          await _reply(req);
        case '/stop':
          state = 'empty';
          position = 0;
          await _reply(req);
        case '/playback-info':
          if (state == 'playing' && binaryInfo) {
            req.response.headers.contentType =
                ContentType('application', 'x-apple-binary-plist');
            req.response.add(_binaryPlayingInfo());
          } else {
            req.response.headers.contentType =
                ContentType('text', 'xml', charset: 'utf-8');
            req.response.write(_xmlPlaybackInfo());
          }
          await req.response.close();
        default:
          req.response.statusCode = 404;
          await req.response.close();
      }
    });
    return server.port;
  }

  Future<void> _reply(HttpRequest req) async {
    req.response.statusCode = 200;
    await req.response.close();
  }

  String _xmlPlaybackInfo() {
    switch (state) {
      case 'playing':
        return '<plist version="1.0"><dict>'
            '<key>duration</key><real>600.0</real>'
            '<key>position</key><real>$position</real>'
            '<key>rate</key><real>1.0</real>'
            '<key>readyToPlay</key><true/>'
            '</dict></plist>';
      case 'paused':
        return '<plist version="1.0"><dict>'
            '<key>duration</key><real>600.0</real>'
            '<key>position</key><real>$position</real>'
            '<key>rate</key><real>0.0</real>'
            '<key>readyToPlay</key><true/>'
            '</dict></plist>';
      default:
        // 未在播：接收端省略 duration 键（pyatv 以此判「没播起来」）。
        return '<plist version="1.0"><dict>'
            '<key>readyToPlay</key><false/>'
            '</dict></plist>';
    }
  }

  /// python3 plistlib.dumps({'duration': 180.0, 'position': 12.5,
  ///   'rate': 1.0, 'readyToPlay': True}) 的固定字节（bplist00）。
  static const _binaryPlayingHex =
      '62706c6973743030d40102030405060708586475726174696f6e'
      '58706f736974696f6e54726174655b7265616479546f506c6179234066800000000000'
      '234029000000000000233ff00000000000000908111a2328343d464f00000000000001'
      '01000000000000000900000000000000000000000000000050';

  List<int> _binaryPlayingInfo() => [
        for (var i = 0; i < _binaryPlayingHex.length; i += 2)
          int.parse(_binaryPlayingHex.substring(i, i + 2), radix: 16),
      ];

  Future<void> stop() async {
    await _server?.close();
    _server = null;
  }
}

void main() {
  test('/play 报文实锤：text/parameters + Content-Location/Start-Position', () async {
    final receiver = _FakeAirPlayReceiver();
    final port = await receiver.start();
    addTearDown(receiver.stop);

    final transport = AirPlayTransport(
      AirPlayDeviceInfo(host: '127.0.0.1', port: port, name: 'UxPlay'),
    );
    addTearDown(transport.close);

    await transport.setUri(
      Uri.parse('http://192.168.1.5:18280/v/1.m3u8'),
      title: '第1集',
      duration: '0:10:00.000',
    );

    final play = receiver.requests.last;
    expect(play.method, 'POST');
    expect(play.path, '/play');
    // package:http 对字符串 body 自动补 charset（蓝本 dart_cast 同款出线形态；
    // UxPlay/shairport-sync 按前缀匹配 text/parameters，后缀无害）。
    expect(play.contentType, startsWith('text/parameters'));
    expect(play.body,
        'Content-Location: http://192.168.1.5:18280/v/1.m3u8\nStart-Position: 0.0\n');
    expect(play.hasSessionId, isTrue, reason: '恒带 X-Apple-Session-ID');
  });

  test('全链：load → poll(PLAYING) → pause → seek → poll(PAUSED) → stop', () async {
    final receiver = _FakeAirPlayReceiver();
    final port = await receiver.start();
    addTearDown(receiver.stop);

    final transport = AirPlayTransport(
      AirPlayDeviceInfo(host: '127.0.0.1', port: port, name: '客厅 Apple TV'),
    );
    addTearDown(transport.close);

    // 加载中（/play 前的空态）：不报 STOPPED（不能误杀新会话）。
    var poll = await transport.poll();
    expect(poll.transportState, 'BUFFERING');

    await transport.setUri(Uri.parse('http://x/1.mp4'), title: '第1集');
    await transport.play();
    expect(receiver.requests.last.path, '/rate');
    expect(receiver.requests.last.query['value'], '1.0');

    poll = await transport.poll();
    expect(poll.transportState, 'PLAYING');
    expect(poll.duration, const Duration(seconds: 600));
    expect(poll.position, Duration.zero);

    await transport.pause();
    expect(receiver.requests.last.query['value'], '0.0');
    poll = await transport.poll();
    expect(poll.transportState, 'PAUSED_PLAYBACK');
    expect(poll.position, Duration.zero);

    await transport.seekTo(const Duration(seconds: 120));
    expect(receiver.requests.last.path, '/scrub');
    expect(receiver.requests.last.query['position'], '120.0');
    poll = await transport.poll();
    expect(poll.transportState, 'PAUSED_PLAYBACK');
    expect(poll.position, const Duration(seconds: 120));

    // 接收端把进度拉回 0（清空状态）：已见过 loaded → STOPPED（远端停止感知）。
    receiver.state = 'empty';
    receiver.position = 0;
    poll = await transport.poll();
    expect(poll.transportState, 'STOPPED');

    final sessionIdBefore = receiver.requests.last.sessionId;
    await transport.stop();
    expect(receiver.requests.last.path, '/stop');
    // stop 后新会话 ID（蓝本 AirPlayClient.stop 口径）。
    final stopReq = receiver.requests.last;
    final nextPoll = await transport.poll();
    expect(receiver.requests.last.sessionId,
        isNot(equals(sessionIdBefore)),
        reason: 'stop 换新会话 ID');
    expect(nextPoll.transportState, 'BUFFERING',
        reason: 'stop 后重置加载记忆：空态回到加载中而不是 STOPPED');
    expect(stopReq.hasSessionId, isTrue);
  });

  test('二进制 plist /playback-info（AirPlay 2 接收端）→ poll 正常解析', () async {
    final receiver = _FakeAirPlayReceiver();
    final port = await receiver.start();
    addTearDown(receiver.stop);
    receiver.binaryInfo = true;
    receiver.state = 'playing';

    final transport = AirPlayTransport(
      AirPlayDeviceInfo(host: '127.0.0.1', port: port),
    );
    addTearDown(transport.close);

    final poll = await transport.poll();
    expect(poll.transportState, 'PLAYING');
    expect(poll.duration, const Duration(seconds: 180));
    expect(poll.position, const Duration(milliseconds: 12500));
  });

  test('音量/静音不支持：固定文案 CastException（与 DLNA 无 RCS 同路径）', () async {
    final receiver = _FakeAirPlayReceiver();
    final port = await receiver.start();
    addTearDown(receiver.stop);

    final transport = AirPlayTransport(
      AirPlayDeviceInfo(host: '127.0.0.1', port: port),
    );
    addTearDown(transport.close);

    await expectLater(transport.setVolume(50),
        throwsA(isA<CastException>().having((e) => e.message, 'message', '设备不支持音量控制')));
    await expectLater(transport.setMute(true),
        throwsA(isA<CastException>().having((e) => e.message, 'message', '设备不支持静音控制')));
    expect(receiver.requests, isEmpty, reason: '不发任何音量请求');
  });

  test('控制器全链（默认工厂 → 真实 AirPlayTransport → 假接收端）', () async {
    final receiver = _FakeAirPlayReceiver();
    final port = await receiver.start();
    addTearDown(receiver.stop);

    final controller = CastController(
      airplayDiscover: () => Stream.value(
        AirPlayDeviceInfo(host: '127.0.0.1', port: port, name: 'UxPlay 电视'),
      ),
    );
    addTearDown(controller.dispose);
    controller.startScan();
    await Future<void>.delayed(Duration.zero);
    controller.stopScan();

    expect(controller.devices, hasLength(1));
    expect(controller.devices.first.protocol, CastProtocol.airplay);
    expect(controller.devices.first.name, 'UxPlay 电视');

    await controller.castTo(
      controller.devices.first,
      const CastMedia(url: 'http://x/1.mp4', title: '第1集'),
    );
    expect(controller.state, CastSessionState.casting);
    // 控制器标准序列：setUri(/play) → play(/rate?value=1.0)。
    expect(receiver.requests.map((r) => r.path).toList(),
        containsAllInOrder(['/play', '/rate']));

    // 立即拉一次状态（不等 1s 轮询）：接收端已报 playing。
    await controller.forceRefresh();
    expect(controller.remoteTransportState, 'PLAYING');
    expect(controller.remoteDuration, const Duration(seconds: 600));

    await controller.disconnect();
    expect(receiver.requests.last.path, '/stop');
  });
}
