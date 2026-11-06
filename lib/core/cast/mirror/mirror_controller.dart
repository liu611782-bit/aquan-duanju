import 'dart:async';

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../aqua_api.dart';
import '../../error_log.dart';
import '../cast_target.dart';

/// 屏幕镜像状态机（Android 原生 MirrorService 的 Dart 桥）。
///
/// 流程：requestPermission（系统投屏确认框）→ start（起前台服务，等 mirrorStarted
/// 事件拿 /stream.ts URL）→ 面板用该 URL 走既有 DLNA 投屏；服务自毁/致命错误经
/// mirrorStopped 事件回 idle。
class MirrorController extends ChangeNotifier {
  MirrorController._() {
    _channel.setMethodCallHandler(_onEvent);
  }

  static final MirrorController instance = MirrorController._();

  static const _channel = MethodChannel('aquan/cast');
  static const _startTimeout = Duration(seconds: 15);

  /// 启动等待预算。默认 15s；测试钩子可缩短以覆盖超时路径。
  Duration _startTimeoutDuration = _startTimeout;
  // ignore: avoid_setters_without_getters
  set debugStartTimeout(Duration value) => _startTimeoutDuration = value;

  MirrorState _state = MirrorState.idle;
  String? _url;
  bool _hasAudio = false;
  String? _lastError;
  Completer<Map<Object?, Object?>>? _startCompleter;

  // 桌面（Windows）分支：Go 中继会话。
  String? _desktopSession;
  AquaApi? _desktopApi;

  /// 平台分支依据。测试钩子：单测注入 true 走 Android 通道路径（flutter test
  /// 跑在宿主平台上，Platform.isAndroid 恒 false 会踩错分支）。
  bool _androidMode = Platform.isAndroid;
  // ignore: avoid_setters_without_getters
  set debugAndroidMode(bool value) => _androidMode = value;

  MirrorState get state => _state;
  String? get url => _url;
  bool get hasAudio => _hasAudio;
  String? get lastError => _lastError;
  bool get isMirroring => _state == MirrorState.mirroring;

  Future<void> _onEvent(MethodCall call) async {
    switch (call.method) {
      case 'mirrorStarted':
        final args = (call.arguments as Map?)?.cast<Object?, Object?>() ?? const {};
        final pending = _startCompleter;
        _startCompleter = null; // 先置空：重复/晚到事件不再 complete。
        // 超时后迟到的启动回执：该次 start 已放弃，不复活状态机。
        if (pending == null && _state != MirrorState.starting) break;
        _url = args['url'] as String?;
        _hasAudio = args['audio'] as bool? ?? false;
        if (pending != null && !pending.isCompleted) pending.complete(args);
        _state = MirrorState.mirroring;
        notifyListeners();
      case 'mirrorStopped':
        final pending = _startCompleter;
        _startCompleter = null;
        final reason = args(call)['reason'];
        if (reason != 'stopped') {
          // 原生侧失败原因（固定文案/简短 message，不含 URL 与凭据）落 ErrorLog。
          ErrorLog.instance.record('镜像服务', '服务事件: ${reason ?? '未知原因'}');
        }
        if (pending != null && !pending.isCompleted) {
          pending.completeError(CastException('镜像服务停止（$reason）'));
        }
        _state = MirrorState.idle;
        _url = null;
        notifyListeners();
    }
  }

  static Map<Object?, Object?> args(MethodCall call) =>
      (call.arguments as Map?)?.cast<Object?, Object?>() ?? const {};

  /// 请求系统投屏授权；用户拒绝/失败返回 false。桌面端无需授权直接通过。
  Future<bool> requestPermission() async {
    if (!_androidMode) return true;
    try {
      final r = await _channel
          .invokeMethod<Map>('requestMirrorPermission')
          .timeout(const Duration(minutes: 2));
      final granted = r?['granted'] as bool? ?? false;
      if (!granted) {
        _lastError = '未授权屏幕录制';
        notifyListeners();
      }
      return granted;
    } on Exception {
      _lastError = '无法发起屏幕录制授权';
      notifyListeners();
      return false;
    }
  }

  /// 启动镜像：Android 走 MediaProjection 通道；桌面（Windows）走 Go 桌面中继
  /// （ddagrab→HLS，[api] 必填）。返回可直接投给电视的 URL；失败返回 null。
  Future<String?> start({bool withAudio = true, AquaApi? api}) async {
    if (_state == MirrorState.mirroring || _state == MirrorState.starting) {
      return _url;
    }
    if (!_androidMode) {
      if (api == null) {
        _lastError = '桌面镜像需要 api 引用';
        notifyListeners();
        return null;
      }
      _state = MirrorState.starting;
      _lastError = null;
      notifyListeners();
      try {
        final r = await api.castDesktopStart().timeout(_startTimeout);
        _desktopApi = api;
        _desktopSession = r['session'] as String?;
        _url = r['url'] as String?;
        _hasAudio = false; // 桌面首版仅视频
        _state = _url != null && _url!.isNotEmpty
            ? MirrorState.mirroring
            : MirrorState.idle;
        if (_state != MirrorState.mirroring) {
          _lastError = '桌面镜像启动失败';
        }
        notifyListeners();
        return _url;
      } on Exception catch (e) {
        _lastError = e is CastException ? e.message : '桌面镜像启动失败';
        _state = MirrorState.idle;
        notifyListeners();
        return null;
      }
    }
    _state = MirrorState.starting;
    _lastError = null;
    notifyListeners();
    final completer = _startCompleter = Completer<Map<Object?, Object?>>();
    try {
      await _channel.invokeMethod<bool>('startMirror', {'withAudio': withAudio});
      final args = await completer.future.timeout(_startTimeoutDuration);
      if ((args['url'] as String?)?.isNotEmpty != true) {
        throw CastException('镜像服务未返回地址');
      }
      _lastError = null;
      return _url;
    } on Exception catch (e) {
      _lastError = e is CastException ? e.message : '镜像启动失败';
      _state = MirrorState.idle;
      notifyListeners();
      return null;
    } finally {
      // 15s 超时/通道失败：先丢弃挂起的 completer 再走失败文案。
      // 晚到的 mirrorStarted/mirrorStopped 不会对已废弃的 future 二次 complete。
      // 成功路径上事件处理里已置空，这里的 identical 判断不会误清新会话。
      if (identical(_startCompleter, completer)) _startCompleter = null;
    }
  }

  /// 停止镜像服务（投屏会话结束时由 CastController 调用，幂等）。
  Future<void> stop() async {
    if (_state == MirrorState.idle) return;
    if (!_androidMode) {
      final session = _desktopSession;
      _desktopSession = null;
      final api = _desktopApi;
      _desktopApi = null;
      _state = MirrorState.idle;
      _url = null;
      notifyListeners();
      if (session != null && api != null) {
        await api.castDesktopStop(session).catchError((_) {});
      }
      return;
    }
    _state = MirrorState.stopping;
    notifyListeners();
    try {
      await _channel.invokeMethod<void>('stopMirror');
    } on Exception {
      // 服务可能已自毁；等 mirrorStopped 事件兜底。
    }
  }

  /// 测试钩子：直接注入状态（不经过通道）。
  // ignore: avoid_setters_without_getters
  set debugState(MirrorState value) {
    _state = value;
    notifyListeners();
  }
}

enum MirrorState { idle, requesting, starting, mirroring, stopping }
