/// 接收端播放引擎抽象 + Phase A stub 实现。
///
/// 状态机口径（design.md §4）：**引擎是状态的唯一事实源**（GetPositionInfo
/// 读引擎实况，不另记假账，PRD R3.2）；渲染器只在「无 URI」时把上报状态
/// 归一为 NO_MEDIA_PRESENT。Phase B 由 Windows 实现接线 media_kit（独立
/// Player 实例，不与本地播放页共用）；测试与 Phase A 默认用
/// [StubReceiverPlayer]。
library;

import 'dart:async';

/// UPnP TransportState 常量（蓝本 DlnaState.kt）。
const String kTransportNoMedia = 'NO_MEDIA_PRESENT';
const String kTransportTransitioning = 'TRANSITIONING';
const String kTransportPlaying = 'PLAYING';
const String kTransportPaused = 'PAUSED_PLAYBACK';
const String kTransportStopped = 'STOPPED';

/// 全部合法转移状态（SCPD allowedValueList 同源）。
const List<String> kTransportStates = [
  kTransportStopped,
  kTransportPlaying,
  kTransportPaused,
  kTransportTransitioning,
  kTransportNoMedia,
];

/// 引擎实况快照。[transportState] 必须是 [kTransportStates] 之一。
class ReceiverPlayerStatus {
  const ReceiverPlayerStatus({
    required this.transportState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.volume = 100,
    this.muted = false,
  });

  final String transportState;
  final Duration position;
  final Duration duration;
  final int volume;
  final bool muted;
}

/// 引擎实况 → UPnP TransportState 的纯映射（media_kit 适配层使用；stub
/// 引擎状态本就是 UPnP 口径不经此）。
///
/// 优先级（蓝本 DlnaState.kt 口径 + 本任务 design §4）：
/// 无媒体 → NO_MEDIA_PRESENT；收到过 Stop → STOPPED（下次 load/play 前
/// 引擎实况不可信）；缓冲中 → TRANSITIONING；播放中 → PLAYING；
/// 自然播完 / 已加载未播 → STOPPED；其余（暂停）→ PAUSED_PLAYBACK。
String mapReceiverTransportState({
  required bool hasMedia,
  required bool stopRequested,
  required bool loadedNotPlayed,
  required bool buffering,
  required bool playing,
  required bool completed,
}) {
  if (!hasMedia) return kTransportNoMedia;
  if (stopRequested) return kTransportStopped;
  if (buffering) return kTransportTransitioning;
  if (playing) return kTransportPlaying;
  if (completed) return kTransportStopped;
  if (loadedNotPlayed) return kTransportStopped;
  return kTransportPaused;
}

/// 接收端播放引擎抽象。
///
/// `status()` 为同步读取（实现方持有引擎回调缓存的最新值）；动作方法
/// 返回 Future，失败抛异常（渲染器不翻译为 SOAP fault，引擎故障只进
/// ErrorLog——协议面只对「非法请求」回 fault）。
abstract class ReceiverPlayer {
  ReceiverPlayerStatus status();

  /// 实况流（接收端播放页订阅；实现方在状态/进度变化时推送，位置类
  /// 事件可节流）。
  Stream<ReceiverPlayerStatus> get statusStream;

  /// 载入媒体（SetAVTransportURI）：进入 TRANSITIONING，完成后 STOPPED
  /// （已加载待播）。重复 load = 新投替换当前会话。[subtitleUrl] 为 DIDL
  /// 提取的外挂字幕地址（无则 null；附加失败静默无字幕，不阻断视频，R2.2）。
  Future<void> load(Uri url, {String? title, String? subtitleUrl});

  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration position);
  Future<void> setVolume(int percent);
  Future<void> setMuted(bool muted);
}

/// 测试 / Phase A 默认引擎：内存状态机，[position] 不自走（测试直接赋值）。
///
/// [duration] 由引擎持有方（真实引擎=媒体元数据；测试=直接赋值）设置，
/// GetPositionInfo 的 TrackDuration 从这里出 `H:MM:SS`。任何状态/进度
/// 变化都会往 [statusStream] 推一帧实况。
class StubReceiverPlayer implements ReceiverPlayer {
  StubReceiverPlayer({this.loadDelay = Duration.zero, this.autoPlay = false});

  /// load 停留 TRANSITIONING 的时长（0 = 立即到 STOPPED）。
  final Duration loadDelay;

  /// load 完成后是否自动 PLAYING（多数 DLNA 发送端会显式 Play，默认 false）。
  final bool autoPlay;

  final StreamController<ReceiverPlayerStatus> _status =
      StreamController<ReceiverPlayerStatus>.broadcast();

  String _state = kTransportNoMedia;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _volume = 100;
  bool _muted = false;

  Uri? loadedUri;
  String? loadedTitle;
  String? loadedSubtitleUrl;
  int loadCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  final List<Duration> seeks = [];
  final List<int> volumes = [];
  final List<bool> mutes = [];

  /// 测试直改状态（驱动全转移表）。
  set state(String value) {
    _state = value;
    _notify();
  }

  set position(Duration value) {
    _position = value;
    _notify();
  }

  Duration get duration => _duration;

  set duration(Duration value) {
    _duration = value;
    _notify();
  }

  int get volume => _volume;

  bool get muted => _muted;

  void _notify() {
    if (!_status.hasListener) return;
    _status.add(status());
  }

  @override
  Stream<ReceiverPlayerStatus> get statusStream => _status.stream;

  @override
  ReceiverPlayerStatus status() => ReceiverPlayerStatus(
        transportState: _state,
        position: _position,
        duration: _duration,
        volume: _volume,
        muted: _muted,
      );

  @override
  Future<void> load(Uri url, {String? title, String? subtitleUrl}) async {
    loadCount++;
    loadedUri = url;
    loadedTitle = title;
    loadedSubtitleUrl = subtitleUrl;
    _state = kTransportTransitioning;
    _position = Duration.zero;
    _notify();
    if (loadDelay > Duration.zero) {
      await Future<void>.delayed(loadDelay);
    }
    state = autoPlay ? kTransportPlaying : kTransportStopped;
  }

  @override
  Future<void> play() async {
    playCount++;
    // 加载中 / 无媒体时忽略（渲染器已对无 URI 回 710，这里兜底）。
    if (_state == kTransportTransitioning || _state == kTransportNoMedia) {
      return;
    }
    state = kTransportPlaying;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (_state == kTransportPlaying) state = kTransportPaused;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (_state != kTransportNoMedia) state = kTransportStopped;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (_state != kTransportNoMedia) this.position = position;
  }

  @override
  Future<void> setVolume(int percent) async {
    volumes.add(percent);
    _volume = percent;
    _notify();
  }

  @override
  Future<void> setMuted(bool value) async {
    mutes.add(value);
    _muted = value;
    _notify();
  }
}
