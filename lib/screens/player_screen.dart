import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:screen_retriever/screen_retriever.dart' as sr;
import 'package:share_plus/share_plus.dart';
import 'package:smtc_windows/smtc_windows.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../cli/launch_command.dart';
import '../cli/player_bus.dart';
import '../core/error_log.dart';
import '../core/aqua_error.dart';
import '../core/cast/cast_controller.dart';
import '../core/muted_hint.dart';
import '../core/next_episode_prompt.dart';
import '../core/playback_diagnostics.dart';
import '../core/player/playback_buffer_monitor.dart';
import '../core/player/playback_health.dart';
import '../core/playback_failure.dart';
import '../core/playback_fallback.dart';
import '../core/playback_recovery.dart';
import '../core/playback_utils.dart';
import '../core/player_layout.dart';
import '../core/player/player_engine.dart';
import '../core/player/track_preference.dart';
import '../core/progress_throttle.dart';
import '../models/models.dart';
import '../models/play_skip.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/cast_panel.dart';
import '../widgets/download_sheet.dart';
import '../widgets/episode_picker.dart';
import '../widgets/playback_error_panel.dart';
import '../widgets/player_info_dialog.dart';
import '../widgets/player_track_sheet.dart';

/// 播放器页。
///
/// 播放链路：resolvePlayback 选流 → 受保护流带 contentKey 经 mpv 的
/// demuxer-lavf-o decryption_key 解密（与 guoappxxx 验证过的方案一致）→
/// 完结/手势切换上下集 → 每 5 秒回写本地历史。
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.series,
    required this.episodes,
    required this.startIndex,
    this.startAt = Duration.zero,
  });

  final Series series;
  final List<Episode> episodes;
  final int startIndex;
  final Duration startAt;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    implements PlayerHandle {
  late final PlayerEngine _engine;
  bool _prepared = false;
  bool _disposed = false;

  int _index = 0;
  PlaybackResult? _playback;
  String? _selectedDefinition;
  List<String> _definitions = const [];
  double _speed = 1.0;

  /// 字幕时差（秒；mpv sub-delay，正=延后）。按剧记忆，开播时注入。
  double _subDelay = 0;

  /// 音轨/字幕选择按剧记忆（面板展示序；字幕 -1=关闭）。
  int? _prefAudioIndex;
  int? _prefSubtitleIndex;
  String? _prefAudioKey;
  String? _prefSubtitleKey;
  bool _trackPrefApplied = false;
  StreamSubscription? _tracksSub;

  /// 这部剧的清晰度偏好：初始化自该剧本的历史，跟随用户切换而更新。
  String _quality = '';

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _showControls = true;
  Timer? _hideTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<PlayerLog>? _logSub;
  StreamSubscription<bool>? _bufferingSub;
  bool _buffering = false;

  /// 慢缓冲判定器：把「卡」分成起播超时/长缓冲/频繁/累计，命中后记线路健康度。
  final PlaybackBufferMonitor _bufferMonitor = PlaybackBufferMonitor();

  /// 位置跳变超过这个幅度就当作 seek（3 倍速正常播放远小于它）。
  static const Duration _seekJumpThreshold = Duration(seconds: 5);

  /// dispose 里不能再查 context：历史 store 先缓存一次。
  late final HistoryStore _history = AppScope.read(context).history;
  Timer? _bufferTimer;

  /// mpv 引擎日志环形缓冲（诊断面板用）。
  final RecentLogBuffer _logBuffer = RecentLogBuffer();
  StreamSubscription<String>? _errorSub;
  String? _rawPlaybackError;
  PlaybackFailure? _playbackFailure;

  /// 历史写盘节流 + 并发保护。
  final ProgressWriteThrottle _historyThrottle = ProgressWriteThrottle();
  bool _historyWriteInFlight = false;

  /// 本集是否已自然播完（防止 stop / dispose 用未完成进度覆盖「已看完」）。
  bool _episodeEnded = false;

  /// 智能换线状态。
  final Set<String> _triedUrls = {};
  List<PlaybackCandidate> _candidates = const [];
  Timer? _fallbackTimer;
  bool _fallbackInFlight = false;

  /// 本集自动恢复预算（换线次数上限，防「错误→防抖→换线」循环折腾）。
  final PlaybackRecoveryBudget _recoveryBudget = PlaybackRecoveryBudget();
  int _playEpoch = 0;
  Duration _attemptStart = Duration.zero;
  static const Duration _earlyWindow = Duration(seconds: 15);

  /// 本集是否已经重新解析过播放地址（签名 URL 过期兜底，每集只做一次）。
  bool _reResolved = false;
  bool _reResolving = false;

  /// 换集 epoch：快速连点时，旧的解析结果直接丢弃。
  int _openEpoch = 0;

  /// 片头片尾。
  PlaySkipEntry? _playSkip;
  bool _openingNoticePending = false;
  bool _endingHandled = false;

  /// 静音起播提醒（同一部剧只提醒一次，进程内去重）。
  static final MutedPlaybackHintRegistry _mutedHints =
      MutedPlaybackHintRegistry();
  bool _mutedHintVisible = false;

  /// 下一集提示条（播完前引导；与片尾跳过互斥，见 next_episode_prompt.dart）。
  final Set<String> _nextPromptConsumed = {};
  bool _nextPromptVisible = false;
  int _nextPromptRemainingMs = 0;
  Timer? _nextPromptTimer;
  Timer? _mutedHintTimer;

  /// 播放器 OSD。
  String? _osdText;
  IconData? _osdIcon;
  Timer? _osdTimer;

  // Windows 系统媒体控制（SMTC）。
  SMTCWindows? _smtc;
  StreamSubscription<PressedButton>? _smtcSub;
  int _lastSmtcSecond = -1;

  // 手势状态。
  Timer? _sleepTimer;
  int _sleepMinutes = 0;

  /// 当前播放的流（备用容错用）；本地播放为 null。
  VideoStream? _currentVideoStream;

  /// 投屏解密中继会话（castrelay.go）：投屏结束/退出时回收。
  String? _relaySession;

  /// 连播预解析：集下标 → 已解析的播放结果（本会话内复用）。
  final Map<int, PlaybackResult> _prefetched = {};

  double _lastBrightness = 0.5;
  double? _dragStartPos;
  double? _dragStartVolume;
  double? _dragStartBrightness;
  _DragKind? _dragKind;
  double? _seekPreviewMs;
  double? _overlayValue;

  Object? _loadError;
  bool _loadingStream = true;
  bool _fittedWindow = false;
  bool _muted = false;

  /// 桌面迷你置顶小窗状态（还原时恢复原窗口位置）。
  bool _mini = false;
  Rect? _preMiniBounds;

  /// 桌面「铺满」模式：画面 cover 裁剪填充窗口（抖音式），再点切回 contain。
  bool _fill = false;

  /// 播放方向：auto = 跟随传感器；locked = 由「横屏/竖屏」按钮锁定。
  ///
  /// 移动端进页**一律先竖屏**（含横屏电影），横屏画面靠 `BoxFit.contain`
  /// 在竖屏容器里上下留黑边；用户旋转设备或点按钮才横过来。
  _OrientationMode _orientMode = _OrientationMode.auto;
  bool _lockedLandscape = false;

  /// 首次 `_applyOrientation` 已执行（换集不再强制竖屏）。
  bool _orientationReady = false;
  Timer? _orientationUnlockTimer;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  void initState() {
    super.initState();
    if (widget.episodes.isEmpty) {
      // 防御：调用方应保证非空；空列表直接报错态而不是崩溃。
      _loadingStream = false;
      _loadError = AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可播放的分集',
          retryable: false);
      return;
    }
    _index = widget.startIndex.clamp(0, widget.episodes.length - 1);
    // 播放偏好按剧记忆：上次用的倍速/清晰度优先，否则用全局默认。
    final scope = AppScope.read(context);
    final prefs = scope.history.get(widget.series.id);
    _speed = (prefs != null && prefs.speed > 0)
        ? prefs.speed
        : (double.tryParse(scope.settings.defaultSpeed) ?? 1.0);
    _quality = (prefs != null && prefs.quality.isNotEmpty)
        ? prefs.quality
        : scope.settings.defaultQuality;
    _subDelay = (prefs?.subtitleDelayMs ?? 0) / 1000.0;
    _prefAudioIndex = prefs?.audioTrackIndex;
    _prefSubtitleIndex = prefs?.subtitleTrackIndex;
    _prefAudioKey =
        (prefs?.audioTrackKey ?? '').isEmpty ? null : prefs!.audioTrackKey;
    _prefSubtitleKey = (prefs?.subtitleTrackKey ?? '').isEmpty
        ? null
        : prefs!.subtitleTrackKey;
    _engine = MpvPlayerEngine();
    // 轨道就绪事件驱动：每集只应用一次偏好（换集重置标记）。
    _tracksSub = _engine.stream.tracks.listen((_) => _applyTrackPreference());
    // 投屏：电视端主动停止时按设置回本地续播（M1：加密分集不可投，入口处拦截）。
    castController.onRemoteStopped = (device, position) {
      if (!mounted) return;
      unawaited(_stopRelayIfAny());
      _resumeLocalAfterCast(position);
    };
    unawaited(_installMpvOptions());
    _playSkip = AppScope.read(context).playSkip.entryFor(widget.series.id);
    // 恢复上次音量。
    _engine.setVolume(AppScope.read(context).settings.volume);
    _posSub = _engine.stream.position.listen(_onPosition);
    _durSub = _engine.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _playingSub = _engine.stream.playing.listen((playing) {
      if (!playing && _prepared && !_disposed) _flushHistory();
      if (playing) _bufferMonitor.onPlaying();
      if (!Platform.isWindows) return;
      try {
        _smtc?.setPlaybackStatus(
            playing ? PlaybackStatus.playing : PlaybackStatus.paused);
      } catch (_) {}
    });
    _completedSub = _engine.stream.completed.listen((completed) {
      if (completed) _onEnded();
    });
    _errorSub = _engine.stream.error.listen(_onPlaybackError);
    _logSub = _engine.stream.log.listen((log) {
      _logBuffer.add('[${log.level}] ${log.text}');
    });
    _bufferingSub = _engine.stream.buffering.listen((buffering) {
      _bufferMonitor.onBuffering(buffering);
      if (mounted) setState(() => _buffering = buffering);
    });
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    PlayerBus.instance.attach(this);
    if (Platform.isWindows) _initSmtc();
    // 播放页的首次打开都源于用户动作（详情页点「第 N 集」/继续播放/立即播放）：
    // 立刻把「想去这一集」写进历史，否则起播慢/失败时退出，历史还停在旧集。
    // 页内的自动连播/换线不经这里，语义不变。
    _openEpisode(_index, widget.startAt, manual: true);
  }

  // ---------- Windows 系统媒体控制（SMTC）：媒体键 + 音量浮层 ----------

  /// 每秒最多同步一次时间轴，避免高频调用系统接口。
  void _syncSmtcTimeline() {
    if (!Platform.isWindows) return;
    final second = _position.inSeconds;
    if (second == _lastSmtcSecond) return;
    _lastSmtcSecond = second;
    try {
      _smtc?.updateTimeline(PlaybackTimeline(
        startTimeMs: 0,
        endTimeMs: _duration.inMilliseconds,
        positionMs: _position.inMilliseconds,
        minSeekTimeMs: 0,
        maxSeekTimeMs: _duration.inMilliseconds,
      ));
    } catch (_) {}
  }

  /// 初始化系统媒体控制：键盘媒体键、蓝牙耳机、音量浮层都能看到并控制播放。
  /// 失败（如系统不支持）只静默放弃，不影响播放本身。
  Future<void> _initSmtc() async {
    try {
      await SMTCWindows.initialize();
      _smtc = SMTCWindows(
        config: const SMTCConfig(
          fastForwardEnabled: true,
          nextEnabled: true,
          pauseEnabled: true,
          playEnabled: true,
          rewindEnabled: true,
          prevEnabled: true,
          stopEnabled: false,
        ),
        metadata: MusicMetadata(
          title: widget.series.title,
          album: '阿圈短剧',
          thumbnail: widget.series.coverUrl,
        ),
      );
      _smtcSub = _smtc!.buttonPressStream.listen((event) {
        if (!mounted || _disposed) return;
        switch (event) {
          case PressedButton.play:
            _engine.play();
          case PressedButton.pause:
            _engine.pause();
          case PressedButton.next:
            _goNext(manual: true);
          case PressedButton.previous:
            _goPrev(manual: true);
          case PressedButton.fastForward:
            _engine.seek(_position + const Duration(seconds: 10));
          case PressedButton.rewind:
            _engine.seek(_position - const Duration(seconds: 10));
          default:
            break;
        }
      });
      _smtc!.setPlaybackStatus(PlaybackStatus.playing);
    } catch (_) {
      _smtc = null;
    }
  }

  /// 分集切换后同步系统媒体浮层的标题。
  void _updateSmtcMetadata() {
    if (!Platform.isWindows || _smtc == null) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    try {
      _smtc?.updateMetadata(MusicMetadata(
        title: '${widget.series.title} · 第${ep.number}集',
        album: '阿圈短剧',
        thumbnail: widget.series.coverUrl,
      ));
    } catch (_) {}
  }

  /// mpv 全局参数：解密、协议白名单、硬件解码、缓冲、音画同步、画面比例。
  Future<void> _installMpvOptions() async {
    final settings = AppScope.read(context).settings;
    await _engine.setProperty('network-timeout', '20');
    await _engine.setProperty('cache', 'yes');
    await _engine.setProperty('demuxer-max-bytes', '64MiB');
    await _engine.setProperty('force-seekable', 'yes');
    // Android 走 mediacodec；其余平台用用户选择的硬解方式（白名单已校验）。
    final hwdec = Platform.isAndroid
        ? (settings.hwdecMode == 'no' ? 'no' : 'mediacodec')
        : settings.hwdecMode;
    await _engine.setProperty('hwdec', hwdec);
    await _engine.setProperty('cache-secs', '${settings.cacheSecs}');
    await _engine.setProperty(
        'audio-delay', (settings.audioDelayMs / 1000).toStringAsFixed(3));
    await _engine.setProperty(
      'video-aspect-override',
      switch (settings.scale) {
        '16:9' => '16:9',
        '4:3' => '4:3',
        _ => '-1',
      },
    );
    // 填充 = 保持比例放大并裁掉溢出部分（panscan）。
    await _engine.setProperty(
        'panscan', settings.scale == 'fill' ? '1.0' : '0');
    // 字幕样式。
    await _engine.setProperty(
        'sub-font-size', '${settings.subtitleFontSize}');
    await _engine.setProperty(
        'sub-border-size', settings.subtitleBorder ? '3' : '0');
    await _engine.setProperty('sub-back-color',
        settings.subtitleBackground ? '#80000000' : '#00000000');
    // 字幕时差按剧记忆（每次开播注入，换剧即切换）。
    await _engine.setProperty('sub-delay', '$_subDelay');
  }


  @override
  void dispose() {
    if (castController.onRemoteStopped != null) {
      castController.onRemoteStopped = null;
    }
    unawaited(_stopRelayIfAny());
    PlayerBus.instance.detach(this);
    // 记住本次音量，下次启动恢复。
    try {
      AppScope.read(context).settings.volume = _engine.state.volume;
    } catch (_) {}
    if (!_episodeEnded) _recordHistory(finished: false);
    _sleepTimer?.cancel();
    _hideTimer?.cancel();
    _fallbackTimer?.cancel();
    _nextPromptTimer?.cancel();
    _osdTimer?.cancel();
    _mutedHintTimer?.cancel();
    _tracksSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _completedSub?.cancel();
    _playingSub?.cancel();
    _errorSub?.cancel();
    _logSub?.cancel();
    _bufferingSub?.cancel();
    _bufferTimer?.cancel();
    _smtcSub?.cancel();
    try {
      _smtc?.dispose();
    } catch (_) {}
    _smtc = null;
    _engine.dispose();
    _disposed = true;
    // 全屏/置顶残留会把主窗口卡在全屏态：退播放页时还原（含自建全屏的
    // 标题栏与 bounds 恢复）。
    if (_isDesktop) {
      unawaited(() async {
        try {
          if (await windowManager.isFullScreen()) {
            await _applyFullscreen(false);
          }
        } catch (_) {}
      }());
    }
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _orientationUnlockTimer?.cancel();
    _restoreOrientation();
    super.dispose();
  }

  void _restoreOrientation() {
    if (_isDesktop) return;
    // 退出播放器后交还给系统，首页可自由旋转。
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  /// 进页首次摆正：**一律先竖屏**（含横屏电影），随后按模式放开给传感器。
  ///
  /// 换集不再强制竖屏，也不重置用户的手动锁定——横屏看剧换集被掰回竖屏很难受。
  void _applyOrientation() {
    if (_isDesktop) return;
    if (_orientationReady) {
      if (_orientMode == _OrientationMode.auto) _applyAutoOrientation();
      return;
    }
    _orientationReady = true;
    _portraitOnly();
    if (_orientMode != _OrientationMode.auto) return;
    // 立刻竖屏 → 400ms 后放开三方向：既满足「进页竖屏」，又让物理旋转能生效。
    // 锁定方向后 MediaQuery 不再变化，跟随传感器只能交给系统按
    // preferredOrientations 处理（在 build 里判断会形成锁定循环）。
    _orientationUnlockTimer?.cancel();
    _orientationUnlockTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted || _orientMode != _OrientationMode.auto) return;
      _applyAutoOrientation();
    });
  }

  void _portraitOnly() {
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  void _applyAutoOrientation() {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _applyLockedOrientation() {
    if (_lockedLandscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _portraitOnly();
    }
  }

  /// 「横屏/竖屏」按钮：自动 ⇄ 锁定；锁定方向取当前姿态的反方向。
  void _toggleOrientation() {
    if (_isDesktop) return;
    final isLandscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    _orientationUnlockTimer?.cancel();
    setState(() {
      if (_orientMode == _OrientationMode.auto) {
        _orientMode = _OrientationMode.locked;
        _lockedLandscape = !isLandscape;
      } else {
        _orientMode = _OrientationMode.auto;
      }
    });
    if (_orientMode == _OrientationMode.locked) {
      _applyLockedOrientation();
    } else {
      _applyAutoOrientation();
    }
  }

  /// 桌面端首次打开视频时，把窗口调成和片源一致的比例（参考「自动摆正」）。
  Future<void> _maybeFitWindow(VideoStream stream, Episode episode) async {
    if (!_isDesktop || _fittedWindow) return;
    _fittedWindow = true;
    final settings = AppScope.read(context).settings;
    if (!settings.autoFitWindow) return;
    await _fitWindowToStream(stream, episode);
  }

  Future<void> _fitWindowToStream(VideoStream stream, Episode episode) async {
    if (!_isDesktop) return;
    try {
      if (_mini ||
          await windowManager.isFullScreen() ||
          await windowManager.isMaximized()) {
        return;
      }
      final double aspect;
      if (stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        aspect = episode.vertical ? 9 / 16 : 16 / 9;
      }
      final bounds = await windowManager.getBounds();
      var height = bounds.height;
      if (height < 500) height = 760;
      var width = height * aspect;
      width = width.clamp(380.0, 1600.0);
      await windowManager.setBounds(Rect.fromLTWH(
        bounds.center.dx - width / 2,
        bounds.top,
        width,
        height,
      ));
    } catch (_) {}
  }

  /// 自建全屏：window_manager 0.5.2 的 Windows setFullScreen 只剥
  /// THICKFRAME/MAXIMIZEBOX 而保留 WS_CAPTION（标题栏还在）且盖不住任务栏——
  /// 用户实测「全屏后仍有状态栏」。这里显式：隐标题栏 + 窗口铺满显示器 + 原生
  /// 标记同步；退出时按序还原。
  Rect? _preFullscreenBounds;

  Future<void> _applyFullscreen(bool on) async {
    if (on) {
      _preFullscreenBounds = await windowManager.getBounds();
      await windowManager.setMinimumSize(const Size(0, 0));
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      try {
        // screen_retriever 的坐标是逻辑像素，与 windowManager.setBounds 同一
        // 体系；visiblePosition 是该屏工作区原点（多显示器下的偏移）。
        final display = await sr.screenRetriever.getPrimaryDisplay();
        final origin = display.visiblePosition ?? Offset.zero;
        await windowManager.setBounds(Rect.fromLTWH(
          origin.dx,
          origin.dy,
          display.size.width,
          display.size.height,
        ));
      } catch (e, stack) {
        ErrorLog.instance.record('全屏', '取显示器尺寸失败：$e', stack);
      }
      await windowManager.setFullScreen(true);
    } else {
      await windowManager.setFullScreen(false);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(const Size(380, 480));
      final restore = _preFullscreenBounds;
      if (restore != null) await windowManager.setBounds(restore);
    }
  }

  Future<void> _toggleFullscreen() async {
    if (!_isDesktop) return;
    try {
      if (_mini) await _toggleMiniWindow();
      final full = await windowManager.isFullScreen();
      final target = !full;
      await _applyFullscreen(target);
      // setFullScreen 是异步系统调用，执行完立即回读真实状态；
      // 与目标不符（用户报过「全屏后仍有标题栏」）留痕进错误日志。
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final actual = await windowManager.isFullScreen();
      if (actual != target) {
        ErrorLog.instance.record(
          '全屏',
          'setFullScreen($target) 后回读 isFullScreen=$actual，与预期不符',
        );
      }
    } catch (e, stack) {
      ErrorLog.instance.record('全屏', e, stack);
    }
  }

  /// 迷你置顶小窗：缩成小尺寸 + 窗口置顶，边干活边看；再按一次还原。
  /// 竖屏剧竖着缩（宽 380），横屏剧横着缩。
  Future<void> _toggleMiniWindow() async {
    if (!_isDesktop) return;
    try {
      final settings = AppScope.read(context).settings;
      if (_mini) {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(const Size(380, 480));
        final restore = _preMiniBounds;
        if (restore != null) {
          await windowManager.setBounds(restore);
        } else {
          await windowManager.center();
        }
        settings.miniWindowActive = false;
        if (mounted) setState(() => _mini = false);
        return;
      }
      final bounds = await windowManager.getBounds();
      _preMiniBounds = bounds;
      final stream = _playback != null
          ? _currentStream(_playback!.playback)
          : null;
      final double aspect;
      if (stream != null && stream.width > 0 && stream.height > 0) {
        aspect = stream.width / stream.height;
      } else {
        aspect = widget.episodes[_index.clamp(0, widget.episodes.length - 1)]
                .vertical
            ? 9 / 16
            : 16 / 9;
      }
      const width = 380.0;
      final height = (width / aspect).clamp(160.0, 780.0);
      await windowManager.setMinimumSize(const Size(240, 160));
      await windowManager.setBounds(
          Rect.fromLTWH(bounds.left, bounds.top, width, height));
      await windowManager.setAlwaysOnTop(true);
      settings.miniWindowActive = true;
      if (mounted) setState(() => _mini = true);
    } catch (_) {}
  }

  /// 桌面端键盘快捷键：空格暂停、←/→ 快进退 10 秒、↑/↓ 音量、
  /// F 全屏、M 静音、PageUp/PageDown 上下集、Esc 退出全屏/返回。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.space) {
      _engine.playOrPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.keyJ) {
      _engine.seek(_position - const Duration(seconds: 10));
      _showOsd(Icons.fast_rewind_rounded, '快退 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.keyL) {
      _engine.seek(_position + const Duration(seconds: 10));
      _showOsd(Icons.fast_forward_rounded, '快进 10 秒');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      final v = (_engine.state.volume + 5).clamp(0.0, 100.0);
      _engine.setVolume(v);
      _showOsd(Icons.volume_up_rounded, '音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      final v = (_engine.state.volume - 5).clamp(0.0, 100.0);
      _engine.setVolume(v);
      _showOsd(Icons.volume_down_rounded, '音量 ${v.round()}%');
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyI) {
      _toggleMiniWindow();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyM) {
      _muted = !_muted;
      _engine.setVolume(_muted ? 0 : 100);
      _showOsd(
        _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
        _muted ? '已静音' : '取消静音',
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyC) {
      _applySpeed(_speed + 0.25);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyX) {
      _applySpeed(_speed - 0.25);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyZ) {
      _applySpeed(1.0);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.keyE) {
      _openEpisodePicker();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f1) {
      _showShortcutHelp();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageDown) {
      _goNext(manual: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.pageUp) {
      _goPrev(manual: true);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (_isDesktop) {
        windowManager.isFullScreen().then((full) {
          if (full) windowManager.setFullScreen(false);
        });
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  /// 每集起播前重置判定器并开始 1s 采样。
  void _startBufferMonitor() {
    _bufferTimer?.cancel();
    _bufferTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_disposed) return;
      final verdict = _bufferMonitor.tick();
      if (verdict == null) return;
      unawaited(_recordPlaybackHealth(PlaybackHealthEvent.slowBuffer));
      if (_candidates.isNotEmpty) {
        // 有备选线路就直接换，别让用户盯着缓冲圈手动操作；预算耗尽后只提示。
        if (_recoveryBudget.exhausted) {
          if (mounted) _showToast(verdict.message);
          return;
        }
        final label = _candidates.first.label;
        _showOsd(Icons.swap_horiz_rounded, '画面卡顿，换到「$label」…');
        unawaited(_attemptFallback());
        return;
      }
      if (mounted) _showToast(verdict.message);
    });
  }

  /// 记录「源/影片/集/线路」的健康度；失败静默（不能因为统计挂掉播放）。
  ///
  /// 线路下标用「已尝试地址数 - 1」：第 0 条是原始线路，每次换线 +1。
  /// 不区分线路的话，同一集换三条线的记录会全写在一个键上，换线排序就没数据。
  Future<void> _recordPlaybackHealth(PlaybackHealthEvent event) async {
    try {
      final key = PlaybackHealthRegistry.keyOf(
        sourceKey: '',
        seriesId: widget.series.id,
        episode: _index,
        line: (_triedUrls.length - 1).clamp(0, 99),
      );
      await AppScope.read(context).playbackHealth.record(key, event);
    } catch (_) {}
  }

  /// 应用按剧轨道偏好（stream.tracks 驱动，每集一次）。
  ///
  /// 等待轨道就绪：偏好存在但对应列表还空 → 不置标记，等下一次事件。
  void _applyTrackPreference() {
    if (_trackPrefApplied || _disposed || !mounted) return;
    final tracks = _engine.state.tracks;
    final audio =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final subs =
        tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (_prefAudioIndex == null &&
        _prefSubtitleIndex == null &&
        (_prefAudioKey ?? '').isEmpty &&
        (_prefSubtitleKey ?? '').isEmpty) {
      _trackPrefApplied = true;
      return;
    }
    if (audio.isEmpty && subs.isEmpty) return; // 轨道事件未到
    _trackPrefApplied = true;
    final audioTarget = _resolveTrackTarget(
        _prefAudioIndex, _prefAudioKey, audio, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    final subTarget = _resolveTrackTarget(
        _prefSubtitleIndex, _prefSubtitleKey, subs, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    if (audioTarget != null) {
      unawaited(_engine.setAudioTrack(audio[audioTarget]));
    }
    if (_prefSubtitleIndex == TrackPreference.subtitleOff) {
      unawaited(_engine.setSubtitleTrack(SubtitleTrack.no()));
    } else if (subTarget != null) {
      unawaited(_engine.setSubtitleTrack(subs[subTarget]));
    }
  }

  /// 轨道目标解析（Pathfin 语义）：稳定身份键**唯一命中**优先——命中多条
  /// 宁可保持默认（不错配语言）；键缺失/失配时序号在界内兜底。
  static int? _resolveTrackTarget(
    int? index,
    String? key,
    List<dynamic> tracks,
    String? Function(dynamic track) keyOf,
  ) {
    final keys = [for (final t in tracks) keyOf(t)];
    if (key != null && key.isNotEmpty) {
      final unique = TrackPreference.uniqueMatchIndex(key, keys);
      if (unique != null) return unique;
    }
    if (index != null && index >= 0 && index < tracks.length) return index;
    return null;
  }

  Future<void> _openEpisode(
    int index,
    Duration startAt, {
    bool manual = false,
  }) async {
    _bufferMonitor.reset();
    _bufferMonitor.onOpen();
    _startBufferMonitor();
    final epoch = ++_openEpoch;
    final ep = widget.episodes[index];
    final scope = AppScope.read(context);
    // 用户显式选集：立刻把「想去第 N 集」写进历史。原先只有起播成功且播过
    // 5 秒才落盘，点开失败/秒退就退出的话历史还停在旧集（用户的断点意图丢了）。
    // 自动连播不提前记：起播失败不该挪断点，播起来后节流器照常写。
    if (manual) {
      _position = startAt;
      await _recordHistory(
        finished: false,
        force: true,
        episodeIndex: index,
      );
      if (_disposed || epoch != _openEpoch) return;
    }
    _playSkip = scope.playSkip.entryFor(widget.series.id);
    _endingHandled = false;
    _nextPromptConsumed.clear();
    _cancelNextPromptTimer();
    _nextPromptVisible = false;
    _openingNoticePending = false;
    _playbackFailure = null;
    _rawPlaybackError = null;
    _reResolved = false;
    _reResolving = false;
    _recoveryBudget.attempts = 0;
    _trackPrefApplied = false;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    var effectiveStart = startAt;
    if (startAt == Duration.zero &&
        scope.settings.skipIntroOutro &&
        (_playSkip?.openingMs ?? 0) > 0) {
      effectiveStart = Duration(milliseconds: _playSkip!.openingMs);
      _openingNoticePending = true;
    }
    // 换集先停掉上一集，避免旧位置事件在解析期间写进新一集的进度。
    await _engine.stop();
    if (_disposed || epoch != _openEpoch) return;
    _episodeEnded = false;
    setState(() {
      _position = Duration.zero;
      _duration = Duration.zero;
      _loadingStream = true;
      _loadError = null;
      _playback = null;
      _selectedDefinition = null;
      _definitions = const [];
    });
    await _installMpvOptions();
    // 已缓存的集直接播本地文件（带密钥解密），不发起任何网络请求。
    final local = scope.downloads.localEntryOf(ep.id);
    if (local != null) {
      if (_disposed || epoch != _openEpoch) return;
      setState(() {
        _playback = null;
        _definitions = local.keyHex.isEmpty ? const [] : const ['本地'];
        _selectedDefinition = local.keyHex.isEmpty ? null : '本地';
        _loadingStream = false;
        _index = index;
      });
      await _playLocal(local, effectiveStart);
      if (_disposed || epoch != _openEpoch) return;
      _applyOrientation();
      _updateSmtcMetadata();
      _recordHistory(finished: false);
      _showOpeningNoticeIfNeeded();
      return;
    }
    try {
      final api = scope.api;
      final quality = _quality;
      // 连播预解析命中直接用（过期则重新解析），换集零等待。
      final cached = _prefetched.remove(index);
      final pb = cached != null && prefetchUsable(cached, DateTime.now())
          ? cached
          : await api.resolvePlayback(ep.id);
      if (_disposed || epoch != _openEpoch) return;
      if (pb.playback.streams.isEmpty) {
        throw AquaException(
            code: AquaCode.contentUnavailable,
            message: '没有可用播放流',
            retryable: false);
      }
      final stream = _selectStream(pb.playback, quality);
      setState(() {
        _playback = pb;
        _definitions = _definitionLabels(pb.playback);
        _selectedDefinition = _definitionLabel(stream);
        _loadingStream = false;
        _index = index;
      });
      await _playStream(stream, effectiveStart);
      if (_disposed || epoch != _openEpoch) return;
      _applyOrientation();
      await _maybeFitWindow(stream, ep);
      _updateSmtcMetadata();
      _recordHistory(finished: false);
      _showOpeningNoticeIfNeeded();
    } catch (e) {
      if (_disposed || epoch != _openEpoch) return;
      setState(() {
        _loadError = e;
        _loadingStream = false;
      });
    }
  }

  /// 与 SDK Playback.Select 相同语义的选流：best/worst/具体清晰度标签。
  VideoStream _selectStream(Playback pb, String quality) {
    final usable =
        pb.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw AquaException(
          code: AquaCode.contentUnavailable,
          message: '没有可用播放流',
          retryable: false);
    }
    int rank(VideoStream s) {
      if (s.height > 0) return s.height;
      final digits = RegExp(r'^(\d+)').firstMatch(s.definition)?.group(1);
      return digits == null ? 0 : int.parse(digits);
    }

    usable.sort((a, b) {
      final ra = rank(a);
      final rb = rank(b);
      if (ra != rb) return ra.compareTo(rb);
      return a.bitrate.compareTo(b.bitrate);
    });
    switch (quality) {
      case 'worst':
        return usable.first;
      case '':
      case 'best':
        return usable.last;
      default:
        return usable.lastWhere(
          (s) =>
              s.definition == quality ||
              s.quality == quality ||
              s.codec == quality,
          orElse: () => usable.last,
        );
    }
  }

  List<String> _definitionLabels(Playback pb) {
    final set = <String>{};
    for (final s in pb.streams) {
      if (s.url.isEmpty) continue;
      set.add(_definitionLabel(s));
    }
    return set.toList();
  }

  String _definitionLabel(VideoStream s) =>
      s.definition.isNotEmpty ? s.definition : (s.quality.isEmpty ? '默认' : s.quality);

  VideoStream _currentStream(Playback pb) {
    final label = _selectedDefinition;
    if (label != null) {
      for (final stream in pb.streams) {
        if (stream.url.isNotEmpty && _definitionLabel(stream) == label) {
          return stream;
        }
      }
    }
    return pb.streams.firstWhere((s) => s.url.isNotEmpty,
        orElse: () => pb.streams.first);
  }

  Future<void> _playStream(VideoStream stream, Duration startAt) async {
    final epoch = _openEpoch;
    _currentVideoStream = stream;
    _playbackFailure = null;
    _rawPlaybackError = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    _attemptStart = startAt;
    _playEpoch++;
    _triedUrls
      ..clear()
      ..add(stream.url.trim());
    final pb = _playback;
    _candidates = pb == null
        ? const []
        : planPlaybackCandidates(
            streams: pb.playback.streams,
            current: stream,
            tried: _triedUrls,
          );
    _logBuffer.clear();
    await _prepareLavf();
    await _engine.setRate(_speed);
    await _engine.open(Media(stream.url), play: true);
    if (startAt > Duration.zero) {
      await _engine.seek(startAt);
    }
    if (!mounted || _disposed || epoch != _openEpoch) return;
    setState(() => _prepared = true);
    _historyThrottle.reset(
      baseline: startAt,
      floor: startAt > Duration.zero
          ? startAt - const Duration(seconds: 1)
          : null,
    );
    _prefetchNext(_index);
    _maybeShowMutedHint();
  }

  /// 写入 mpv 的 demuxer-lavf-o（解密、协议白名单、分片重试）。
  Future<void> _prepareLavf() async {
    final key = _playback?.contentKey?.key ?? '';
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
      if (key.isNotEmpty) 'decryption_key=$key',
    ].join(',');
    await _engine.setProperty('demuxer-lavf-o', lavf);
  }

  /// 换线 / 重试时打开一个新地址（沿用当前播放模型与解密密钥）。
  Future<void> _openUrl(String url, Duration startAt) async {
    await _prepareLavf();
    await _engine.setRate(_speed);
    await _engine.open(Media(url), play: true);
    if (startAt > Duration.zero) {
      await _engine.seek(startAt);
    }
    if (!mounted || _disposed) return;
    setState(() => _prepared = true);
  }

  /// 当前集开播后预解析下一集；静默失败（离线/限流都不影响当前播放）。
  void _prefetchNext(int index) {
    final next = index + 1;
    if (next >= widget.episodes.length) return;
    if (_prefetched.containsKey(next)) return;
    final ep = widget.episodes[next];
    if (!ep.playable) return;
    AppScope.read(context).api.resolvePlayback(ep.id).then((pb) {
      if (_disposed) return;
      _prefetched[next] = pb;
    }, onError: (_) {});
  }

  /// 播放位置事件：UI、SMTC、换线取消、历史节流、片尾跳过统一入口。
  void _onPosition(Duration position) {
    if (!mounted) return;
    final previous = _position;
    // 两次采样之间的大跳变只可能来自 seek（3 倍速下每次采样也只前进约 3 秒）。
    // 缓冲监控要靠这个信号启用 seek 宽限，否则正常跳转会被判成慢缓冲并换线。
    final delta = position - previous;
    if (delta > _seekJumpThreshold || delta < -_seekJumpThreshold) {
      _bufferMonitor.onSeek();
    }
    setState(() => _position = position);
    _syncSmtcTimeline();
    // 错误后位置确实前进（≥1 秒）：说明还能播，取消本次换线。
    if (_fallbackTimer != null &&
        position >= _attemptStart + const Duration(seconds: 1)) {
      _fallbackTimer?.cancel();
      _fallbackTimer = null;
    }
    if (_historyThrottle.shouldWrite(position)) {
      _flushHistory();
    }
    _maybeSkipEnding(previous, position);
    _maybeUpdateNextPrompt(position);
  }

  /// 播放器报错：按错误类型分级 + 多候选自动换线。
  ///
  /// - 永久性错误（域名解析失败 / HTTP 4xx-5xx / 格式不支持）立即换线；
  /// - 瞬时错误保留 2 秒防抖，期间位置前进就取消；
  /// - 已播放超过 15 秒的晚期错误不自动换线，避免打断正常观看；
  /// - 候选耗尽后进错误面板（含诊断复制）。
  Future<void> _onPlaybackError(String error) async {
    if (_disposed) return;
    _bufferMonitor.onError();
    unawaited(_recordPlaybackHealth(PlaybackHealthEvent.failed));
    _rawPlaybackError = error;
    _logBuffer.add('[error] $error');
    final failure = classifyPlaybackFailure(error);
    final action = decideRecovery(
      kind: failure.kind,
      playedAheadOfAttempt: _position >= _attemptStart + _earlyWindow,
      hasCandidates: _candidates.isNotEmpty,
      budgetExhausted: _recoveryBudget.exhausted,
    );
    if (action == RecoveryAction.none) {
      // 晚期错误：不自动换线；先给 OSD 提示，若播放确实停了再给错误面板。
      _showOsd(Icons.error_outline_rounded, '播放出错，可在菜单重试');
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () {
        if (_disposed || !mounted) return;
        if (!_engine.state.playing &&
            _rawPlaybackError == error &&
            _playbackFailure == null) {
          setState(() => _playbackFailure = failure);
        }
      }));
      return;
    }
    if (action == RecoveryAction.finalize) {
      unawaited(_finalizeFailure());
      return;
    }
    if (action == RecoveryAction.immediateFallback) {
      unawaited(_attemptFallback());
      return;
    }
    _fallbackTimer ??= Timer(const Duration(seconds: 2), () {
      if (!_disposed) _attemptFallback();
    });
  }

  /// 依次尝试候选线路。每次只打开下一条；若它继续报错，错误事件会再驱动
  /// 下一轮尝试（[_triedUrls] 保证不回头）。
  Future<void> _attemptFallback() async {
    if (_disposed || _fallbackInFlight) return;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    final candidates = List<PlaybackCandidate>.from(_candidates);
    if (candidates.isEmpty) {
      await _finalizeFailure();
      return;
    }
    _fallbackInFlight = true;
    final epoch = _playEpoch;
    try {
      while (candidates.isNotEmpty) {
        if (_disposed || epoch != _playEpoch) return;
        if (_recoveryBudget.exhausted) break;
        final candidate = candidates.removeAt(0);
        if (_triedUrls.contains(candidate.url)) continue;
        _candidates = List<PlaybackCandidate>.unmodifiable(candidates);
        _triedUrls.add(candidate.url);
        _recoveryBudget.recordAttempt();
        _playbackFailure = null;
        setState(() => _selectedDefinition = streamLabel(candidate.stream));
        _showOsd(Icons.swap_horiz_rounded, '线路不可用，尝试「${candidate.label}」…');
        try {
          await _openUrl(
            candidate.url,
            _position > _attemptStart ? _position : _attemptStart,
          );
          // 换线成功：给新线路记一次成功，把它的健康分拉回来。
          unawaited(_recordPlaybackHealth(PlaybackHealthEvent.success));
          return;
        } catch (e) {
          _rawPlaybackError = '$e';
          _logBuffer.add('[error] $e');
          // 打开直接抛错：继续尝试下一条候选。
        }
      }
      // 预算耗尽但候选未用完：转入过期重解析收尾，不再继续硬切。
      if (_recoveryBudget.exhausted && _candidates.isNotEmpty && mounted) {
        unawaited(_finalizeFailure());
        return;
      }
      if (mounted) {
        setState(() =>
            _playbackFailure = classifyPlaybackFailure(_rawPlaybackError));
      }
    } finally {
      _fallbackInFlight = false;
    }
  }

  /// 候选耗尽：先尝试重新解析一次播放地址（签名 URL 过期 / 换 CDN 场景），
  /// 仍失败才显示错误面板。
  Future<void> _finalizeFailure() async {
    if (_disposed || !mounted || _reResolving) return;
    final epoch = _openEpoch;
    final failure = classifyPlaybackFailure(_rawPlaybackError);
    if (_reResolved) {
      setState(() => _playbackFailure = failure);
      return;
    }
    _reResolving = true;
    try {
      final ok = await _tryReResolve();
      if (!ok &&
          mounted &&
          !_disposed &&
          epoch == _openEpoch) {
        setState(() => _playbackFailure = failure);
      }
    } finally {
      _reResolving = false;
    }
  }

  Future<bool> _tryReResolve() async {
    if (_reResolved || _disposed || _playback == null) return false;
    final epoch = _openEpoch;
    _reResolved = true;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    final quality = _selectedDefinition ?? _quality;
    try {
      _showOsd(Icons.refresh_rounded, '播放地址可能已过期，正在重新解析…');
      final pb = await AppScope.read(context).api.resolvePlayback(ep.id);
      if (_disposed || !mounted || epoch != _openEpoch) return false;
      final stream = _selectStream(pb.playback, quality);
      setState(() {
        _playback = pb;
        _definitions = _definitionLabels(pb.playback);
        _selectedDefinition = _definitionLabel(stream);
      });
      await _playStream(
        stream,
        _position > _attemptStart ? _position : _attemptStart,
      );
      return true;
    } catch (e) {
      _rawPlaybackError = '$e';
      _logBuffer.add('[error] $e');
      return false;
    }
  }

  /// 首次从片头起播且设置了片头偏移：提示「已跳过片头」并给 5 秒撤销。
  void _showOpeningNoticeIfNeeded() {
    if (!_openingNoticePending) return;
    _openingNoticePending = false;
    final skip = _playSkip;
    if (skip == null || skip.openingMs <= 0) return;
    _showOsdWithUndo(
      Icons.skip_next_rounded,
      '已跳过片头 ${_fmtSkipMs(skip.openingMs)}',
      () => _engine.seek(Duration.zero),
    );
  }

  /// 静音起播提醒：同一部剧只提醒一次，提供一键开声。
  ///
  /// 延迟 600ms 再判断：初始化时 setVolume 是异步的，立即读可能误判为静音。
  void _maybeShowMutedHint() {
    if (_disposed) return;
    final url = _currentVideoStream?.url;
    unawaited(Future<void>.delayed(const Duration(milliseconds: 600), () {
      if (_disposed || !mounted || _engine.state.volume > 0) return;
      final key = MutedPlaybackHintRegistry.keyFor(
        title: widget.series.title,
        url: url,
      );
      if (!_mutedHints.shouldHint(key)) return;
      _mutedHintTimer?.cancel();
      setState(() => _mutedHintVisible = true);
      _mutedHintTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _mutedHintVisible = false);
      });
    }));
  }

  /// 片尾跳过：只在「自然播放」越过阈值时触发，用户手动拖到结尾不算。
  void _maybeSkipEnding(Duration previous, Duration current) {
    final skip = _playSkip;
    if (skip == null || _endingHandled || skip.endingMs <= 0) return;
    if (!AppScope.read(context).settings.skipIntroOutro) return;
    if (_duration <= Duration.zero) return;
    final threshold =
        _duration - Duration(milliseconds: skip.endingMs);
    if (threshold <= Duration.zero) return;
    final naturalForward = current > previous &&
        (current - previous) < const Duration(seconds: 5);
    if (!naturalForward || current < threshold) return;
    _endingHandled = true;
    final settings = AppScope.read(context).settings;
    if (settings.autoNext && _index < widget.episodes.length - 1) {
      _episodeEnded = true;
      _recordHistory(finished: true);
      _showOsd(Icons.skip_next_rounded, '已跳过片尾，播放下一集');
      _goNext();
    } else {
      _engine.pause();
      _engine.seek(threshold);
      _showOsd(Icons.skip_next_rounded, '已跳过片尾');
    }
  }

  /// 本集是否走片尾跳过路径（下一集提示条与之互斥）。
  bool get _outroConfigured {
    final settings = AppScope.read(context).settings;
    return settings.skipIntroOutro && (_playSkip?.endingMs ?? 0) > 0;
  }

  /// 下一集提示条：位置事件驱动（出现 / 倒计时 / seek 回退收起）。
  void _maybeUpdateNextPrompt(Duration position) {
    if (_disposed || !mounted || _episodeEnded) return;
    final outro = _outroConfigured;
    if (_nextPromptVisible) {
      final remaining = _duration - position;
      if (remaining <= Duration.zero) return; // 自然播完交给 _onEnded
      if (shouldHideNextPromptOnSeek(
        position: position,
        duration: _duration,
        outroConfigured: outro,
      )) {
        _hideNextPrompt(release: true);
      } else if (!_nextPromptConsumed.contains('next')) {
        setState(() => _nextPromptRemainingMs = remaining.inMilliseconds);
      }
      return;
    }
    final prompt = nextEpisodePrompt(
      position: position,
      duration: _duration,
      hasNext: _index < widget.episodes.length - 1,
      autoNext: AppScope.read(context).settings.autoNext,
      outroConfigured: outro,
      consumed: _nextPromptConsumed,
    );
    if (prompt == null) return;
    setState(() {
      _nextPromptVisible = true;
      _nextPromptRemainingMs = prompt.remainingMs;
    });
    final remaining = Duration(milliseconds: prompt.remainingMs);
    if (prompt.autoAdvance) {
      // 倒计时到点自动切集；用户取消/换集/播完都会先撤销本定时器或被守卫拦下。
      _nextPromptTimer = Timer(remaining, () {
        if (_disposed || !mounted || _episodeEnded) return;
        _nextPromptVisible = false;
        consumePrompt(_nextPromptConsumed);
        _episodeEnded = true;
        _recordHistory(finished: true);
        _goNext();
      });
    } else {
      // 非自动连播：提示条到自然播完自动消失（不暂停，保持现状语义）。
      _nextPromptTimer = Timer(remaining, () {
        if (mounted && !_disposed) _hideNextPrompt();
      });
    }
  }

  void _cancelNextPromptTimer() {
    _nextPromptTimer?.cancel();
    _nextPromptTimer = null;
  }

  void _hideNextPrompt({bool release = false}) {
    _cancelNextPromptTimer();
    if (release) releasePrompt(_nextPromptConsumed);
    _nextPromptVisible = false;
    if (mounted) setState(() {});
  }

  /// 提示条「立即播放」。
  void _confirmNextPrompt() {
    _cancelNextPromptTimer();
    _nextPromptVisible = false;
    consumePrompt(_nextPromptConsumed);
    _episodeEnded = true;
    _recordHistory(finished: true);
    _goNext();
  }

  /// 提示条「取消」：本集不再出现。
  void _dismissNextPrompt() {
    consumePrompt(_nextPromptConsumed);
    _hideNextPrompt();
  }

  Future<void> _flushHistory() async {
    if (_historyWriteInFlight || _disposed || !_prepared || _episodeEnded) {
      return;
    }
    _historyWriteInFlight = true;
    try {
      await _recordHistory(finished: false);
      _historyThrottle.markWritten(_position);
    } finally {
      _historyWriteInFlight = false;
    }
  }

  /// 中央 OSD 提示（音量 / 快进 / 倍速 / 换线等）。
  void _showOsd(IconData icon, String text) {
    if (!mounted) return;
    _osdTimer?.cancel();
    setState(() {
      _osdIcon = icon;
      _osdText = text;
    });
    _osdTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) {
        setState(() {
          _osdIcon = null;
          _osdText = null;
        });
      }
    });
  }

  /// 带「撤销」动作的提示（跳过片头等）。
  void _showOsdWithUndo(IconData icon, String text, VoidCallback onUndo) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(text)),
          ],
        ),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(label: '撤销', onPressed: onUndo),
      ));
  }

  /// 倍速统一入口：限制范围、应用、按剧记忆、OSD。
  Future<void> _applySpeed(double value) async {
    final history = AppScope.read(context).history;
    final v = value.clamp(0.5, 3.0).toDouble();
    setState(() => _speed = v);
    await _engine.setRate(v);
    _showOsd(Icons.speed_rounded, '倍速 ${_trimSpeed(v)}x');
    try {
      await history.setPlaybackPrefs(seriesId: widget.series.id, speed: v);
    } catch (_) {}
  }

  /// 播放本地缓存文件：密钥为空说明未加密，直接播；否则带 decryption_key。
  Future<void> _playLocal(DownloadEntry entry, Duration startAt) async {
    _currentVideoStream = null;
    _playbackFailure = null;
    _rawPlaybackError = null;
    _fallbackTimer?.cancel();
    _fallbackTimer = null;
    _fallbackInFlight = false;
    _candidates = const [];
    _triedUrls.clear();
    _playEpoch++;
    _attemptStart = startAt;
    _logBuffer.clear();
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      'protocol_whitelist=[file,http,https,tcp,tls,crypto,data]',
      if (entry.keyHex.isNotEmpty) 'decryption_key=${entry.keyHex}',
    ].join(',');
    await _engine.setProperty('demuxer-lavf-o', lavf);
    await _engine.setRate(_speed);
    await _engine.open(Media(entry.filePath), play: true);
    if (startAt > Duration.zero) {
      await _engine.seek(startAt);
    }
    if (_disposed) return;
    setState(() => _prepared = true);
    _historyThrottle.reset(
      baseline: startAt,
      floor: startAt > Duration.zero
          ? startAt - const Duration(seconds: 1)
          : null,
    );
    _maybeShowMutedHint();
  }

  Future<void> _switchDefinition(String label) async {
    final pb = _playback;
    if (pb == null) return;
    final stream = pb.playback.streams.firstWhere(
      (s) => s.url.isNotEmpty && _definitionLabel(s) == label,
      orElse: () => pb.playback.streams.first,
    );
    final resumeAt = _position;
    _reResolved = false;
    setState(() {
      _selectedDefinition = label;
      _quality = label;
    });
    // 清晰度按剧记忆，换集与下次打开沿用。
    try {
      await AppScope.read(context)
          .history
          .setPlaybackPrefs(seriesId: widget.series.id, quality: label);
    } catch (_) {}
    await _playStream(stream, resumeAt);
  }

  void _onEnded() {
    if (_episodeEnded || _disposed) return;
    _episodeEnded = true;
    unawaited(_recordPlaybackHealth(PlaybackHealthEvent.success));
    _recordHistory(finished: true);
    if (AppScope.read(context).settings.autoNext) {
      _goNext();
    }
  }

  void _goNext({bool manual = false}) {
    if (_index < widget.episodes.length - 1) {
      _openEpisode(_index + 1, Duration.zero, manual: manual);
    } else {
      _showToast('已经是最后一集了');
    }
  }

  void _goPrev({bool manual = false}) {
    if (_index > 0) {
      _openEpisode(_index - 1, Duration.zero, manual: manual);
    } else {
      _showToast('已经是第一集了');
    }
  }

  /// AI / aquan-cli 的播放控制入口（PlayerHandle）。
  @override
  Map<String, dynamic> control(LaunchCommand command) {
    if (!mounted || _disposed) {
      return {'ok': false, 'playing': false, 'message': '播放器已关闭'};
    }
    final kind = command.kind;
    switch (kind) {
      case 'pause':
        _engine.pause();
        return {'ok': true, 'playing': false};
      case 'resume':
        _engine.play();
        return {'ok': true, 'playing': true};
      case 'toggle':
        _engine.playOrPause();
        return {'ok': true, 'playing': _engine.state.playing};
      case 'next':
        _goNext(manual: true);
        return {'ok': true};
      case 'prev':
        _goPrev(manual: true);
        return {'ok': true};
      case 'status':
        return _statusPayload();
      case 'seek':
        return _controlSeek(command.value);
      case 'volume':
        return _controlVolume(command.value);
      case 'speed':
        return _controlSpeed(command.value);
      case 'quality':
        return _controlQuality(command.value);
      case 'open':
        // 窗口已由命令处理方置顶，这里只回报状态摘要。
        return _statusPayload();
    }
    return {'ok': false, 'error': '未知命令 $kind'};
  }

  /// seek：纯数字按秒（绝对）；`+30`/`-15` 相对当前；也认 `mm:ss` / `hh:mm:ss`。
  Map<String, dynamic> _controlSeek(String value) {
    final target = _parseSeek(value);
    if (target == null) {
      return {'ok': false, 'error': '无法解析进度 "$value"'};
    }
    final text = value.trim();
    final absolute = !text.startsWith('+') && !text.startsWith('-');
    var dest = absolute ? target : _position + target;
    if (dest < Duration.zero) dest = Duration.zero;
    if (_duration > Duration.zero && dest > _duration) dest = _duration;
    _engine.seek(dest);
    _showOsd(Icons.fast_forward_rounded, '跳转 ${_fmtDur(dest)}');
    return {'ok': true, 'position': _fmtDur(dest)};
  }

  Duration? _parseSeek(String raw) {
    final text = raw.trim().replaceFirst(RegExp(r'^\+'), '');
    final negative = text.startsWith('-');
    final body = negative ? text.substring(1) : text;
    // mm:ss / hh:mm:ss
    if (body.contains(':')) {
      var seconds = 0;
      for (final part in body.split(':')) {
        final v = int.tryParse(part.trim());
        if (v == null) return null;
        seconds = seconds * 60 + v;
      }
      return Duration(seconds: negative ? -seconds : seconds);
    }
    final seconds = double.tryParse(body);
    if (seconds == null) return null;
    final d = Duration(milliseconds: (seconds * 1000).round());
    return negative ? -d : d;
  }

  /// volume：`up`/`down` ±10，数字 0-100 绝对设置。
  Map<String, dynamic> _controlVolume(String value) {
    final text = value.trim().toLowerCase();
    double volume;
    switch (text) {
      case 'up':
        volume = (_engine.state.volume + 10).clamp(0.0, 100.0);
      case 'down':
        volume = (_engine.state.volume - 10).clamp(0.0, 100.0);
      default:
        final v = double.tryParse(text);
        if (v == null || v < 0 || v > 100) {
          return {'ok': false, 'error': '音量要在 0-100 之间（或 up/down）'};
        }
        volume = v;
    }
    _muted = false;
    _engine.setVolume(volume);
    _showOsd(Icons.volume_up_rounded, '音量 ${volume.round()}%');
    return {'ok': true, 'volume': volume.round()};
  }

  /// speed：倍速 0.5-3.0，按剧记忆（与播放器菜单同一份偏好）。
  Map<String, dynamic> _controlSpeed(String value) {
    final v = double.tryParse(value.trim().replaceAll('x', ''));
    if (v == null || v < 0.5 || v > 3.0) {
      return {'ok': false, 'error': '倍速支持 0.5-3.0'};
    }
    _applySpeed(v);
    return {'ok': true, 'speed': v};
  }

  static String _trimSpeed(double v) =>
      v == v.roundToDouble() ? v.round().toString() : v.toString();

  /// quality：切换清晰度（如 1080p / 720p / best / worst）。
  /// 未指明的标签按包含匹配当前可选清晰度。
  Map<String, dynamic> _controlQuality(String value) {
    final want = value.trim().toLowerCase();
    final candidates = _definitions.where((d) => d.toLowerCase().contains(want)).toList();
    if (candidates.isEmpty && (want == 'best' || want == 'worst')) {
      final usable = _playback?.playback.streams
              .where((s) => s.url.isNotEmpty)
              .toList() ??
          const <VideoStream>[];
      if (usable.isNotEmpty) {
        final target = _selectStream(_playback!.playback, want);
        final label = _definitionLabel(target);
        final resumeAt = _position;
        _reResolved = false;
        setState(() {
          _selectedDefinition = label;
          // 记住的是「最高/最低」意图，而不是当时命中的具体档位，
          // 片源增加更高清晰度时会自动跟上。
          _quality = want;
        });
        unawaited(_persistQualityAndPlay(want, target, resumeAt));
        return {'ok': true, 'quality': label};
      }
    }
    if (candidates.isEmpty) {
      return {'ok': false, 'error': '没有「$value」清晰度，可选：${_definitions.join(" / ")}'};
    }
    _switchDefinition(candidates.last);
    return {'ok': true, 'quality': candidates.last};
  }

  Future<void> _persistQualityAndPlay(
      String quality, VideoStream target, Duration resumeAt) async {
    try {
      await AppScope.read(context)
          .history
          .setPlaybackPrefs(seriesId: widget.series.id, quality: quality);
    } catch (_) {}
    await _playStream(target, resumeAt);
  }

  Map<String, dynamic> _statusPayload() {
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return {
      'ok': true,
      'playing': _engine.state.playing,
      'series': widget.series.title,
      'episode': ep.number,
      'episode_title': ep.title,
      'position': _fmtDur(_position),
      'duration': _fmtDur(_duration),
      'speed': _speed,
      'quality': _selectedDefinition ?? _quality,
      'mini': _mini,
    };
  }

  /// 桌面快捷键自说明面板（F1）。
  void _showShortcutHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('键盘快捷键'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Shortcut(key_: '空格', action: '暂停 / 播放'),
            _Shortcut(key_: '← / →', action: '快退 / 快进 10 秒'),
            _Shortcut(key_: '↑ / ↓', action: '音量 +5% / -5%'),
            _Shortcut(key_: 'F', action: '全屏切换'),
            _Shortcut(key_: 'M', action: '静音'),
            _Shortcut(key_: 'C / X', action: '倍速 +0.25 / -0.25'),
            _Shortcut(key_: 'Z', action: '恢复 1.0x'),
            _Shortcut(key_: 'E', action: '选集'),
            _Shortcut(key_: 'F1', action: '本帮助'),
            _Shortcut(key_: 'PgUp / PgDn', action: '上一集 / 下一集'),
            _Shortcut(key_: 'Esc', action: '退出全屏'),
          ],
        ),
        actions: [
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 窄屏底栏放不下时，「更多」里的睡眠定时二级选择。
  Future<void> _pickSleepTimer() async {
    const options = <int>[0, 15, 30, 60];
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in options)
              ListTile(
                title: Text(m == 0 ? '不定时' : '$m 分钟后暂停'),
                trailing: _sleepMinutes == m ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, m),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) _setSleepTimer(picked);
  }

  /// 窄屏底栏放不下时，「更多」里的倍速二级选择。
  Future<void> _pickSpeed() async {
    const options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0];
    final picked = await showModalBottomSheet<double>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final v in options)
              ListTile(
                title: Text('${_trimSpeed(v)}x'),
                trailing: _speed == v ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(sheetContext, v),
              ),
          ],
        ),
      ),
    );
    if (picked != null && mounted) await _applySpeed(picked);
  }

  /// 睡眠定时：到点暂停播放；选「关」取消。
  void _setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    if (!mounted) return;
    setState(() => _sleepMinutes = minutes);
    if (minutes <= 0) {
      _showToast('已取消睡眠定时');
      return;
    }
    _sleepTimer = Timer(Duration(minutes: minutes), () {
      if (_disposed) return;
      _engine.pause();
      _showToast('睡眠时间到，已暂停');
      if (mounted) setState(() => _sleepMinutes = 0);
    });
    _showToast('将在 $minutes 分钟后暂停');
  }

  /// 选集抽屉：点任意一集直接换集。
  Future<void> _openEpisodePicker() async {
    if (widget.episodes.isEmpty || _disposed) return;
    final downloads = AppScope.read(context).downloads;
    await showEpisodePicker(
      context,
      title: widget.series.title,
      episodes: widget.episodes,
      currentIndex: _index,
      onSelect: (i) {
        if (_disposed || i == _index) return;
        _openEpisode(i, Duration.zero, manual: true);
      },
      isDownloaded: (ep) => downloads.store.has(ep.id),
      onDownload: () {
        Navigator.of(context).pop();
        showDownloadSheet(
          context,
          series: widget.series,
          episodes: widget.episodes,
        );
      },
    );
  }

  /// 清晰度选择面板：即使源只提供一路，也能看到当前清晰度；
  /// 「最高可用」会忽略按剧记忆切到最高。
  Future<void> _openQualitySheet() async {
    if (_definitions.isEmpty) {
      _showToast('当前源没有提供清晰度信息');
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('清晰度'),
              subtitle: Text(
                  '当前：${_selectedDefinition ?? '最高可用'}；默认清晰度在「我的 → 设置」调整'),
            ),
            for (final definition in _definitions)
              ListTile(
                title: Text(definition),
                trailing: definition == _selectedDefinition
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(sheetContext, definition),
              ),
            if (_playback != null)
              ListTile(
                leading: const Icon(Icons.hd_outlined),
                title: const Text('最高可用'),
                subtitle: const Text('忽略按剧记忆，切到当前源最高清晰度'),
                onTap: () => Navigator.pop(sheetContext, 'best'),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    if (picked == 'best') {
      _controlQuality('best');
    } else {
      _switchDefinition(picked);
    }
  }

  /// 截取当前画面：桌面端保存为 PNG，Android 走系统分享。
  Future<void> _captureScreenshot() async {
    try {
      final bytes = await _engine.screenshot(
        format: 'image/png',
        includeLibassSubtitles: true,
      );
      if (bytes == null) {
        _showToast('截图失败：当前画面不可用');
        return;
      }
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[:.]'), '-');
      final name = 'aquan_$stamp.png';
      if (Platform.isAndroid) {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}${Platform.pathSeparator}$name');
        await file.writeAsBytes(bytes);
        await SharePlus.instance
            .share(ShareParams(files: [XFile(file.path)]));
        return;
      }
      final location = await getSaveLocation(
        suggestedName: name,
        acceptedTypeGroups: const [
          XTypeGroup(label: 'PNG 图片', extensions: ['png'])
        ],
      );
      if (location == null) return;
      await File(location.path).writeAsBytes(bytes);
      _showToast('截图已保存');
    } catch (e) {
      _showToast('截图失败：$e');
    }
  }

  /// 播放信息：分辨率、编码、硬解状态、音轨、缓冲、引擎版本。
  Future<void> _openPlaybackInfo() async {
    String? engineVersion;
    String? hwdec;
    try {
      engineVersion = await _engine.getProperty('mpv-version');
      hwdec = await _engine.getProperty('hwdec-current');
    } catch (_) {}
    if (!mounted) return;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    await showPlayerInfoDialog(
      context,
      PlayerInfoData(
        engine: _engine,
        title: widget.series.title,
        episodeLabel:
            '第${ep.number}集${ep.title.isEmpty ? '' : ' · ${ep.title}'}',
        quality: _selectedDefinition,
        url: _currentVideoStream?.url,
        engineVersion: engineVersion,
        hwdecCurrent: hwdec,
      ),
    );
  }

  /// 片头片尾设置：按时长/当前位置设置，按剧记忆；打开开关后立即生效。
  Future<void> _openSkipSettings() async {
    final scope = AppScope.read(context);
    final current = _playSkip ?? const PlaySkipEntry();
    var enabled = scope.settings.skipIntroOutro;
    var opening = current.openingMs;
    var ending = current.endingMs;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final theme = Theme.of(context);
          return AlertDialog(
            title: const Text('片头片尾'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('启用片头片尾跳过'),
                      subtitle: const Text('按剧记忆，换集沿用'),
                      value: enabled,
                      onChanged: (v) => setDialogState(() => enabled = v),
                    ),
                    const Divider(),
                    Text(opening > 0
                            ? '片头：从开头跳过 ${_fmtSkipMs(opening)}'
                            : '片头：未设置',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final sec in const [15, 30, 45, 60, 90])
                          ChoiceChip(
                            label: Text('$sec 秒'),
                            selected: opening == sec * 1000,
                            onSelected: (_) =>
                                setDialogState(() => opening = sec * 1000),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.my_location, size: 16),
                          label: const Text('设为当前位置'),
                          onPressed: _position.inMilliseconds > 500
                              ? () => setDialogState(
                                  () => opening = _position.inMilliseconds)
                              : null,
                        ),
                        ActionChip(
                          label: const Text('清除'),
                          onPressed: opening > 0
                              ? () => setDialogState(() => opening = 0)
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Divider(),
                    Text(ending > 0
                            ? '片尾：提前 ${_fmtSkipMs(ending)} 结束'
                            : '片尾：未设置',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final sec in const [30, 60, 90, 120])
                          ChoiceChip(
                            label: Text('$sec 秒'),
                            selected: ending == sec * 1000,
                            onSelected: (_) =>
                                setDialogState(() => ending = sec * 1000),
                          ),
                        ActionChip(
                          avatar: const Icon(Icons.last_page, size: 16),
                          label: const Text('从当前位置算起'),
                          onPressed: _duration > const Duration(seconds: 5) &&
                                  _position <
                                      _duration - const Duration(seconds: 3)
                              ? () => setDialogState(() {
                                    final tail = (_duration - _position)
                                        .inMilliseconds
                                        .clamp(3000, 600000);
                                    ending = tail;
                                  })
                              : null,
                        ),
                        ActionChip(
                          label: const Text('清除'),
                          onPressed: ending > 0
                              ? () => setDialogState(() => ending = 0)
                              : null,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '片尾只在自然播放接近末尾时触发；手动拖动进度条不会触发。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  child: const Text('保存')),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    scope.settings.skipIntroOutro = enabled;
    await scope.playSkip.upsert(
      widget.series.id,
      PlaySkipEntry(openingMs: opening, endingMs: ending),
    );
    if (!mounted) return;
    setState(() {
      _playSkip = (opening <= 0 && ending <= 0)
          ? null
          : PlaySkipEntry(openingMs: opening, endingMs: ending);
      _endingHandled = false;
    });
    _showOsd(Icons.content_cut_rounded,
        enabled ? '片头片尾设置已保存' : '已关闭片头片尾跳过');
    if (enabled &&
        opening > 0 &&
        _position < Duration(milliseconds: opening)) {
      await _engine.seek(Duration(milliseconds: opening));
    }
  }

  String _fmtSkipMs(int ms) {
    if (ms <= 0) return '未设置';
    final seconds = (ms / 1000).round();
    if (seconds < 60) return '$seconds 秒';
    final minutes = seconds ~/ 60;
    final rest = seconds % 60;
    return rest == 0 ? '$minutes 分钟' : '$minutes 分 $rest 秒';
  }

  Future<void> _recordHistory({
    required bool finished,
    bool force = false,
    int? episodeIndex,
  }) async {
    if (widget.series.id.isEmpty) return;
    final ep = widget
        .episodes[(episodeIndex ?? _index).clamp(0, widget.episodes.length - 1)];
    final position = finished ? 0.0 : _position.inSeconds.toDouble();
    // 没真正播起来（起播失败 / 秒退 / 缓冲中退出）时不要用 0 覆盖已有断点；
    // 用户显式选集的「意图记录」（force）除外——那一步就是要挪断点。
    if (!finished && position <= 0 && !force) return;
    await _history.record(
      seriesId: widget.series.id,
      title: widget.series.title,
      coverUrl: widget.series.coverUrl,
      episode: ep.number,
      episodes: widget.episodes.length,
      episodeId: ep.id,
      position: position,
      finished: finished,
      speed: _speed,
      // 清晰度只在用户手动切换时持久化（_switchDefinition），
      // 自动选流 / 自动换线不能覆盖「最高」偏好。
      quality: '',
    );
  }

  // ---------- 手势 ----------

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _onHorizontalDragStart(DragStartDetails d) {
    _dragKind = _DragKind.seek;
    _dragStartPos = d.localPosition.dx;
    _seekPreviewMs = _position.inMilliseconds.toDouble();
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_dragKind != _DragKind.seek || _duration == Duration.zero) return;
    final delta = d.localPosition.dx - (_dragStartPos ?? 0);
    final ms = (_seekPreviewMs ?? 0) + delta * 300;
    setState(() {
      _overlayValue = ms.clamp(0.0, _duration.inMilliseconds.toDouble()).toDouble();
    });
  }

  void _onDragEnd(DragEndDetails d) async {
    if (_dragKind == _DragKind.seek) {
      final target = _overlayValue;
      if (target != null) {
        await _engine.seek(Duration(milliseconds: target.floor()));
      }
      setState(() {
        _seekPreviewMs = null;
        _overlayValue = null;
      });
    } else if (_dragKind == _DragKind.brightness) {
      setState(() => _overlayValue = null);
    } else if (_dragKind == _DragKind.volume) {
      setState(() => _overlayValue = null);
    }
    _dragKind = null;
    _dragStartPos = null;
  }

  void _onVerticalDragUpdate(DragUpdateDetails d, bool leftHalf) {
    _dragKind ??= leftHalf ? _DragKind.brightness : _DragKind.volume;
    if (_dragKind == _DragKind.brightness) {
      _dragStartBrightness ??= _lastBrightness;
      final delta = -d.delta.dy / 300;
      final v = ((_dragStartBrightness ?? 0.5) + delta).clamp(0.0, 1.0).toDouble();
      _lastBrightness = v;
      // Linux 等平台没有亮度插件，失败时不打断播放。
      ScreenBrightness().setApplicationScreenBrightness(v).catchError((_) {});
      setState(() => _overlayValue = v);
    } else if (_dragKind == _DragKind.volume) {
      _dragStartVolume ??= _engine.state.volume;
      final delta = -d.delta.dy / 2;
      final v = ((_dragStartVolume ?? 100) + delta).clamp(0.0, 100.0);
      _engine.setVolume(v);
      setState(() => _overlayValue = v);
    }
  }

  // ---------- 投屏（DLNA 发送端） ----------

  void _resumeLocalAfterCast(Duration position) {
    final behavior = AppScope.read(context).settings.castDisconnectBehavior;
    if (behavior != 'resumeLocal') return;
    if (position > Duration.zero) {
      _engine.seek(position);
    }
    _engine.play();
    if (mounted) setState(() {});
  }

  Future<void> _openCastSheet() async {
    final playback = _playback;
    if (playback == null) {
      _showToast('播放地址未就绪');
      return;
    }
    final stream = _currentVideoStream ?? _currentStream(playback.playback);
    if (stream.url.isEmpty) {
      _showToast('没有可投屏的视频流');
      return;
    }
    var castUrl = stream.url;
    // 中继起不来（典型：系统没有可执行的 ffmpeg）时不再把整条投屏路堵死，
    // 改为弹面板并默认勾选「镜像屏幕」——镜像走 MediaProjection，不依赖 ffmpeg。
    var needsMirror = false;
    if (playback.contentKey != null) {
      // M3：加密分集走本机中继（ffmpeg 解密转 HLS）。
      try {
        final relay = await AppScope.read(context).api.castRelayStart(
          url: stream.url,
          backupUrl: stream.backupUrl,
          decKey: playback.contentKey!.key,
          audioUrl: playback.playback.audioUrl,
        );
        _relaySession = relay['session'] as String?;
        castUrl = relay['url'] as String? ?? castUrl;
        _showToast('已启动本机解密中继');
      } on AquaException catch (e) {
        needsMirror = true;
        _showToast('${e.friendlyText}；已切换为镜像屏幕投屏');
      } catch (e) {
        needsMirror = true;
        _showToast('加密中继启动失败，已切换为镜像屏幕投屏');
        ErrorLog.instance.record('投屏', '中继启动失败：$e', StackTrace.current);
      }
    }
    if (!mounted) {
      unawaited(_stopRelayIfAny());
      return;
    }
    final ep = widget.episodes[_index];
    final media = CastMedia(
      url: castUrl,
      title:
          '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
      position: _position,
      episodeIndex: _index + 1,
      episodeCount: widget.episodes.length,
    );
    // 连播：电视端播完自动解析并投下一集（本地缓存集投本地文件；加密分集
    // 停旧中继、起新中继）。scope 在发起时捕获，避免异步后摸 context。
    final castScope = AppScope.read(context);
    final castIndex = _index;
    castController.onNextEpisode = () async {
      final n = castIndex + 1;
      if (n >= widget.episodes.length) return null;
      final nep = widget.episodes[n];
      final local = castScope.downloads.localEntryOf(nep.id);
      if (local != null) {
        return CastMedia(
          url: '',
          localPath: local.filePath,
          title: '${widget.series.title} · ${nep.title.isEmpty ? '第${nep.number}集' : nep.title}',
          episodeIndex: nep.number,
          episodeCount: widget.episodes.length,
        );
      }
      final cached = _prefetched.remove(n);
      final pb = cached != null && prefetchUsable(cached, DateTime.now())
          ? cached
          : await castScope.api.resolvePlayback(nep.id);
      if (pb.playback.streams.isEmpty) return null;
      final stream = _selectStream(pb.playback, _quality);
      var nextUrl = stream.url;
      if (pb.contentKey != null) {
        // 换集：停旧中继 → 起新中继（会话随 provider 闭包管理）。
        final oldSession = _relaySession;
        _relaySession = null;
        if (oldSession != null) {
          try {
            await castScope.api.castRelayStop(oldSession);
          } catch (_) {}
        }
        try {
          final relay = await castScope.api.castRelayStart(
            url: stream.url,
            backupUrl: stream.backupUrl,
            decKey: pb.contentKey!.key,
            audioUrl: pb.playback.audioUrl,
          );
          _relaySession = relay['session'] as String?;
          nextUrl = relay['url'] as String? ?? stream.url;
        } catch (_) {
          return null; // 中继起不来：本轮连播终止，走远端停止路径。
        }
      }
      return CastMedia(
        url: nextUrl,
        title: '${widget.series.title} · ${nep.title.isEmpty ? '第${nep.number}集' : nep.title}',
        episodeIndex: nep.number,
        episodeCount: widget.episodes.length,
      );
    };
    final result = await showCastSheet(
      context,
      media: media,
      onLocalPause: () => _engine.pause(),
      initialMirrorMode: needsMirror,
    );
    if (!mounted || result == null) {
      // 用户取消：中继会话留着会被空闲回收，但立即回收更干净。
      unawaited(_stopRelayIfAny());
      return;
    }
    if (result == 'started') {
      _showToast('已投屏，电视端播放中');
    } else if (result == 'disconnect') {
      final position = await castController.disconnect();
      await _stopRelayIfAny();
      _resumeLocalAfterCast(position);
    }
  }

  /// 回收中继会话（断开/远端停止/退出三条路径）。
  Future<void> _stopRelayIfAny() async {
    final session = _relaySession;
    _relaySession = null;
    if (session == null) return;
    try {
      await AppScope.read(context).api.castRelayStop(session);
    } catch (_) {}
  }

  void _showToast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text), duration: const Duration(milliseconds: 800)));
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              onPointerSignal: (event) {
                if (event is PointerScrollEvent) {
                  // 桌面滚轮调音量：向下滚减小，向上滚增大。
                  final v = (_engine.state.volume +
                          (event.scrollDelta.dy > 0 ? -5 : 5))
                      .clamp(0.0, 100.0);
                  _engine.setVolume(v);
                  _showOsd(Icons.volume_up_rounded, '音量 ${v.round()}%');
                }
              },
              child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTapDown: (d) {
                if (_isDesktop) {
                  _toggleFullscreen();
                  return;
                }
                final half = MediaQuery.sizeOf(context).width / 2;
                if (d.localPosition.dx < half) {
                  _engine.seek(_position - const Duration(seconds: 10));
                  _showOsd(Icons.fast_rewind_rounded, '快退 10 秒');
                } else {
                  _engine.seek(_position + const Duration(seconds: 10));
                  _showOsd(Icons.fast_forward_rounded, '快进 10 秒');
                }
              },
              onHorizontalDragStart: _onHorizontalDragStart,
              onHorizontalDragUpdate: _onHorizontalDragUpdate,
              onHorizontalDragEnd: _onDragEnd,
              onVerticalDragStart: (_) => _dragKind = null,
              onVerticalDragUpdate: (d) =>
                  _onVerticalDragUpdate(d, d.localPosition.dx <
                      MediaQuery.sizeOf(context).width / 2),
              onVerticalDragEnd: _onDragEnd,
              child: _buildVideo(context),
            ),
            ),
            if (_overlayValue != null) _buildGestureOverlay(context),
            if (_loadingStream) _buildPreparingOverlay(context),
            if (_loadError != null) _buildLoadError(context),
            if (_playbackFailure != null) _buildPlaybackErrorPanel(context),
            if (_osdText != null) _buildOsdOverlay(context),
            if (_mutedHintVisible) _buildMutedHint(context),
            if (_nextPromptVisible) _buildNextPromptBar(context),
            if (_buffering &&
                _prepared &&
                !_loadingStream &&
                _playbackFailure == null)
              _buildBufferingBadge(),
            if (_showControls) _buildControls(context),
            // 投屏入口常驻：控件条 4 秒自动隐藏后，顶栏按钮会一起消失。
            if (!_showControls)
              Positioned(
                top: 10,
                right: 10,
                child: CastFabButton(onPressed: _openCastSheet),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideo(BuildContext context) {
    if (!_prepared) {
      return Container(color: Colors.black);
    }
    return Video(
      controller: _engine.videoController,
      controls: NoVideoControls,
      fit: _fill ? BoxFit.cover : BoxFit.contain,
    );
  }

  /// 桌面「铺满」：进全屏（若尚未全屏）+ 画面 cover 裁剪填充；再点切回 contain。
  /// 全屏开关仍归「全屏(F)」按钮管，这里只负责画面填充方式。
  Future<void> _toggleFill() async {
    if (!_isDesktop) return;
    try {
      if (!await windowManager.isFullScreen()) {
        await _applyFullscreen(true);
      }
      if (mounted) setState(() => _fill = !_fill);
    } catch (e, stack) {
      ErrorLog.instance.record('全屏', e, stack);
    }
  }

  Widget _buildLoadError(BuildContext context) {
    final e = _loadError!;
    final text =
        e is AquaException ? e.friendlyText : '加载失败，请稍后再试';
    final detail =
        e is AquaException ? '${e.code}: ${e.message}' : '$e';
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        margin: const EdgeInsets.symmetric(horizontal: 24),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.82),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded,
                color: Colors.white70, size: 34),
            const SizedBox(height: 10),
            Text(text,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 90),
              child: SingleChildScrollView(
                child: SelectableText(detail,
                    style: const TextStyle(
                        color: Colors.white38, fontSize: 12, height: 1.4)),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                OutlinedButton(
                  onPressed: () => _openEpisode(_index, Duration.zero),
                  child: const Text('重试',
                      style: TextStyle(color: Colors.white)),
                ),
                OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('返回',
                      style: TextStyle(color: Colors.white)),
                ),
                TextButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                        ClipboardData(text: '$text\n$detail'));
                    if (mounted) _showToast('错误信息已复制');
                  },
                  icon: const Icon(Icons.copy_rounded,
                      size: 16, color: Colors.white54),
                  label: const Text('复制错误',
                      style: TextStyle(color: Colors.white54)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 起播准备层：封面 + 片名 + 集号立即显示；进度条延迟出现，
  /// 避免解析只用了 80ms 时闪一下。
  Widget _buildPreparingOverlay(BuildContext context) {
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return Container(
      color: Colors.black.withValues(alpha: 0.74),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 320;
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!compact) ...[
                    SizedBox(
                      width: 96,
                      height: 128,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CoverImage(url: widget.series.coverUrl),
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],
                  Text(widget.series.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  Text(
                    '第${ep.number}集${ep.title.isEmpty ? '' : ' · ${ep.title}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54, fontSize: 12),
                  ),
                  const SizedBox(height: 18),
                  const SizedBox(
                    width: 160,
                    child: _DelayedProgressBar(),
                  ),
                  const SizedBox(height: 8),
                  const Text('正在解析播放地址…',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPlaybackErrorPanel(BuildContext context) {
    final failure = _playbackFailure!;
    final ep = widget.episodes[_index.clamp(0, widget.episodes.length - 1)];
    return PlaybackErrorPanel(
      failure: failure,
      rawError: _rawPlaybackError,
      url: _currentVideoStream?.url,
      logs: _logBuffer.entries,
      seriesTitle: widget.series.title,
      episodeNumber: ep.number,
      episodeTitle: ep.title,
      quality: _selectedDefinition,
      onRetry: () => _openEpisode(
        _index,
        _position > const Duration(seconds: 10)
            ? _position
            : Duration.zero,
      ),
      onBack: () => Navigator.pop(context),
    );
  }

  /// 缓冲中提示：网络抖动时给明确反馈，避免用户以为卡死。
  Widget _buildBufferingBadge() {
    return Positioned(
      top: 78,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.58),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
              SizedBox(width: 8),
              Text('缓冲中…',
                  style: TextStyle(color: Colors.white, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  /// 静音起播提示胶囊：不占用 SnackBar，避免盖掉「已跳过片头 · 撤销」。
  Widget _buildMutedHint(BuildContext context) {
    return Positioned(
      right: 20,
      bottom: 100,
      child: Material(
        color: Colors.black.withValues(alpha: 0.74),
        borderRadius: BorderRadius.circular(24),
        child: Padding(
          padding: const EdgeInsets.only(left: 14, right: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.volume_off_rounded,
                  color: Colors.white, size: 18),
              const SizedBox(width: 8),
              const Text('当前静音',
                  style: TextStyle(color: Colors.white, fontSize: 13)),
              TextButton(
                onPressed: () {
                  _mutedHintTimer?.cancel();
                  setState(() => _mutedHintVisible = false);
                  _engine.setVolume(100);
                  _showOsd(Icons.volume_up_rounded, '音量 100%');
                },
                child: const Text('开启声音',
                    style: TextStyle(color: Colors.amberAccent)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 下一集提示条（底部居中；倒计时 + 立即播放 / 取消）。
  Widget _buildNextPromptBar(BuildContext context) {
    final remaining = Duration(milliseconds: _nextPromptRemainingMs);
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final nextNo = (_index + 2).clamp(1, widget.episodes.length);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: IgnorePointer(
        ignoring: false,
        child: Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.74),
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.only(left: 14, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.skip_next_rounded,
                      color: Colors.white, size: 18),
                  const SizedBox(width: 8),
                  Text('即将播放：第 $nextNo 集 · $mm:$ss',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 13)),
                  TextButton(
                    onPressed: _confirmNextPrompt,
                    child: const Text('立即播放',
                        style: TextStyle(color: Colors.amberAccent)),
                  ),
                  TextButton(
                    onPressed: _dismissNextPrompt,
                    child: const Text('取消',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildOsdOverlay(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(24),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_osdIcon != null) ...[
                Icon(_osdIcon, color: Colors.white, size: 20),
                const SizedBox(width: 8),
              ],
              Text(_osdText ?? '',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureOverlay(BuildContext context) {
    final v = _overlayValue!;
    final text = switch (_dragKind) {
      _DragKind.seek =>
        '${_fmtDur(Duration(milliseconds: v.floor()))} / ${_fmtDur(_duration)}',
      _DragKind.brightness => '亮度 ${(v * 100).round()}%',
      _DragKind.volume => '音量 ${v.round()}%',
      null => '',
    };
    return IgnorePointer(
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(24),
          ),
          child: Text(text,
              style: const TextStyle(
                  color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final ep = widget.episodes[_index];
    // 竖屏 360dp 级设备上，底栏固定子项合计约 394dp，会把最右侧「横屏/竖屏」
    // 按钮裁掉一半。窄屏把睡眠定时与倍速收进「更多」菜单（见 player_layout.dart）。
    final compactBar = useCompactPlayerBar(
      desktop: _isDesktop,
      width: MediaQuery.sizeOf(context).width,
    );
    return GestureDetector(
      onTap: _toggleControls,
      child: Container(
        color: Colors.black26,
        child: Column(
          children: [
            // 顶栏
            SafeArea(
              bottom: false,
              child: Row(
                children: [
                  const BackButton(color: Colors.white),
                  Expanded(
                    child: Text(
                      '${widget.series.title} · ${ep.title.isEmpty ? '第${ep.number}集' : ep.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15),
                    ),
                  ),
                  ListenableBuilder(
                    listenable: castController,
                    builder: (context, _) => IconButton(
                      tooltip: '投屏',
                      icon: Icon(castController.isCasting
                          ? Icons.cast_connected
                          : Icons.cast_outlined),
                      color: Colors.white,
                      onPressed: _openCastSheet,
                    ),
                  ),
                  if (_definitions.isNotEmpty)
                    PopupMenuButton<String>(
                      initialValue: _selectedDefinition,
                      color: Colors.grey.shade900,
                      onSelected: _switchDefinition,
                      itemBuilder: (_) => [
                        for (final d in _definitions)
                          PopupMenuItem(
                              value: d,
                              child: Text(d,
                                  style: const TextStyle(
                                      color: Colors.white))),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Text(_selectedDefinition ?? '清晰度',
                            style: const TextStyle(color: Colors.white)),
                      ),
                    ),
                ],
              ),
            ),
            ListenableBuilder(
              listenable: castController,
              builder: (context, _) {
                final device = castController.currentDevice;
                if (!castController.isCasting || device == null) {
                  return const SizedBox.shrink();
                }
                return CastStatusBar(
                  deviceName: device.name,
                  onOpenSession: _openCastSheet,
                );
              },
            ),
            const Spacer(),
            // 底栏
            SafeArea(
              top: false,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Text(_fmtDur(_position),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: _duration == Duration.zero
                                  ? 0
                                  : _position.inMilliseconds
                                      .clamp(0, _duration.inMilliseconds)
                                      .toDouble(),
                              max: _duration.inMilliseconds
                                  .toDouble()
                                  .clamp(1, double.infinity),
                              onChanged: (v) =>
                                  _engine.seek(Duration(milliseconds: v.floor())),
                            ),
                          ),
                        ),
                        Text(_fmtDur(_duration),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12)),
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      IconButton(
                        onPressed: _goPrev,
                        icon: const Icon(Icons.skip_previous,
                            color: Colors.white),
                      ),
                      IconButton(
                        onPressed: () => _engine.playOrPause(),
                        icon: StreamBuilder<bool>(
                          stream: _engine.stream.playing,
                          initialData: true,
                          builder: (_, snap) => Icon(
                            snap.data == true
                                ? Icons.pause_circle_filled
                                : Icons.play_circle_fill,
                            color: Colors.white,
                            size: 36,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: _goNext,
                        icon: const Icon(Icons.skip_next, color: Colors.white),
                      ),
                      // 选集：长剧不用退回详情页翻找。
                      IconButton(
                        tooltip: _isDesktop ? '选集 (E)' : '选集',
                        onPressed: _openEpisodePicker,
                        icon: const Icon(Icons.format_list_numbered,
                            color: Colors.white),
                      ),
                      const Spacer(),
                      // 更多：片头片尾 / 音轨字幕 / 播放信息 / 快捷键。
                      // 收进一个菜单，避免窄屏底栏溢出。
                      PopupMenuButton<String>(
                        tooltip: '更多',
                        color: Colors.grey.shade900,
                        icon: const Icon(Icons.more_horiz, color: Colors.white),
                        onSelected: (value) {
                          switch (value) {
                            case 'skip':
                              _openSkipSettings();
                              break;
                            case 'tracks':
                              showPlayerTracksSheet(context, _engine,
                                initialSubtitleDelay: _subDelay,
                                onAudioTrackSelected: (idx, key) async {
                                  setState(() {
                                    _prefAudioIndex = idx;
                                    _prefAudioKey =
                                        key.isEmpty ? null : key;
                                  });
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      audioTrackIndex: idx,
                                      audioTrackKey: key,
                                    );
                                  } catch (_) {}
                                },
                                onSubtitleTrackSelected: (idx, key) async {
                                  setState(() {
                                    _prefSubtitleIndex = idx;
                                    _prefSubtitleKey =
                                        key.isEmpty ? null : key;
                                  });
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      subtitleTrackIndex: idx,
                                      subtitleTrackKey: key,
                                    );
                                  } catch (_) {}
                                },
                                onSubtitleDelayChanged: (delayMs) async {
                                  setState(
                                      () => _subDelay = delayMs / 1000.0);
                                  try {
                                    await AppScope.read(context)
                                        .history
                                        .setPlaybackPrefs(
                                      seriesId: widget.series.id,
                                      subtitleDelayMs: delayMs.round(),
                                    );
                                  } catch (_) {}
                                });
                              break;
                            case 'quality':
                              _openQualitySheet();
                              break;
                            case 'info':
                              _openPlaybackInfo();
                              break;
                            case 'screenshot':
                              _captureScreenshot();
                              break;
                            case 'sleep':
                              unawaited(_pickSleepTimer());
                              break;
                            case 'speed':
                              unawaited(_pickSpeed());
                              break;
                            case 'help':
                              _showShortcutHelp();
                              break;
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'skip',
                            child: Text('片头片尾',
                                style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: 'tracks',
                            child: Text('音轨 / 字幕',
                                style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: 'quality',
                            child: Text('清晰度',
                                style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: 'info',
                            child: Text('播放信息',
                                style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: 'screenshot',
                            child: Text('截图',
                                style: TextStyle(color: Colors.white)),
                          ),
                          PopupMenuItem(
                            value: 'help',
                            child: Text('快捷键',
                                style: TextStyle(color: Colors.white)),
                          ),
                          if (!compactBar) ...[
                            PopupMenuItem(
                              value: 'sleep',
                              child: Text('睡眠定时',
                                  style: TextStyle(color: Colors.white)),
                            ),
                            PopupMenuItem(
                              value: 'speed',
                              child: Text('播放倍速',
                                  style: TextStyle(color: Colors.white)),
                            ),
                          ],
                        ],
                      ),
                      // 睡眠定时（窄屏收进「更多」）
                      if (!compactBar)
                        PopupMenuButton<int>(
                        tooltip: '睡眠定时',
                        initialValue: _sleepMinutes,
                        color: Colors.grey.shade900,
                        onSelected: _setSleepTimer,
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                              value: 0,
                              child: Text('不定时',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 15,
                              child: Text('15 分钟',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 30,
                              child: Text('30 分钟',
                                  style: TextStyle(color: Colors.white))),
                          PopupMenuItem(
                              value: 60,
                              child: Text('60 分钟',
                                  style: TextStyle(color: Colors.white))),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(
                            _sleepMinutes > 0
                                ? Icons.timer
                                : Icons.timer_outlined,
                            color: _sleepMinutes > 0
                                ? Colors.amberAccent
                                : Colors.white,
                          ),
                        ),
                      ),
                      // 倍速（窄屏收进「更多」）
                      if (!compactBar)
                        PopupMenuButton<double>(
                        initialValue: _speed,
                        color: Colors.grey.shade900,
                        // 倍速按剧记忆，换剧不再重调。
                        onSelected: _applySpeed,
                        itemBuilder: (_) => [
                          for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0])
                            PopupMenuItem(
                                value: v,
                                child: Text('${v}x',
                                    style: const TextStyle(
                                        color: Colors.white))),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Text('${_speed}x',
                              style: const TextStyle(color: Colors.white)),
                        ),
                      ),
                      // 桌面端：窗口调成片源比例；移动端：横竖屏切换。
                      if (_isDesktop)
                        IconButton(
                          tooltip: '适应片源',
                          onPressed: () {
                            final pb = _playback;
                            if (pb == null) return;
                            _fitWindowToStream(
                              _currentStream(pb.playback),
                              widget.episodes[_index],
                            );
                          },
                          icon: const Icon(Icons.aspect_ratio,
                              color: Colors.white),
                        ),
                      // 桌面端：铺满——全屏 + 画面裁剪填充（竖屏剧也能无黑边）。
                      if (_isDesktop)
                        IconButton(
                          tooltip: _fill ? '适应画面' : '铺满全屏',
                          onPressed: _toggleFill,
                          icon: Icon(
                            _fill ? Icons.fit_screen : Icons.crop_free,
                            color: Colors.white,
                          ),
                        ),
                      // 桌面端：迷你置顶小窗（I 键），边干活边看。
                      if (_isDesktop)
                        IconButton(
                          tooltip: _mini ? '还原窗口 (I)' : '迷你置顶 (I)',
                          onPressed: _toggleMiniWindow,
                          icon: Icon(
                              _mini
                                  ? Icons.picture_in_picture_alt
                                  : Icons.picture_in_picture,
                              color: Colors.white),
                        ),
                      IconButton(
                        tooltip: _isDesktop
                            ? '全屏 (F)'
                            : _orientMode == _OrientationMode.locked
                                ? '恢复自动旋转'
                                : MediaQuery.orientationOf(context) ==
                                        Orientation.landscape
                                    ? '锁定竖屏'
                                    : '锁定横屏',
                        onPressed: () {
                          if (_isDesktop) {
                            unawaited(_toggleFullscreen());
                            return;
                          }
                          _toggleOrientation();
                        },
                        icon: Icon(
                            _isDesktop
                                ? Icons.fullscreen
                                : _orientMode == _OrientationMode.locked
                                    ? Icons.screen_lock_rotation
                                    : Icons.screen_rotation,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 播放方向模式：跟随传感器 / 手动锁定。
enum _OrientationMode { auto, locked }

enum _DragKind { seek, brightness, volume }

String _fmtDur(Duration d) {
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  final h = d.inHours;
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}


/// 延迟出现的进度条：解析极快（<120ms）时不闪一下。
class _DelayedProgressBar extends StatefulWidget {
  const _DelayedProgressBar();

  @override
  State<_DelayedProgressBar> createState() => _DelayedProgressBarState();
}

class _DelayedProgressBarState extends State<_DelayedProgressBar> {
  Timer? _timer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(const Duration(milliseconds: 120), () {
      if (mounted) setState(() => _visible = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox(height: 2);
    return const LinearProgressIndicator(minHeight: 2);
  }
}

/// 帮助面板里的一行：按键 + 说明。
class _Shortcut extends StatelessWidget {
  const _Shortcut({required this.key_, required this.action});

  final String key_;
  final String action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(key_,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          Expanded(child: Text(action, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
