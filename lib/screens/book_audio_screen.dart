import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
// media_kit 也有 AudioTrack（音轨选择用），这里用本项目的 AudioTrack。
import 'package:media_kit/media_kit.dart' hide AudioTrack;

import '../core/aqua_error.dart';
import '../core/player/player_engine.dart';
import '../core/reader/reader_listen_settings.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/reader/speech/chapter_gap.dart';
import '../core/reader/speech/chapter_prefetcher.dart';
import '../core/reader/speech/fade_out.dart';
import '../core/reader/speech/listen_bgm.dart';
import '../core/reader/speech/listen_bookmarks.dart';
import '../core/reader/speech/listen_format.dart';
import '../core/reader/speech/listen_media_bridge.dart';
import '../core/reader/speech/listen_media_state.dart';
import '../core/reader/speech/listen_stats.dart';
import '../core/reader/speech/sleep_timer.dart';
import '../core/tts/tts_models.dart';
import '../models/audio.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/reader/follow_pill.dart';
import '../widgets/reader/sleep_sheet.dart';
import 'reader_screen.dart';

/// 听书页 → 阅读页的定位比例（章内 0..1）。
///
/// 音轨只有段级时间点、没有字符坐标：拿时间比例去近似阅读位置是**唯一诚实**的做法。
/// 总时长未知（还没拿到 track）时返回 0，宁可从头开始，也不编一个比例。
double listenRatioOf(Duration position, int totalMs) {
  if (totalMs <= 0) return 0;
  final raw = position.inMilliseconds / totalMs;
  if (raw.isNaN) return 0;
  return raw.clamp(0.0, 1.0).toDouble();
}

/// 播放器时间文案见 `listen_format.dart`（两处 UI 共用）。

/// 相对跳转的目标位置：夹在 `0..totalMs`（`totalMs <= 0` 时只夹下界）。
///
/// 音轨没有句级时间点，所以「上一句/下一句」在音轨路径就是固定步长；
/// 这个函数让 UI 按钮与通知栏命令共用同一套夹取规则。
Duration listenSeekTarget(Duration position, Duration delta, int totalMs) {
  var target = position + delta;
  if (target < Duration.zero) target = Duration.zero;
  if (totalMs > 0 && target.inMilliseconds > totalMs) {
    target = Duration(milliseconds: totalMs);
  }
  return target;
}

/// 听书页：选音色 → 播当前章 → 章节列表。
///
/// 播放走 mpv（与短剧播放器同一内核）：加密音轨把内容密钥交给
/// `demuxer-lavf-o` 的 `decryption_key` 解密。
class BookAudioScreen extends StatefulWidget {
  const BookAudioScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.chapters,
    this.coverUrl = '',
    this.startIndex = 0,
    this.startRatio = 0,
    this.startParagraph = 0,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int startIndex;

  /// 从阅读进度换算的章内比例（0..1）：听书从该位置开始。
  final double startRatio;

  /// 读到的段落下标（用于时间点精确对齐）。
  final int startParagraph;

  @override
  State<BookAudioScreen> createState() => _BookAudioScreenState();
}

