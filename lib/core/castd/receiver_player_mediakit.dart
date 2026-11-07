/// media_kit（libmpv）接收端引擎：**独立 Player 实例**，不与本地播放页
/// 共用（design §4——避免状态互踩）。
///
/// 本文件**只被生产接线 import**（`receiver_service.dart` 的 playerFactory），
/// 测试一律不 import：构造 [MediaKitReceiverPlayer] 会初始化媒体库单例，
/// 会破坏 flutter_tester（见任务约束）。可测的状态映射纯函数放在
/// `receiver_player_adapter.dart` 的 [mapReceiverTransportState]。
library;

import 'dart:async';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../error_log.dart';
import 'receiver_player_adapter.dart';

/// 位置事件的推送步长（毫秒）：progress 条 2~3 Hz 足够，避免 60fps 刷屏。
const int _positionEmitStepMs = 400;

class MediaKitReceiverPlayer implements ReceiverPlayer {
  MediaKitReceiverPlayer() {
    // main.dart 启动时已全局 ensureInitialized；这里幂等兜底（接收端
    // Player 惰性创建，早于 main 完成初始化的理论时序不存在）。
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
    );
    videoController = VideoController(_player);
    _subscriptions = [
      _player.stream.position.listen(_onPosition),
      _player.stream.duration.listen((_) => _emit()),
      _player.stream.playing.listen((_) => _emit()),
      _player.stream.completed.listen((_) => _emit()),
      _player.stream.buffering.listen((_) => _emit()),
      _player.stream.volume.listen((_) => _emit()),
    ];
  }

  late final Player _player;

  /// 接收端播放页 Video 控件用（media_kit_video 的渲染控制器）。
  late final VideoController videoController;

  List<StreamSubscription<dynamic>> _subscriptions = const [];

  final StreamController<ReceiverPlayerStatus> _status =
      StreamController<ReceiverPlayerStatus>.broadcast();

  /// 引擎状态意图（引擎实况之上的一层薄记）：
  /// SetAVTransportURI 后未显式 Play 前 = 已加载待播（STOPPED 语义）；
  /// Stop 动作后引擎实况不可信（mpv stop 后 playing=false 但并非暂停），
  /// 在下次 load/play 前恒报 STOPPED。从未 load 过 = 无媒体。
  bool _hasMedia = false;
  bool _loadedNotPlayed = false;
  bool _stopRequested = false;

  /// media_kit 1.2.6 没有 mute 状态/流（mpv 属性 `mute`）：显式记录
  /// setMuted 的写入值作为实况（本引擎的静音只来自 DLNA SetMute 与本页
  /// 静音键，两条路径都经过 [setMuted]）。
  bool _muted = false;

  int _lastEmittedPositionMs = -1;

  @override
  Stream<ReceiverPlayerStatus> get statusStream => _status.stream;

  @override
  ReceiverPlayerStatus status() {
    final s = _player.state;
    return ReceiverPlayerStatus(
      transportState: mapReceiverTransportState(
        hasMedia: _hasMedia,
        stopRequested: _stopRequested,
        loadedNotPlayed: _loadedNotPlayed,
        buffering: s.buffering,
        playing: s.playing,
        completed: s.completed,
      ),
      position: s.position,
      duration: s.duration,
      volume: s.volume.clamp(0, 100).round(),
      muted: _muted,
    );
  }

  @override
  Future<void> load(Uri url, {String? title, String? subtitleUrl}) async {
    _hasMedia = true;
    _loadedNotPlayed = true;
    _stopRequested = false;
    _lastEmittedPositionMs = -1;
    // SetAVTransportURI 语义：装载待播，不自动出画（发送端随后显式 Play）。
    await _player.open(Media(url.toString()), play: false);
    // 外挂字幕（R2.2）：libmpv sub-files 语义，SRT/VTT 原样喂（libmpv 自
    // 解析）；字幕源不可达 / 加载失败静默无字幕，不阻断视频播放。
    if (subtitleUrl != null && subtitleUrl.isNotEmpty) {
      try {
        await _player.setSubtitleTrack(SubtitleTrack.uri(subtitleUrl));
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·加载字幕', e, st);
      }
    }
    _emit();
  }

  @override
  Future<void> play() async {
    _loadedNotPlayed = false;
    _stopRequested = false;
    await _player.play();
    _emit();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _emit();
  }

  @override
  Future<void> stop() async {
    _stopRequested = true;
    _loadedNotPlayed = false;
    await _player.stop();
    _emit();
  }

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(int percent) =>
      _player.setVolume(percent.clamp(0, 100).toDouble());

  @override
  Future<void> setMuted(bool muted) async {
    _muted = muted;
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        await platform.setProperty('mute', muted ? 'yes' : 'no');
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·静音', e, st);
      }
    }
    _emit();
  }

  void _onPosition(Duration position) {
    // 位置步长节流：状态类事件照发，位置类事件 400ms 一帧。
    final ms = position.inMilliseconds;
    if ((_lastEmittedPositionMs - ms).abs() < _positionEmitStepMs) return;
    _lastEmittedPositionMs = ms;
    _emit();
  }

  void _emit() {
    if (!_status.hasListener) return;
    _status.add(status());
  }

  /// 释放引擎（App 生命周期内接收端 Player 常驻，本方法供将来接线用；
  /// 当前 stop() 即语义终点，Player 不随开关销毁）。
  Future<void> dispose() async {
    for (final sub in _subscriptions) {
      try {
        await sub.cancel();
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·引擎订阅清理', e, st);
      }
    }
    _subscriptions = const [];
    await _status.close();
    await _player.dispose();
  }
}
