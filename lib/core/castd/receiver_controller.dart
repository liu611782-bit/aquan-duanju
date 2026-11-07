/// 接收端对上层的唯一门面（design.md §6）：开关 start/stop、会话回调、
/// 状态查询。Phase B 的设置开关与接收端播放页只与本类对话。
///
/// UDN：调用方注入（生产从 CastStore.ensureReceiverUdn() 持久化读取，
/// Phase B 接线；测试直接传）；两者都缺省时临时生成（不落盘，重启变化
/// 仅影响发送端记忆的旧设备项）。
library;

import 'dart:async';
import 'dart:io';

import '../error_log.dart';
import 'receiver_descriptions.dart';
import 'receiver_gena.dart';
import 'receiver_http_server.dart';
import 'receiver_player_adapter.dart';
import 'receiver_renderer.dart';
import 'receiver_ssdp.dart';

/// 一次投送会话（显示「投送方地址/UA」用；URL 不落日志）。
class ReceiverSession {
  const ReceiverSession({
    required this.url,
    required this.title,
    required this.senderAddress,
    required this.senderUserAgent,
    required this.startedAt,
  });

  final String url;
  final String title;
  final String senderAddress;
  final String senderUserAgent;
  final DateTime startedAt;
}

class ReceiverController {
  ReceiverController({
    this.playerOverride,
    this.playerFactory,
    this.udnSeed,
    this.udnLoader,
    this.friendlyNameSeed,
    this.preferredPort = 18099,
    this.portAttempts = 20,
    this.enableSsdp = true,
    this.onIncomingSession,
  });

  /// Phase A 默认 stub 引擎；Phase B 注入 media_kit 适配实现。
  final ReceiverPlayer? playerOverride;

  /// 惰性引擎工厂：首次 start() 才创建（media_kit Player 不在构造期
  /// 初始化媒体库；测试传 [playerOverride] 即可，不走工厂）。
  final ReceiverPlayer Function()? playerFactory;

  final String? udnSeed;
  final Future<String?> Function()? udnLoader;
  final String? friendlyNameSeed;

  /// 用户改过的接收名（设置页可改；覆盖 [friendlyNameSeed]，空 = 未改）。
  String? friendlyNameOverride;

  final int preferredPort;
  final int portAttempts;

  /// SSDP 发现（B-4 Android 守卫与纯 HTTP 自测可关；关掉时设备只能靠
  /// 手动 IP 直连发现）。
  final bool enableSsdp;

  /// 来投回调（UI 打开接收端播放页；Phase B 接线）。
  void Function(ReceiverSession session)? onIncomingSession;

  ReceiverPlayer? _player;
  ReceiverRenderer? _renderer;
  ReceiverGena? _gena;
  ReceiverHttpServer? _http;
  ReceiverSsdpServer? _ssdp;
  String? _udn;
  ReceiverSession? _currentSession;
  bool _running = false;

  ReceiverPlayer get player => _player!;

  /// 未 start 过时为 null（开关关闭路径「尽力停引擎」用，不炸断言）。
  ReceiverPlayer? get playerOrNull => _player;

  bool get running => _running;

  /// HTTP 描述服务端口；未运行为 null。
  int? get port => _http?.port;

  String? get udn => _udn;

  /// 接收名：用户改名 > 注入名 > 「<主机名>（aquan 接收）」（R4.2 可改）。
  String get friendlyName {
    final override = friendlyNameOverride;
    if (override != null && override.isNotEmpty) return override;
    final seed = friendlyNameSeed;
    if (seed != null && seed.isNotEmpty) return seed;
    var host = '';
    try {
      host = Platform.localHostname;
    } catch (_) {}
    if (host.isEmpty) host = 'Aquan';
    return '$host（aquan 接收）';
  }

  ReceiverSession? get currentSession => _currentSession;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      _udn = udnSeed ?? (await udnLoader?.call()) ?? uuidV4();
      _player ??= playerOverride ?? playerFactory?.call() ?? StubReceiverPlayer();
      final player = _player!;
      _renderer ??= ReceiverRenderer(player: player, onOpened: _onMediaOpened);
      _gena ??= ReceiverGena(renderer: _renderer!);
      _http ??= ReceiverHttpServer(
        renderer: _renderer!,
        gena: _gena!,
        describe: () => receiverDeviceDescription(
          friendlyName: friendlyName,
          udn: _udn!,
        ),
        preferredPort: preferredPort,
        portAttempts: portAttempts,
      );
      await _http!.start();
      _gena!.start();
      if (enableSsdp) {
        _ssdp ??= ReceiverSsdpServer(udn: _udn!, httpPort: _http!.port!);
        await _ssdp!.start();
      }
    } catch (e, st) {
      _running = false;
      ErrorLog.instance.record('DLNA 接收·启动', e, st);
      await _teardown(sendByeBye: false);
      rethrow;
    }
  }

  /// 关闭：SSDP byebye + 清订阅 + 关 HTTP + 清会话（幂等）。
  Future<void> stop() async {
    if (!_running && _http == null) return;
    _running = false;
    await _teardown(sendByeBye: true);
  }

  Future<void> _teardown({required bool sendByeBye}) async {
    if (sendByeBye) {
      try {
        await _ssdp?.stop();
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·停止', e, st);
      }
    }
    _ssdp = null;
    _gena?.stop();
    _gena = null;
    try {
      await _http?.close();
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·HTTP 关闭', e, st);
    }
    _http = null;
    _currentSession = null;
  }

  void _onMediaOpened(ReceiverMediaOpened event) {
    _currentSession = ReceiverSession(
      url: event.url,
      title: event.title,
      senderAddress: event.senderAddress,
      senderUserAgent: event.senderUserAgent,
      startedAt: DateTime.now(),
    );
    onIncomingSession?.call(_currentSession!);
  }
}
