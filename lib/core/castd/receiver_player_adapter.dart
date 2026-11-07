/// 接收端播放引擎抽象 + Phase A stub 实现。
///
/// 状态机口径（design.md §4）：**引擎是状态的唯一事实源**（GetPositionInfo
/// 读引擎实况，不另记假账，PRD R3.2）；渲染器只在「无 URI」时把上报状态
/// 归一为 NO_MEDIA_PRESENT。Phase B 由 Windows 实现接线 media_kit（独立
/// Player 实例，不与本地播放页共用）；测试与 Phase A 默认用
/// [StubReceiverPlayer]。
library;

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

/// 接收端播放引擎抽象。
///
/// `status()` 为同步读取（实现方持有引擎回调缓存的最新值）；动作方法
/// 返回 Future，失败抛异常（渲染器不翻译为 SOAP fault，引擎故障只进
/// ErrorLog——协议面只对「非法请求」回 fault）。
abstract class ReceiverPlayer {
  ReceiverPlayerStatus status();

  /// 载入媒体（SetAVTransportURI）：进入 TRANSITIONING，完成后 STOPPED
  /// （已加载待播）。重复 load = 新投替换当前会话。
  Future<void> load(Uri url, {String? title});

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
/// GetPositionInfo 的 TrackDuration 从这里出 `H:MM:SS`。
class StubReceiverPlayer implements ReceiverPlayer {
  StubReceiverPlayer({this.loadDelay = Duration.zero, this.autoPlay = false});

  /// load 停留 TRANSITIONING 的时长（0 = 立即到 STOPPED）。
  final Duration loadDelay;

  /// load 完成后是否自动 PLAYING（多数 DLNA 发送端会显式 Play，默认 false）。
  final bool autoPlay;

  String _state = kTransportNoMedia;
  Duration _position = Duration.zero;
  Duration duration = Duration.zero;
  int volume = 100;
  bool muted = false;

  Uri? loadedUri;
  String? loadedTitle;
  int loadCount = 0;
  int playCount = 0;
  int pauseCount = 0;
  int stopCount = 0;
  final List<Duration> seeks = [];
  final List<int> volumes = [];
  final List<bool> mutes = [];

  /// 测试直改状态（驱动全转移表）。
  set state(String value) => _state = value;

  set position(Duration value) => _position = value;

  @override
  ReceiverPlayerStatus status() => ReceiverPlayerStatus(
        transportState: _state,
        position: _position,
        duration: duration,
        volume: volume,
        muted: muted,
      );

  @override
  Future<void> load(Uri url, {String? title}) async {
    loadCount++;
    loadedUri = url;
    loadedTitle = title;
    _state = kTransportTransitioning;
    _position = Duration.zero;
    if (loadDelay > Duration.zero) {
      await Future<void>.delayed(loadDelay);
    }
    _state = autoPlay ? kTransportPlaying : kTransportStopped;
  }

  @override
  Future<void> play() async {
    playCount++;
    // 加载中 / 无媒体时忽略（渲染器已对无 URI 回 710，这里兜底）。
    if (_state == kTransportTransitioning || _state == kTransportNoMedia) {
      return;
    }
    _state = kTransportPlaying;
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (_state == kTransportPlaying) _state = kTransportPaused;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    if (_state != kTransportNoMedia) _state = kTransportStopped;
  }

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (_state != kTransportNoMedia) _position = position;
  }

  @override
  Future<void> setVolume(int percent) async {
    volumes.add(percent);
    volume = percent;
  }

  @override
  Future<void> setMuted(bool value) async {
    mutes.add(value);
    muted = value;
  }
}
