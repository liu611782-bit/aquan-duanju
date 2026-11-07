import 'dart:math';

import 'package:http/http.dart' as http;

import '../cast_controller.dart';
import '../cast_target.dart';
import 'plist_codec.dart';

/// AirPlay 1 经典视频投送传输（无配对 `/play` 路径）。
///
/// 报文口径逐条对照 dart_cast `airplay_client.dart`（纯 Dart、真机验证过的
/// 未配对客户端；HAP 配对后的 `airplay_media_controller.dart` 二进制 plist
/// 路径是二期范围，一期不采用）：
///
/// - `/play`：POST，`Content-Type: text/parameters`，body 为
///   `Content-Location: <url>\nStart-Position: <fraction>\n` 文本体。
///   AirPlay 1 的 `Start-Position` 是 0.0–1.0 的**比例**而非秒
///   （蓝本 `playV1`/`playV1Text` 同口径；加载时未知总时长，秒无法换算），
///   故起播恒为 0，续播由控制器的 `seekTo` → `/scrub?position=` 兜底。
/// - `/rate?value=1.0|0.0`：播放/暂停（AirPlay 1 HTTP 控制端点，无 body）。
/// - `/scrub?position=<s>`：拖动到绝对秒。
/// - `/stop`：停止，随后换新会话 ID（蓝本同款）。
/// - `/playback-info`：GET，回 XML plist（AirPlay 1）或二进制 plist
///   （AirPlay 2 接收端），按 Content-Type/魔数分流解码。
///
/// 音量/静音：AirPlay 1 无音量遥控端点——抛 [CastException]（固定中文文案，
/// 与 DLNA 无 RCS 的「不支持」降级同路径，面板吞掉异常保持现状交互）。
class AirPlayTransport implements CastTransport {
  AirPlayTransport(
    this.device, {
    http.Client? client,
    this.timeout = const Duration(seconds: 5),
  }) : _client = client ?? http.Client();

  final AirPlayDeviceInfo device;
  final http.Client _client;

  /// 单请求超时（与 Chromecast 就绪等待同量级；轮询另有控制器 3s 上限）。
  final Duration timeout;

  /// 会话 ID：每次播放会话一个，stop 后换新（蓝本 `_generateUuid` 口径）。
  String _sessionId = _generateUuid();

  /// 是否已见过「已加载」状态（readyToPlay/duration/非零位置）。
  /// 此前 `/playback-info` 回空是起播加载中；此后再回空是接收端停止。
  bool _everLoaded = false;

  @override
  Future<void> setUri(Uri url,
      {required String title, String? duration, Uri? subtitleUrl}) async {
    // AirPlay 1 /play 无标题/时长/字幕通道；字幕由接收端自行决定（一期不做）。
    _everLoaded = false;
    await _post(
      '/play',
      body: 'Content-Location: $url\nStart-Position: 0.0\n',
      contentType: 'text/parameters',
    );
  }

  @override
  Future<void> play() => _rate(1.0);

  @override
  Future<void> pause() => _rate(0.0);

  @override
  Future<void> stop() async {
    await _post('/stop');
    // 换会话 ID：下一次投送是新会话（蓝本 AirPlayClient.stop 同款）。
    _sessionId = _generateUuid();
    _everLoaded = false;
  }

  @override
  Future<void> seekTo(Duration position) => _post(
        '/scrub',
        query: {'position': '${position.inMilliseconds / 1000.0}'},
      );

  @override
  Future<void> setVolume(int percent) async {
    throw CastException('设备不支持音量控制');
  }

  @override
  Future<void> setMute(bool muted) async {
    throw CastException('设备不支持静音控制');
  }

  @override
  Future<CastPoll> poll() async {
    final response = await _get('/playback-info');
    final info = PlistCodec.parsePlaybackInfo(
      response.bodyBytes,
      contentType: response.headers['content-type'] ?? '',
    );
    if (info.loaded) _everLoaded = true;
    return CastPoll(
      // 状态映射（蓝本 airplay_session 状态机口径：!readyToPlay=缓冲、
      // rate==0=暂停、rate>0=播放）+ 本仓 CastPoll 词汇表：
      transportState: info.rate > 0
          ? 'PLAYING'
          : info.rate == 0 && info.loaded
              ? 'PAUSED_PLAYBACK'
              // 还没加载过就回空 = /play 后起播加载中（绝不能报 STOPPED，
              // 否则控制器的「远端停止」路径会立刻杀掉新会话）。
              : _everLoaded
                  ? 'STOPPED'
                  : 'BUFFERING',
      position:
          Duration(milliseconds: (info.position * 1000).round()),
      duration: Duration(milliseconds: (info.duration * 1000).round()),
    );
  }

  @override
  void close() {
    _client.close();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  Future<void> _rate(double value) =>
      _post('/rate', query: {'value': '${value.toDouble()}'});

  Uri _uri(String path, {Map<String, String>? query}) => Uri(
        scheme: 'http',
        host: device.host,
        port: device.port,
        path: path,
        queryParameters: query,
      );

  Map<String, String> get _headers => {
        'User-Agent': 'MediaControl/1.0',
        'X-Apple-Session-ID': _sessionId,
      };

  Future<http.Response> _post(
    String path, {
    Map<String, String>? query,
    String? body,
    String? contentType,
  }) async {
    try {
      final response = await _client
          .post(
            _uri(path, query: query),
            headers: {
              ..._headers,
              'Content-Type': ?contentType,
            },
            body: body,
          )
          .timeout(timeout);
      return _check(response, path);
    } on CastException {
      rethrow;
    } on Exception {
      throw CastException('AirPlay 无响应（$path 超时或连接失败）');
    }
  }

  Future<http.Response> _get(String path) async {
    try {
      final response = await _client
          .get(_uri(path), headers: _headers)
          .timeout(timeout);
      return _check(response, path);
    } on CastException {
      rethrow;
    } on Exception {
      throw CastException('AirPlay 无响应（$path 超时或连接失败）');
    }
  }

  http.Response _check(http.Response response, String endpoint) {
    if (response.statusCode != 200) {
      throw CastException('AirPlay 设备拒绝请求（$endpoint HTTP ${response.statusCode}）');
    }
    return response;
  }

  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }
}