class _BookAudioScreenState extends State<BookAudioScreen>
    with WidgetsBindingObserver {
  final PlayerEngine _engine = MpvPlayerEngine();

  AudioTones? _tones;
  AudioTone? _tone;
  AudioStream? _track;
  Object? _error;
  bool _loadingTones = true;
  bool _loadingTrack = false;
  bool _playing = false;

  /// 非番茄书（第三方书源/本地书）：没有官方音轨，改走阅读页朗读。
  bool _notTomatoBook = false;

  /// 语速（番茄的听书语速 = 播放倍速）与自动连播。
  static const _speedKey = 'listen.speed';
  static const _autoNextKey = 'listen.autoNext';
  double _speed = 1.0;
  bool _autoNext = true;
  StreamSubscription<bool>? _doneSub;

  /// 定时与预取接的是与控制器路径**同一对纯组件**（design §1：两条播放路径
  /// 各持实例，但实现只有一份）；持久化共用 `ReaderListenSettings`，本页不
  /// 新建 prefs 键，也不复制任何定时判定逻辑。音轨路径拿不到句边界 →
  /// `sentenceEndMs` 恒 null，到点只能整停（UI 如实注明）。
  final SleepTimer _sleep = SleepTimer(clockMs: _wallClockMs);
  final ChapterPrefetcher _prefetcher = ChapterPrefetcher();

  /// 背景音乐：与阅读页**同一份**组件（两条播放路径各持实例，实现只有一份）。
  final ListenBgm _bgm = ListenBgm();

  /// 听书统计（prefs 就绪后才有）。
  ListenStats? _stats;

  /// 听书书签（prefs 就绪后才有）。
  ListenBookmarks? _bookmarks;
  ReaderListenSettings? _listenSettings;

  /// 剩余时间的重建信号：由播放器位置流推进（每秒一跳）。本页不自建 Timer，
  /// 节拍来自媒体时间轴本身，暂停时位置不前进 → 浮层自然不倒数。
  final ValueNotifier<int> _sleepTick = ValueNotifier<int>(0);
  Duration _lastPos = Duration.zero;

  /// 进度条专用（毫秒）：位置事件本来就密，整页 setState 太重，
  /// 单独一个 ValueNotifier 让只有进度条重建。
  final ValueNotifier<int> _posMs = ValueNotifier<int>(0);

  /// 拖动中的预览位置（毫秒；null = 没在拖）。拖动时**不** setState：
  /// 本页 body 是带章节列表的 ListView，60Hz 重建整页会卡。
  final ValueNotifier<int?> _dragMs = ValueNotifier<int?>(null);

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 听书进度（独立存储，与阅读进度不冲突）。
  StreamSubscription<Duration>? _posSub;
  Timer? _saveTimer;
  Duration _lastSavedPos = Duration.zero;
  int _resumeMs = 0;
  StreamSubscription<String>? _errSub;
  String _playError = '';
  ListenEntry? _record;
  late int _index = widget.startIndex.clamp(0, _maxIndex);

  /// 每次「打开当前章」的请求代号：切章/换音色后旧请求的结果必须丢弃。
  int _playEpoch = 0;

  /// 进入页面时的定位只消费一次；之后切章、换音色都按自然起点播。
  double _startRatio = 0;
  int _startParagraph = 0;

  /// dispose 里不能再查 context：store 引用先缓存。
  late final ListenProgressStore _listening = AppScope.read(context).listening;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  /// 徽标文案：音色表还没拿到就不画（路径未知时不许编一个精度出来）。
  String get _badgeText {
    final tones = _tones;
    if (tones == null) return '';
    return speechBadgeOf(
      tones.hasRecordedAudio ? SpeechPath.recorded : SpeechPath.platformTone,
      SpeechGranularity.paragraph,
    );
  }

  @override
  void initState() {
    super.initState();
    final scope = AppScope.read(context);
    final rec = scope.listening.entry(widget.bookId);
    _record = rec;
    if (rec != null) {
      _index = rec.chapterIndex.clamp(0, _maxIndex);
      _resumeMs = rec.positionMs;
    }
    // 全局朗读会话（阅读页页内听书）可能正在播：本页一旦开始放音轨，
    // 两份声音会叠着响。进本页就接管，先把那边收掉（它会先落盘进度）。
    final speech = scope.speech;
    if (speech.isActive) unawaited(speech.close());
    _startRatio = widget.startRatio;
    _startParagraph = widget.startParagraph;
    WidgetsBinding.instance.addObserver(this);
    _errSub = _engine.stream.error.listen((e) {
      if (!mounted) return;
      setState(() => _playError = e.toString());
    });
    // 固定周期落盘：以前的写法是「每个位置事件重置 5s timer」，
    // 位置事件比 5s 密，等于永远不会保存，进程被杀就丢进度。
    _saveTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _saveProgress());
    _loadPrefs();
    // 位置事件驱动定时与预取：_posSub 此前只声明未订阅，这里补上接线。
    _posSub = _engine.stream.position.listen(_onPosition);
    _doneSub = _engine.stream.completed.listen((done) {
      if (!done) return;
      // 「本章播完停」：先让组件判决（fire 置连播抑制位），再**先消费抑制位**
      // 再决定连播（注意事项 2）；绝不改写 listen.autoNext 的持久化偏好（PRD）。
      if (_sleep.mode == SleepMode.endOfChapter) {
        final decision = _sleep.tick(
          position: _lastPos,
          chapterCompleted: true,
        );
        if (decision.stop) unawaited(_applySleepStop());
      }
      if (_sleep.consumeSleepSuppressAutoNext()) return;
      if (!_autoNext || _index >= _maxIndex) return;
      // 章间呼吸：与控制器同一份工具函数（同一默认档、同一取消语义）。
      final epoch = _playEpoch;
      unawaited(() async {
        final current = await awaitChapterGap(
          _listenSettings?.chapterGapMs ?? kDefaultChapterGapMs,
          isCurrent: () => epoch == _playEpoch && mounted,
        );
        if (!current || !mounted) return;
        if (_index >= _maxIndex) return;
        await _go(1);
      }());
    });
    _loadTones();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _sleepTick.dispose();
    _posMs.dispose();
    _dragMs.dispose();
    unawaited(_bgm.dispose());
    final stats = _stats;
    if (stats != null) unawaited(stats.flush());
    _posSub?.cancel();
    _doneSub?.cancel();
    _errSub?.cancel();
    _saveProgress();
    // 页面即本页听书会话：离页等价于 close()，去重集一起失效（注意事项 5）。
    _prefetcher.invalidate();
    _publishStoppedMedia();
    _engine.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台/被系统回收前立即落盘，不等 5s 周期。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveProgress();
    }
  }

  Future<void> _loadTones() async {
    // 番茄官方音轨只认数字 bookId；第三方书源/本地书的 id 是
    // `booksrc:…` / `local:…`，调用会被 Go 侧判为 INVALID_OPTIONS。
    // 这类书走阅读页的朗读（TTS），不要在这里发请求。
    if (!RegExp(r'^\d+$').hasMatch(widget.bookId.trim())) {
      setState(() {
        _notTomatoBook = true;
        _loadingTones = false;
      });
      return;
    }
    try {
      final tones = await AppScope.read(context).api.audioTones(widget.bookId);
      if (!mounted) return;
      setState(() {
        _tones = tones;
        final saved = _record?.toneId ?? 0;
        final match = tones.tones.where((x) => x.id == saved).toList();
        _tone = match.isNotEmpty
            ? match.first
            : (tones.tones.isEmpty ? null : tones.tones.first);
        _loadingTones = false;
      });
      if (_tone != null) await _playCurrent();
    } catch (e) {
      if (!mounted) return;
      // 第三方书源的书 id 也可能是纯数字，但仍不是番茄的书 → Go 侧返回
      // INVALID_OPTIONS。这种情况当作「没有官方音轨」，给可操作的引导，
      // 而不是甩一个红色错误码给用户。
      if (e.toString().contains('INVALID_OPTIONS') ||
          e.toString().contains('invalid client options')) {
        setState(() {
          _notTomatoBook = true;
          _loadingTones = false;
        });
        return;
      }
      setState(() {
        _error = e;
        _loadingTones = false;
      });
    }
  }

  Future<void> _playCurrent() async {
    final tone = _tone;
    if (tone == null) return;
    final epoch = ++_playEpoch;
    final chapter = widget.chapters[_index];
    setState(() {
      _loadingTrack = true;
      _error = null;
      // 切章也要清上一章的播放错误：否则“新章已经在响”，界面还挂着红字与重试按钮。
      _playError = '';
    });
    try {
      final track = await AppScope.read(context)
          .api
          .audioStream(widget.bookId, chapter.id, tone.id);
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _track = track;
        _loadingTrack = false;
      });
      await _open(track, epoch: epoch);
      if (!mounted || epoch != _playEpoch) return;
      // 段落级对齐：用上游时间点把「读到的段落」换算成毫秒（比按时长等分准）。
      if (_startParagraph > 0 || _startRatio > 0) {
        try {
          final points = await AppScope.read(context)
              .api
              .audioTimepoints(widget.bookId, chapter.id, tone.id);
          if (!mounted || epoch != _playEpoch) return;
          await _waitDuration();
          if (!mounted || epoch != _playEpoch) return;
          final ms = points.offsetMs(
              paragraphIndex: _startParagraph, ratio: _startRatio);
          if (ms > 0) {
            await _engine.seek(Duration(milliseconds: ms));
          }
          // 进入定位只消费一次：切章/换音色不该再跳回同一比例。
          if (epoch == _playEpoch) {
            _startRatio = 0;
            _startParagraph = 0;
          }
        } catch (_) {
          // 时间点取不到就用比例定位。
        }
      }
    } catch (e) {
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _error = e;
        _loadingTrack = false;
      });
    }
  }

  Future<void> _open(AudioStream track, {int epoch = 0}) async {
    if (!track.isPlayable) return;
    final lavf = [
      'seg_max_retry=3',
      'strict=experimental',
      'allowed_extensions=ALL',
      'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
      if (track.keyHex.isNotEmpty) 'decryption_key=${track.keyHex}',
    ].join(',');
    // CDN（qznovelvod）只认阅读客户端的 UA + Referer，其它一律 403；
    // mpv 默认没有这两个头，拉流会 403、进度不动，所以随 Media 一起传。
    await _engine.setProperty('demuxer-lavf-o', lavf);
    // 双保险：Media 带 httpHeaders；若 mpv 支持该属性再显式设一次。
    try {
      await _engine.setProperty(
        'http-header-fields',
        'User-Agent: com.dragon.read,Referer: https://reading.snssdk.com/',
      );
    } catch (_) {
      // 该属性不可用时忽略，Media 的 httpHeaders 仍会带上请求头。
    }
    await _engine.open(Media(track.path), play: true);
    if (!mounted || epoch != _playEpoch) return;
    await _engine.setRate(_speed);
    if (!mounted || epoch != _playEpoch) return;
    // 从阅读到的位置开始听（按章内比例换算成毫秒）。
    if (_startRatio > 0 && track.durationMs > 0) {
      await _waitDuration();
      if (!mounted || epoch != _playEpoch) return;
      final ms = (track.durationMs * _startRatio).round();
      await _engine.seek(Duration(milliseconds: ms));
    }
    if (_resumeMs > 0) {
      await _engine.seek(Duration(milliseconds: _resumeMs));
      _resumeMs = 0;
    }
    if (mounted && epoch == _playEpoch) {
      // 切章 position 归零 → 媒体时间轴基准重置：重新武装定时（注意事项 3）。
      final mode = _sleep.mode;
      if (mode != SleepMode.off) {
        _sleep.setMode(mode, minutes: _sleep.minutes);
      }
      setState(() => _playing = true);
      _syncBgm(play: true);
    }
  }

  void _onPosition(Duration p) {
    _lastPos = p;
    _sleepTick.value = p.inSeconds;
    _posMs.value = p.inMilliseconds;
    if (!_playing) return;
    // 统计只在“确实在播”时累计（暂停时位置流仍可能来心跳）。
    _stats?.tick();
    if (_sleep.armed) {
      // 音轨路径没有句级时间点 → sentenceEndMs 恒 null → 到点立即停；
      // 「该音源只能整点停止」已在控制区注明（注意事项 4）。
      final decision = _sleep.tick(position: p, sentenceEndMs: null);
      if (decision.stop) {
        unawaited(_applySleepStop());
      }
    }
    _drivePrefetch(p);
    _publishMedia();
  }

  /// 系统媒体会话（Android）：与控制器共用同一座桥与同一套命令，
  /// 只是播放器换成本页自己的 `_engine`（两条并行路径的既有现状）。
  DateTime _lastMediaPublish = DateTime.fromMillisecondsSinceEpoch(0);

  void _publishMedia({bool force = false}) {
    final bridge = ListenMediaBridge.instance;
    if (bridge == null) return;
    final now = DateTime.now();
    if (!force &&
        now.difference(_lastMediaPublish) <
            const Duration(milliseconds: 200)) {
      return;
    }
    _lastMediaPublish = now;
    bridge.attach(_onMediaCommand);
    final chapter = _chapter;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: chapter.id,
          title: widget.bookTitle,
          chapterTitle: chapter.title,
          artUri: widget.coverUrl.isEmpty ? null : widget.coverUrl,
          playing: _playing,
          buffering: _loadingTrack,
          position: _lastPos,
          // 音轨路径不给总时长：拿 0 冒充会让锁屏进度条一直是满的。
          total: null,
          speed: _speed,
          chapterIndex: _index,
          chapterCount: widget.chapters.length,
          canNext: _index < _maxIndex,
          canPrev: _index > 0,
        ),
      ),
    );
  }

  /// 离页等价于会话结束：推一个 idle 再解绑，不留“点击没人接”的假通知。
  void _publishStoppedMedia() {
    final bridge = ListenMediaBridge.instance;
    if (bridge == null) return;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: widget.bookId.isEmpty ? 'idle' : widget.bookId,
          title: widget.bookTitle,
          chapterTitle: '',
          playing: false,
          finished: true,
          speed: _speed,
        ),
      ),
    );
    bridge.detach(_onMediaCommand);
  }

  void _onMediaCommand(ListenMediaCommand cmd, Duration? position) {
    switch (cmd) {
      case ListenMediaCommand.play:
        if (!_playing) unawaited(_toggle());
      case ListenMediaCommand.pause:
        if (_playing) unawaited(_toggle());
      case ListenMediaCommand.toggle:
        unawaited(_toggle());
      case ListenMediaCommand.nextChapter:
        unawaited(_go(1));
      case ListenMediaCommand.prevChapter:
        unawaited(_go(-1));
      case ListenMediaCommand.stop:
        // 本页没有 close()：停止键只暂停，不拆会话。
        if (_playing) unawaited(_toggle());
      case ListenMediaCommand.seekTo:
        if (position != null) unawaited(_engine.seek(position));
      case ListenMediaCommand.prevSentence:
      case ListenMediaCommand.nextSentence:
        // 音轨路径没有句级时间点：退化为前后 15s，比按章跳更接近“上一句”的预期。
        unawaited(
          _seekBy(
            Duration(
              seconds: cmd == ListenMediaCommand.prevSentence ? -15 : 15,
            ),
          ),
        );
      case ListenMediaCommand.duck:
        unawaited(_engine.setVolume(0.25));
      case ListenMediaCommand.unduck:
        unawaited(_engine.setVolume(1.0));
    }
  }

  /// 到点先落进度再暂停（PRD 硬约束）；pause 保留会话，用户随时可继续。
  Future<void> _applySleepStop() async {
    await _saveProgress();
    // 淡出（可关）：与控制器同一份工具函数；结束后必须恢复满音量。
    var cancelled = false;
    if (_listenSettings?.sleepFadeOutEnabled ?? true) {
      final epoch = _playEpoch;
      try {
        final stillCurrent = await runVolumeFadeOut(
          setVolume: _engine.setVolume,
          isCurrent: () => epoch == _playEpoch && mounted,
        );
        // 淡出期间切章/离开页面：音量照旧恢复，但别把新章暂停掉。
        cancelled = !stillCurrent;
        await _engine.setVolume(1.0);
      } catch (_) {}
    }
    if (!cancelled) {
      try {
        await _engine.pause();
      } catch (_) {}
      if (mounted) setState(() => _playing = false);
    }
    if (!mounted) return;
    // 无论是否取消都要同步 off：否则下次进页会复活已用完的定时。
    await _persistSleep();
  }

  void _drivePrefetch(Duration p) {
    final settings = _listenSettings;
    if (settings == null || !settings.prefetchEnabled) return;
    final tone = _tone;
    if (tone == null) return;
    final nextIndex = _index + 1;
    if (nextIndex > _maxIndex) return;
    final next = widget.chapters[nextIndex];
    final total = Duration(milliseconds: _track?.durationMs ?? 0);
    if (!_prefetcher.shouldTrigger(
      taskId: next.id,
      position: p,
      total: total,
    )) {
      return;
    }
    // 现场捕获 api 与世代：work 迟到时按 isCurrent 丢弃，不碰 UI。
    final api = AppScope.read(context).api;
    final epoch = _playEpoch;
    unawaited(_prefetcher.pump(
      taskId: next.id,
      epoch: epoch,
      isCurrent: (value) => value == _playEpoch,
      work: () async {
        // 音轨版 work（design §4）：audioStream 让 core 提前落 audio_cache/，
        // 顺带拿时间点。403/无音轨等失败一律静默 —— 预取不许打扰当前播放。
        try {
          await api.audioStream(widget.bookId, next.id, tone.id);
          if (!mounted || epoch != _playEpoch) return;
          await api.audioTimepoints(widget.bookId, next.id, tone.id);
        } catch (_) {}
      },
    ));
  }

  /// 定时状态落盘：唯一入口 `ReaderListenSettings`（不另建 prefs 键）。
  Future<void> _persistSleep() async {
    final s = _listenSettings;
    if (s == null) return;
    try {
      await s.setSleepMode(_sleep.mode);
      final minutes = _sleep.minutes;
      if (minutes > 0) await s.setSleepMinutes(minutes);
      // 剩余快照：回到阅读页（另一个宿主）时能续上，而不是重新计满。
      await s.setSleepSnapshot(
        remainingMs: _sleep.remaining?.inMilliseconds,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  /// 定时浮层入口：与阅读页同一个 sheet、同一个组件类，本页不复制逻辑。
  Future<void> _openSleepSheet() async {
    await showListenSleepSheet(
      context,
      timer: _sleep,
      refresh: _sleepTick,
      onSaved: () {
        unawaited(_persistSleep());
        if (mounted) setState(() {});
      },
    );
  }

  /// 定时状态文案：只换算 [SleepTimer.remaining]，本页不自建 Timer。
  String get _sleepLabel {
    final left = _sleep.remaining;
    if (_sleep.mode == SleepMode.endOfChapter) return '本章播完后停止';
    if (left == null) return '定时已设定，开播后开始计时';
    final s = left.inSeconds;
    return '剩余 ${(s ~/ 60).toString().padLeft(2, '0')}:'
        '${(s % 60).toString().padLeft(2, '0')}（暂停不计时）';
  }

  Future<void> _toggle() async {
    if (_track == null) {
      await _playCurrent();
      return;
    }
    await _engine.playOrPause();
    if (mounted) setState(() => _playing = !_playing);
    _syncBgm(play: _playing);
    final stats = _stats;
    if (stats != null) {
      if (_playing) {
        stats.tick();
      } else {
        stats.pause();
        unawaited(stats.flush());
      }
    }
  }

  /// 前后跳（音轨没有句边界，用固定步长：退 15s / 进 30s）。
  Future<void> _seekBy(Duration delta) async {
    final target = listenSeekTarget(_lastPos, delta, _track?.durationMs ?? 0);
    try {
      await _engine.seek(target);
    } catch (_) {}
  }

  /// 书签面板：顶部“加在当前位置”，下面是本书记录（新的在前）。
  Future<void> _showBookmarks() async {
    final store = _bookmarks;
    if (store == null) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) {
          final marks = store.of(widget.bookId);
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: const Icon(Icons.bookmark_add_outlined),
                  title: const Text('在当前位置加书签'),
                  subtitle: Text(
                    '${_chapter.title} · ${formatListenTime(_lastPos)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () async {
                    await store.add(
                      widget.bookId,
                      ListenBookmark(
                        id: DateTime.now().microsecondsSinceEpoch.toString(),
                        chapterIndex: _index,
                        chapterTitle: _chapter.title,
                        positionMs: _lastPos.inMilliseconds,
                        createdAt: DateTime.now().millisecondsSinceEpoch,
                      ),
                    );
                    if (sheetContext.mounted) setSheetState(() {});
                  },
                ),
                const Divider(height: 1),
                if (marks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('还没有书签'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: marks.length,
                      itemBuilder: (_, i) {
                        final mark = marks[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.bookmark, size: 18),
                          title: Text(
                            '${mark.chapterTitle.isEmpty ? '第 ${mark.chapterIndex + 1} 章' : mark.chapterTitle}'
                            ' · ${formatListenTime(Duration(milliseconds: mark.positionMs))}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: mark.note.isEmpty
                              ? null
                              : Text(
                                  mark.note,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_note, size: 18),
                                tooltip: '编辑备注',
                                onPressed: () =>
                                    _editBookmarkNote(mark, setSheetState),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, size: 18),
                                tooltip: '删除书签',
                                onPressed: () async {
                                  await store.remove(widget.bookId, mark.id);
                                  if (sheetContext.mounted) {
                                    setSheetState(() {});
                                  }
                                },
                              ),
                            ],
                          ),
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            unawaited(_jumpToBookmark(mark));
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 改书签备注：位置不变，只补一句话（不影响列表排序）。
  Future<void> _editBookmarkNote(
    ListenBookmark mark,
    StateSetter refreshSheet,
  ) async {
    final controller = TextEditingController(text: mark.note);
    final note = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('书签备注'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(hintText: '例如：这段的设定很关键'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (note == null) return;
    await _bookmarks?.updateNote(widget.bookId, mark.id, note);
    if (mounted) refreshSheet(() {});
  }

  /// 跳到书签：先切章（切章会重开当前章），再 seek 到记录位置。
  Future<void> _jumpToBookmark(ListenBookmark mark) async {
    final index = mark.chapterIndex.clamp(0, _maxIndex);
    if (index != _index) await _selectChapter(index);
    if (!mounted) return;
    try {
      await _engine.seek(Duration(milliseconds: mark.positionMs));
    } catch (_) {}
  }

  /// 播放/加载失败重试：从**上次位置**续播（失败可能发生在章中，不该退回章首）。
  /// `_playCurrent` 自己会把 `_error` 清掉并重新拉流，所以这里只清播放错误与续播点。
  Future<void> _retryPlay() async {
    if (!mounted) return;
    setState(() => _playError = '');
    _resumeMs = _lastPos.inMilliseconds;
    await _playCurrent();
  }

  /// 把背景音乐同步到「设置 + 当前是否在播」（与控制器同一口径）。
  /// 未配置就停、换文件就重起、同文件只切播放状态；BGM 出问题不影响朗读。
  void _syncBgm({required bool play}) {
    final settings = _listenSettings;
    if (settings == null) return;
    final file = settings.bgmFile;
    if (file.isEmpty) {
      if (_bgm.isActive) unawaited(_bgm.stop());
      return;
    }
    final volume = (settings.bgmVolume / 100).clamp(0.0, 1.0).toDouble();
    if (!_bgm.isActive || _bgm.file != file) {
      unawaited(_bgm.start(file, volume: volume));
      return;
    }
    if (play) {
      unawaited(_bgm.resume());
    } else {
      unawaited(_bgm.pause());
    }
  }

  Future<void> _go(int delta) =>
      _selectChapter((_index + delta).clamp(0, _maxIndex));

  /// 跳到阅读页的**同一位置**：用「章内时间比例」近似字符比例。
  ///
  /// 不传 `restoreCharOffset`：音轨没有字符坐标（只有段级时间点），伪造一个字符位
  /// 会把用户丢到错的地方。朗读速度均匀，用比例已足够让人接着读。
  ///
  /// **先暂停**：本页播放器不属于全局控制器，若让它后台继续播，阅读页会“静悄悄
  /// 在看而耳朵里还有声”，两边进度各走各的。暂停后用户可在阅读页用页内听书
  /// 从同一进度继续（两处共享 `ListenProgressStore`）。
  Future<void> _openReader() async {
    if (_playing) await _toggle();
    await _saveProgress();
    if (!mounted) return;
    final totalMs = _track?.durationMs ?? 0;
    final ratio = listenRatioOf(_lastPos, totalMs);
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScreen(
          bookId: widget.bookId,
          bookTitle: widget.bookTitle,
          coverUrl: widget.coverUrl,
          chapters: widget.chapters,
          initialIndex: _index,
          restoreOffset: ratio,
        ),
      ),
    );
  }

  /// 切到指定章：清掉上一章的续播位置与「进入定位」，再播新章。
  Future<void> _selectChapter(int index) async {
    if (index == _index) return;
    await _saveProgress();
    if (!mounted) return;
    _resumeMs = 0;
    _startRatio = 0;
    _startParagraph = 0;
    setState(() => _index = index);
    await _playCurrent();
  }
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.bookTitle),
        // 精度徽标：这一页只播平台音轨（真人讲书 / 智能朗读），段级是**结构性**事实，
        // 徽标如实写「段」，不伪装成词级（design.md §6）。
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmarks_outlined),
            tooltip: '书签',
            onPressed: _bookmarks == null ? null : _showBookmarks,
          ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined),
            tooltip: '去阅读（暂停听书并定位）',
            onPressed: _loadingTones || _tones == null ? null : _openReader,
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(child: SpeechBadge(text: _badgeText)),
          ),
        ],
      ),
      body: _notTomatoBook
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.headphones_outlined,
                        size: 52, color: theme.colorScheme.outline),
                    const SizedBox(height: 14),
                    Text('这本书没有官方音轨',
                        style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    Text(
                      '番茄音轨只适用于书城内的书；第三方书源与本地书请用'
                      '阅读页顶部的「听书」按钮（系统 / 在线语音合成）。',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline, height: 1.6),
                    ),
                    const SizedBox(height: 18),
                    FilledButton.tonal(
                      onPressed: () => Navigator.of(context).maybePop(),
                      child: const Text('返回'),
                    ),
                  ],
                ),
              ),
            )
          : _loadingTones
          ? const Center(child: CircularProgressIndicator())
          : (_error != null && _tones == null)
              ? ErrorRetryView(error: _error!, onRetry: _loadTones)
              : (_tones == null || _tones!.tones.isEmpty)
              ? _buildNoTones(context)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    _buildHeader(context),
                    const SizedBox(height: 16),
                    _buildPlayer(context),
                    const SizedBox(height: 20),
                    Text('章节', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    for (final chapter in widget.chapters)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          chapter.index == _index
                              ? Icons.graphic_eq
                              : Icons.play_circle_outline,
                          size: 18,
                          color: chapter.index == _index
                              ? theme.colorScheme.primary
                              : null,
                        ),
                        title: Text(chapter.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => _selectChapter(chapter.index),
                      ),
                  ],
                ),
    );
  }

  /// 没有平台音轨时的出路：**引导去阅读页用合成朗读**。
  ///
  /// 以前这里只会显示“这本书暂不支持听书”—— 但其实阅读页的页内听书
  /// （Edge / 本地语音 / HTTP 源）完全能读这本书。听书页不该成为死胡同。
  Widget _buildNoTones(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.record_voice_over_outlined,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 12),
            const Text('这本书没有平台音轨', textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(
              '可以在阅读页用「听书」由设备或云端合成朗读，\n'
              '词级高亮与跟随也在那边。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ReaderScreen(
                    bookId: widget.bookId,
                    bookTitle: widget.bookTitle,
                    coverUrl: widget.coverUrl,
                    chapters: widget.chapters,
                    initialIndex: _index,
                    // 用户点「去阅读页听书」的意图已经明确：进页就自动开始。
                    autoListen: true,
                  ),
                ),
              ),
              icon: const Icon(Icons.menu_book_outlined),
              label: const Text('去阅读页听书'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final tones = _tones;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 64,
            height: 86,
            child: CoverImage(url: widget.coverUrl),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.bookTitle,
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 6),
              Text(
                tones == null || tones.isEmpty
                    ? '这本书暂不支持听书'
                    : (tones.hasRecordedAudio ? '有声书 · 真人讲书' : '智能朗读'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
              if (_record != null && _record!.chapterTitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text('上次听到 · ${_record!.chapterTitle}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.primary)),
              ],
              if (tones != null && tones.tones.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    children: [
                      for (final tone in tones.tones)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            avatar: tone.icon.isEmpty
                                ? null
                                : CircleAvatar(
                                    backgroundImage: NetworkImage(tone.icon)),
                            label: Text(tone.title),
                            selected: _tone?.id == tone.id,
                            onSelected: (_) {
                              // 换音色：音轨键全变，预取去重必须失效（design §3）。
                              _prefetcher.invalidate();
                              setState(() => _tone = tone);
                              _playCurrent();
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Text(_chapter.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  icon: const Icon(Icons.skip_previous),
                  onPressed: _index > 0 ? () => _go(-1) : null,
                ),
                IconButton(
                  tooltip: '后退 15 秒',
                  icon: const Icon(Icons.fast_rewind),
                  onPressed: _track == null
                      ? null
                      : () => _seekBy(const Duration(seconds: -15)),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: FilledButton(
                    onPressed: _tone == null ? null : _toggle,
                    style: FilledButton.styleFrom(
                        shape: const CircleBorder(),
                        padding: EdgeInsets.zero),
                    child: _loadingTrack
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                ),
                const SizedBox(width: 12),
                IconButton(
                  tooltip: '前进 30 秒',
                  icon: const Icon(Icons.fast_forward),
                  onPressed: _track == null
                      ? null
                      : () => _seekBy(const Duration(seconds: 30)),
                ),
                IconButton(
                  icon: const Icon(Icons.skip_next),
                  onPressed: _index < _maxIndex ? () => _go(1) : null,
                ),
                IconButton(
                  tooltip: '定时关闭',
                  icon: Icon(
                    _sleep.armed
                        ? Icons.bedtime
                        : Icons.bedtime_outlined,
                    color: _sleep.armed ? theme.colorScheme.primary : null,
                  ),
                  onPressed: _openSleepSheet,
                ),
              ],
            ),
            // 进度条：位置事件本来密，用两个 ValueNotifier 单独驱动，不整页 setState
            // （本页 body 是带章节列表的 ListView，拖动时逐帧 setState 会卡）。
            AnimatedBuilder(
              animation: Listenable.merge(<Listenable>[_posMs, _dragMs]),
              builder: (context, _) {
                final total = _track?.durationMs ?? 0;
                final raw = _dragMs.value ?? _posMs.value;
                final shown = total > 0 ? raw.clamp(0, total) : 0;
                final labelStyle = Theme.of(context).textTheme.labelSmall;
                return Column(
                  children: [
                    Slider(
                      value: total <= 0 ? 0 : shown.toDouble(),
                      max: total <= 0 ? 1 : total.toDouble(),
                      onChanged: total <= 0
                          ? null
                          : (v) => _dragMs.value = v.round(),
                      onChangeEnd: total <= 0
                          ? null
                          : (v) async {
                              _dragMs.value = null;
                              try {
                                await _engine.seek(
                                  Duration(milliseconds: v.round()),
                                );
                              } catch (_) {
                                // 不可 seek 的源（极少数直播式音轨）忽略。
                              }
                            },
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            formatListenTime(Duration(milliseconds: shown)),
                            style: labelStyle,
                          ),
                          Text(
                            formatListenTime(
                              Duration(milliseconds: total > 0 ? total : 0),
                            ),
                            style: labelStyle?.copyWith(
                              color: Theme.of(context).colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
            // 定时状态只来自组件（remaining 换算在本页一处）；音轨无句级
            // 时间点，到点只能整停，必须如实说明（注意事项 4）。
            if (_sleep.armed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  _sleepLabel,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.primary),
                ),
              ),
            if (_sleep.armed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '该音源只能整点停止',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ),
            const SizedBox(height: 8),
            Row(
            children: [
              const Text('语速'),
              Expanded(
                child: Slider(
                  value: _speed,
                  min: 0.5,
                  max: 2.0,
                  divisions: 6,
                  label: '${_speed.toStringAsFixed(2)}x',
                  onChanged: (v) {
                    // 拖动中只改内存与播放器：prefs 是磁盘写，逐帧落盘会卡、也无意义。
                    setState(() => _speed = v);
                    // ignore: discarded_futures
                    _engine.setRate(v);
                  },
                  // 松手才落盘：一次拖动只写一次。
                  onChangeEnd: (_) {
                    // ignore: discarded_futures
                    _savePrefs();
                  },
                ),
              ),
              SizedBox(
                width: 46,
                child: Text('${_speed.toStringAsFixed(2)}x',
                    style: theme.textTheme.labelSmall),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('自动连播'),
            subtitle: const Text('这一章播完自动播下一章'),
            value: _autoNext,
            onChanged: (v) {
              setState(() => _autoNext = v);
              // ignore: discarded_futures
              _savePrefs();
            },
          ),
          StreamBuilder<Duration>(
              stream: _engine.stream.position,
              builder: (context, pos) {
                return StreamBuilder<Duration>(
                  stream: _engine.stream.duration,
                  builder: (context, dur) {
                    final position = pos.data ?? Duration.zero;
                    final duration = dur.data ?? Duration.zero;
                    final maxMs = duration.inMilliseconds.toDouble();
                    final value = maxMs > 0
                        ? (position.inMilliseconds / maxMs).clamp(0.0, 1.0)
                        : 0.0;
                    return Column(
                      children: [
                        Slider(
                          value: value,
                          onChanged: maxMs <= 0
                              ? null
                              : (v) => _engine.seek(Duration(
                                  milliseconds: (v * maxMs).round())),
                        ),
                        Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            mainAxisAlignment:
                                MainAxisAlignment.spaceBetween,
                            children: [
                              Text(_fmt(position),
                                  style: theme.textTheme.labelSmall),
                              Text(_fmt(duration),
                                  style: theme.textTheme.labelSmall),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                );
              },
            ),
            if (_playError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(_playError,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.error)),
                    ),
                    TextButton.icon(
                      onPressed: _retryPlay,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error is AquaException
                            ? (_error! as AquaException).friendlyText
                            : '这一章暂时听不了',
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.error),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _retryPlay,
                      icon: const Icon(Icons.refresh, size: 18),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final listen = ReaderListenSettings(prefs);
      // 定时恢复只在未武装时进行（与控制器 _loadPrefs 同一规则）。
      if (_sleep.mode == SleepMode.off) {
        final saved = listen.sleepMode;
        if (saved == SleepMode.minutes) {
          // 与控制器同口径：按“剩余快照”续上，不重新计满。
          final minutes = sleepRestoreMinutes(
            savedRemainingMs: listen.sleepRemainingMs,
            savedAtMs: listen.sleepSavedAtMs,
            nowMs: DateTime.now().millisecondsSinceEpoch,
          );
          if (minutes != null) {
            _sleep.setMode(SleepMode.minutes, minutes: minutes);
          }
        } else if (saved == SleepMode.endOfChapter) {
          _sleep.setMode(SleepMode.endOfChapter);
        }
      }
      setState(() {
        // 按书语速优先，回落全局 —— 两条播放路径同一口径。
        _speed = (prefs.getDouble(
                      ReaderListenSettings.speedKeyOf(widget.bookId),
                    ) ??
                    prefs.getDouble(_speedKey) ??
                    1.0)
            .clamp(0.5, 2.0);
        _autoNext = prefs.getBool(_autoNextKey) ?? true;
        _listenSettings = listen;
        _stats = ListenStats(prefs);
        _bookmarks = ListenBookmarks(prefs);
      });
    } catch (_) {
      // 偏好读不到就用默认值。
    }
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 与控制器同口径：按书键 + 全局键都写（全局是新书的默认值）。
      await prefs.setDouble(_speedKey, _speed);
      await prefs.setDouble(
        ReaderListenSettings.speedKeyOf(widget.bookId),
        _speed,
      );
      await prefs.setBool(_autoNextKey, _autoNext);
    } catch (_) {
      // 偏好写失败不影响播放。
    }
  }

  /// 写入听书进度（章节 + 章内位置）。
  Future<void> _saveProgress() async {
    if (!mounted) return;
    final pos = _engine.state.position;
    // 位置没变就不重复落盘：5s 周期 + 生命周期回调会重复触发。
    if (pos == _lastSavedPos) return;
    _lastSavedPos = pos;
    try {
      await _listening.record(
        bookId: widget.bookId,
        title: widget.bookTitle,
        coverUrl: widget.coverUrl,
        chapterId: _chapter.id,
        chapterTitle: _chapter.title,
        chapterIndex: _index,
        chapters: widget.chapters.length,
        toneId: _tone?.id ?? 0,
        positionMs: pos.inMilliseconds,
      );
    } catch (_) {
      // 进度写入失败不影响播放。
    }
  }

  /// 等播放器拿到时长再定位：open 刚发出时 seek 会被忽略。
  Future<void> _waitDuration() async {
    try {
      await _engine.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      // 超时就按当前状态定位。
    }
  }
  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
