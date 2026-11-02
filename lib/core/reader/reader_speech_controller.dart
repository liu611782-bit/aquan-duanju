import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:shared_preferences/shared_preferences.dart';

import '../error_log.dart';
import '../../models/audio.dart';
import '../../models/book.dart';
import '../../store/stores.dart';
import '../aqua_api.dart';
import '../player/player_engine.dart';
import '../tts/edge/edge_constants.dart';
import '../tts/edge/edge_engine.dart';
import '../tts/http/http_tts_engine.dart';
import '../tts/http/http_tts_source.dart';
import '../tts/http/http_tts_source_store.dart';
import '../tts/piper/piper_engine.dart';
import '../tts/win/windows_speech_engine.dart';
import '../tts/speech_engine.dart';
import '../tts/tts_cache.dart';
import '../tts/tts_composer.dart';
import '../tts/tts_models.dart';
import 'reader_listen_settings.dart';
import 'reader_paragraphs.dart';
import 'reader_settings.dart';
import 'reader_speech_settings.dart';
import 'replace_rules.dart';
import 'speech/chapter_gap.dart';
import 'speech/chapter_prefetcher.dart';
import 'speech/fade_out.dart';
import 'speech/listen_bgm.dart';
import 'speech/listen_media_bridge.dart';
import 'speech/listen_media_state.dart';
import 'speech/listen_stats.dart';
import 'speech/sleep_timer.dart';
import 'speech/speaker_splitter.dart';
import 'speech/speech_unit.dart';

/// 端点漂移时如何重建引擎：返回替换用的引擎，`null` 表示没有下一个端点（直接报错）。
///
/// 抽成注入点有两个理由：① 换端点是**显式**动作，不能让协议漂移变成看不见的行为
/// （design.md §5 修正 2）；② 单测必须能断言降级路径而绝不真的联网。
typedef TtsEngineFallback = SpeechEngine? Function(
  SpeechEngine current,
  String proxy,
);

/// 默认降级：换一个 Edge preset 重建引擎（`EdgeSpeechEngine` 自己不在单次请求里
/// 静默换 host，见 `edge_engine.dart` 的 [EdgeSpeechEngine.fallbackPreset]）。
SpeechEngine? _edgePresetFallback(SpeechEngine current, String proxy) {
  if (current is! EdgeSpeechEngine) return null;
  final next = current.fallbackPreset;
  if (next == null) return null;
  return EdgeSpeechEngine(preset: next, proxy: proxy);
}

/// TTS 路径的 mpv 参数：拼接出来的 mp3 不需要 `decryption_key`，但白名单与音轨路径
/// 保持一致（design.md §6）。
const String _kTtsDemuxerOptions =
    'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]';

/// 当前朗读走的是哪条路径 —— 精度徽标与「手动切换路径」的唯一真值来源。
///
/// 三条路的精度**天生不同**：真人讲书与平台智能朗读只有段级时间点，自建合成才有词级。
/// UI 必须把它显示出来，不许把「拿不到词级」伪装成正常状态
/// （`backend/listen-tts-contract.md` §4「引擎精度低于词级」那一行）。
enum SpeechPath {
  /// 真人讲书音轨（`AudioTones.hasRecordedAudio`）。
  recorded,

  /// 平台智能朗读音轨（AI 音色）。
  platformTone,

  /// 本地/云端自建合成（Edge TTS 等）。
  cloudTts;

  /// 徽标文案的前半段；精度后缀由 [ReaderSpeechController.highlightGranularity] 决定。
  String get label => switch (this) {
    SpeechPath.recorded => '真人音轨',
    SpeechPath.platformTone => '智能朗读',
    SpeechPath.cloudTts => '云合成',
  };
}

/// 精度徽标文案（design.md §6）：`真人音轨·段` / `智能朗读·段` / `云合成·词`。
///
/// 数据只允许来自 [ReaderSpeechController.activePath] 与
/// [ReaderSpeechController.highlightGranularity]，UI 不许自己猜。**音轨路径恒显
/// 「段」** —— 平台音轨只有段落级时间点，`wordAt` 结构上就给不出词；把「拿不到词级」
/// 如实画成「段」而不是伪装成词级，就是「禁止静默降级」的用户可见落点。
String speechBadgeOf(SpeechPath path, SpeechGranularity granularity) {
  final precision = path != SpeechPath.cloudTts
      ? '段'
      : switch (granularity) {
          SpeechGranularity.word => '词',
          SpeechGranularity.sentence => '句',
          SpeechGranularity.paragraph => '段',
        };
  return '${path.label}·$precision';
}

/// 全局听书控制器：阅读页内听书、独立听书页、离开页面后的继续播放共用同一实例。
///
/// 刻意不持有 `BuildContext`：依赖（api / 进度 store）在构造时注入，页面只订阅
/// 与渲染。这样控制器可以挂在 `AppScope` 上，比页面活得更久。
class ReaderSpeechController extends ChangeNotifier {
  /// 合成引擎与缓存**默认由控制器自己懒建**：`main.dart` / `AppScope` 不需要知道
  /// TTS 的存在（design.md §9）。测试注入假引擎与临时目录缓存。
  ReaderSpeechController({
    required AquaApi api,
    required ListenProgressStore store,
    PlayerEngine? engine,
    this._ttsEngine,
    this._ttsCache,
    TtsComposer? ttsComposer,
    TtsEngineFallback? ttsEngineFallback,
    this._rules,
    this._settings,
    int Function()? clockMs,
    this.fadeSleep,
    /// 章内合成并发度（播放路径用）。预取路径不受它影响，永远串行。
    this.ttsConcurrency = kTtsDefaultConcurrency,
  }) : _engine = engine ?? MpvPlayerEngine(),
       _clockMs = clockMs ?? _wallClockMs,
       _ttsComposer = ttsComposer ?? TtsComposer(),
       _ttsEngineFallback = ttsEngineFallback ?? _edgePresetFallback {
    _api = api;
    _store = store;
  }

  static const String speedKey = 'listen.speed';
  static const String autoNextKey = 'listen.autoNext';

  /// 回滚开关：关掉后「无平台音色」回到今日行为（只报错不合成）。
  static const String ttsEnabledKey = 'listen.tts.enabled';
  static const String ttsVoiceKey = 'listen.tts.voice';
  static const String ttsProxyKey = 'listen.tts.proxy';
  static const String ttsQuotaKey = 'listen.tts.quotaMb';

  /// 合成引擎标识。当前只有 `edge` 一个实现，键先立住，加引擎不必改设置页。
  static const String ttsEngineKey = 'listen.tts.engine';

  late final AquaApi _api;
  late final ListenProgressStore _store;
  final PlayerEngine _engine;

  /// 朗读文本的派生入参：**可选注入**（`main.dart` 装配 `AppScope` 时传入）。
  /// 两者为空时退化成「无替换规则 + 不转简繁」，音轨路径完全不受影响 —— 它根本不取正文。
  /// 只读这两个 store 已有的 getter，不给它们加新 API。
  final ReplaceRuleStore? _rules;
  final ReaderSettingsStore? _settings;

  /// 合成引擎（懒建）；403 降级时会被替换成另一个 preset 的实例。
  SpeechEngine? _ttsEngine;
  TtsCache? _ttsCache;
  final TtsComposer _ttsComposer;
  final TtsEngineFallback _ttsEngineFallback;

  String _bookId = '';
  /// close() 进行中闸：进入即置 true，使 [isFor]/[isActive] 立刻翻 false（朗读条即时
  /// 消失），不依赖后续 `_engine.stop()` 是否卡住；[start] 复位。**只服务主动结束，
  /// 不影响错误态**（失败时不调 close，`_bookId` 保留、条仍可见，见 listen-tts-contract）。
  bool _finalizing = false;
  String _bookTitle = '';
  String _coverUrl = '';
  List<BookChapter> _chapters = const <BookChapter>[];
  int _chapterIndex = 0;

  AudioTones? _tones;
  AudioTone? _tone;

  /// 音色表属于哪本书（null = 未探测/已失效）。
  String? _tonesBookId;

  /// 时间点真值源：音轨路径 = [ParagraphTimelineAdapter]（委托既有 [AudioTimepoints]，
  /// 逐项行为不变），TTS 路径 = [SpeechTimeline]。高亮与跳段只认这一个抽象。
  SpeechPositions _positions = const ParagraphTimelineAdapter(
    AudioTimepoints(),
  );

  bool _loading = false;
  bool _playing = false;
  Object? _error;
  Duration _position = Duration.zero;
  int _paragraphIndex = 0;
  int _paragraphCount = 0;
  double _speed = 1.0;
  bool _autoNext = true;

  /// 整章合成进度（块级）。仅在 [loading] 且确实在合成时有意义；
  /// 预取不写这两个值 —— 后台任务不该驱动 UI 进度。
  int _synthDone = 0;
  int _synthTotal = 0;

  /// 本次会话走不走本地合成：无平台音色且 `listen.tts.enabled` 为真时才置位。
  /// 切章、上下章、自动连播都按它回到 [_startTts]，音轨链路的行为则完全照旧。
  bool _useTts = false;

  /// prefs 实例：高亮粒度偏好要**现取**（设置页改完立刻生效，不必重开朗读会话）。
  SharedPreferences? _prefs;

  /// 词/句高亮区间缓存（章内坐标）。位置事件每帧都查，但**下标没变就不 notify**，
  /// 这是「词级卡拉OK 不卡顿」的落点（design.md §3）。
  (int, int)? _wordRange;
  (int, int)? _sentenceRange;

  /// 本章派生出来的朗读段落快照（**只读**，TTS 路径填充；音轨路径不取正文故为空）。
  /// 存在的唯一理由：让「朗读段 == 屏幕段」可以被直接断言，而不是靠副作用反推。
  List<String> _speechSnapshot = const <String>[];

  // TTS 侧的设置快照（`_loadPrefs` 里读一次，构造引擎与缓存时用）。
  bool _ttsEnabled = true;
  String _ttsVoiceId = '';
  String _ttsProxy = '';
  /// 引擎选择（`listen.tts.engine`）。源配置本身走多源列表（`TtsSourceStore`）。
  String _ttsEngineId = kDefaultTtsEngineId;
  int _ttsQuotaMb = TtsCacheLimits.defaultQuotaMb;

  /// 定时关闭：唯一实现是 [SleepTimer]（design §1），本控制器只是它的宿主之一
  /// —— 不再长第二份状态机，也不新增 prefs 键（持久化走 [ReaderListenSettings]）。
  late final SleepTimer _sleep = SleepTimer(clockMs: _clockMs);

  /// 下一章预取调度：并发 1、去重、世代、失败静默（design §3）。
  final ChapterPrefetcher _prefetcher = ChapterPrefetcher();

  /// 背景音乐：独立播放器，跟随朗读起停（未配置时完全不启动）。
  final ListenBgm _bgm = ListenBgm();

  /// 听书统计（懒建：要等 prefs 就绪）。
  ListenStats? _statsValue;

  /// 取统计实例；prefs 未就绪时为 null（构造早期不累加，不影响正确性）。
  ListenStats? get _stats {
    final prefs = _prefs;
    if (prefs == null) return null;
    return _statsValue ??= ListenStats(prefs);
  }

  /// 当前媒体总时长（预取阈值要 `total`）。切章立刻清零：绝不拿上一章的时长
  /// 做判定，陈旧值会让新章刚开播就误触发。
  Duration _duration = Duration.zero;

  /// 定时关闭用的时钟。可注入：单测要造「墙钟已过 1 分钟」，否则只能真等一分钟。
  /// 生产默认是**墙钟**而非媒体位置 —— 拿媒体位置计时会让 2 倍速把 30 分钟缩成 15 分钟。
  final int Function() _clockMs;

  /// 淡出等待（可注入）：单测不该为一次 3 秒淡出干等。生产不传即真实等待。
  final Future<void> Function(Duration duration)? fadeSleep;

  /// 章内合成并发度。并发下「取消」的语义是「不再领新块」，
  /// 已启动的 ≤ N 个请求会跑完但结果丢弃（不能凭空打断已发出的 WSS）。
  final int ttsConcurrency;

  static int _wallClockMs() => DateTime.now().millisecondsSinceEpoch;

  /// 每次「打开某章」的代号：切章/换音色后旧请求的结果必须丢弃。
  int _epoch = 0;

  Timer? _saveTimer;
  Duration _lastSaved = Duration.zero;
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  String get bookId => _bookId;
  String get bookTitle => _bookTitle;
  List<BookChapter> get chapters => _chapters;
  int get chapterIndex => _chapterIndex;
  AudioTones? get tones => _tones;
  AudioTone? get tone => _tone;
  /// 合成等待文案：`正在合成 3 / 12 段`。不在合成中时为 null。
  ///
  /// 为什么需要它：自建合成是**整章**完成的（几十段要十几秒），只转一个沙漏会让
  /// 用户以为卡死。给到块级进度，等待就变成可预期的事。
  String? get synthesisLabel {
    if (!_loading || _synthTotal <= 0) return null;
    return '正在合成 $_synthDone / $_synthTotal 段';
  }

  /// 播放页 / 控制条要的状态快照。
  bool get loading => _loading;
  bool get playing => _playing;
  Object? get error => _error;
  Duration get position => _position;
  int get paragraphIndex => _paragraphIndex;

  /// 本章总时长（音轨来自 duration 事件流、TTS 来自时间表）；未知时为 0。
  Duration get duration => _duration;

  /// 剩余播放时间（**按当前倍速折算**）；总时长未知时为 null。
  ///
  /// 为什么折算：用户看到的「还要听多久」是真实世界时间，不是媒体时间轴长度 ——
  /// 2 倍速下剩 60s 媒体时间就是 30s 真实时间。
  Duration? get remaining {
    final total = _duration;
    if (total <= Duration.zero) return null;
    final left = total - _position;
    if (left <= Duration.zero) return Duration.zero;
    final rate = _speed <= 0 ? 1.0 : _speed;
    return Duration(milliseconds: (left.inMilliseconds / rate).round());
  }
  double get speed => _speed;
  bool get autoNext => _autoNext;

  /// 定时模式真值：直接读组件 —— 到点后组件**自动落回 off**，UI 必须每次现读
  /// 而不是缓存快照（派发块 A 注意事项 1）。
  SleepMode get sleepMode => _sleep.mode;

  /// 剩余时长。两处 UI 的定时显示文案只允许来自这里（design §5）。
  Duration? get sleepRemaining => _sleep.remaining;

  /// 已武装的定时时长（分钟）；非 minutes 模式恒 0。
  int get sleepMinutes => _sleep.minutes;

  /// 定时浮层的直接触点：`showListenSleepSheet` 驱动的就是这个实例。浮层只改
  /// 组件，落盘由宿主在 onSaved 里调 [persistSleep]。
  SleepTimer get sleepTimer => _sleep;

  /// 预取开关（`listen.prefetch`，默认开）。prefs 还没加载时按默认值 true。
  bool get prefetchEnabled {
    final prefs = _prefs;
    return prefs == null ? true : ReaderListenSettings(prefs).prefetchEnabled;
  }

  /// 段首尾静音裁剪（`listen.trim.silence`，默认开）。prefs 未就绪按默认 true。
  bool get trimSilenceEnabled {
    final prefs = _prefs;
    return prefs == null ? true : ReaderListenSettings(prefs).trimSilenceEnabled;
  }

  /// 章间间隔（`listen.chapterGapMs`，默认 800，0 = 硬切）。
  int get chapterGapMs {
    final prefs = _prefs;
    return prefs == null
        ? kDefaultChapterGapMs
        : ReaderListenSettings(prefs).chapterGapMs;
  }

  /// 定时淡出（`listen.sleep.fadeOut`，默认开）。
  bool get sleepFadeOutEnabled {
    final prefs = _prefs;
    return prefs == null
        ? true
        : ReaderListenSettings(prefs).sleepFadeOutEnabled;
  }

  /// 武装/取消定时：组件变更 + 持久化一步做完（`setMode(off)` 立即生效）。
  Future<void> setSleepMode(SleepMode mode, {int? minutes}) async {
    _sleep.setMode(mode, minutes: minutes);
    await persistSleep();
    notify();
  }

  /// 定时状态落盘的唯一出口。fire 后组件已自动落回 off，prefs 必须跟着写，
  /// 否则下次会话恢复会把「已用完的定时」复活。
  Future<void> persistSleep() async {
    final prefs = _prefs;
    if (prefs == null) return;
    try {
      final settings = ReaderListenSettings(prefs);
      await settings.setSleepMode(_sleep.mode);
      final minutes = _sleep.minutes;
      if (minutes > 0) await settings.setSleepMinutes(minutes);
      // 剩余快照：切到另一个宿主（听书页）时要能续上，而不是重新计满。
      await settings.setSleepSnapshot(
        remainingMs: _sleep.remaining?.inMilliseconds,
        savedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  /// 当前该高亮的那个字；精度不足时是 `null`（音轨链路、句级引擎都给不出）。
  SpeechPoint? get currentWord => _positions.wordAt(_position.inMilliseconds);

  /// 当前朗读路径（精度徽标的数据源）。
  SpeechPath get activePath {
    if (_useTts) return SpeechPath.cloudTts;
    final tones = _tones;
    if (tones != null && tones.hasRecordedAudio) return SpeechPath.recorded;
    return SpeechPath.platformTone;
  }

  /// 真正**画得出**的精度 = 时间表精度 ∩ 用户偏好（偏好「句」时不画词）。
  SpeechGranularity get highlightGranularity {
    final actual = _positions.granularity;
    final preferred = _preferredGranularity;
    if (preferred == SpeechHighlightGranularity.sentence &&
        actual.index > SpeechGranularity.sentence.index) {
      return SpeechGranularity.sentence;
    }
    return actual;
  }

  /// 当前句的章内字符区间 `[start,end)`。音轨路径没有句表 → `null`，
  /// 由页面退到「段落区间」画底纹（段级精度徽标随之出现，不静默）。
  (int, int)? get highlightSentence => _sentenceRange;

  /// 当前词的章内字符区间 `[start,end)`；精度不足或用户只要句级时 `null`。
  (int, int)? get highlightWord =>
      highlightGranularity == SpeechGranularity.word ? _wordRange : null;

  /// 本章朗读段落（与阅读页同一个 [deriveDisplayParagraphs] 算出来的那份）。
  List<String> get speechParagraphs => _speechSnapshot;

  /// 是否拿到了真正的词/句级时间点表（TTS 路径）；音轨路径恒 `false`。
  bool get hasTimeline {
    final positions = _positions;
    return positions is SpeechTimeline && !positions.isEmpty;
  }

  /// 顶栏精度徽标的文案：路径 + **真正画得出**的精度（[speechBadgeOf]）。
  String get badgeText => speechBadgeOf(activePath, highlightGranularity);

  /// 用户偏好粒度：`listen.granularity`，缺键按默认（词级）。
  SpeechHighlightGranularity get _preferredGranularity {
    final prefs = _prefs;
    if (prefs == null) return SpeechHighlightGranularity.word;
    return SpeechHighlightGranularity.parse(
      prefs.getString(ReaderSpeechSettings.granularityKey),
    );
  }

  /// 是否有正在进行的朗读会话（用于全局迷你条与页面接管判断）。
  bool get isActive => !_finalizing && _bookId.isNotEmpty;

  BookChapter? get currentChapter =>
      _chapterIndex >= 0 && _chapterIndex < _chapters.length
      ? _chapters[_chapterIndex]
      : null;

  bool isFor(String bookId) => !_finalizing && _bookId == bookId;

  /// 阅读页把「清洗后的段落数」告诉控制器：段落下标只能由这个数字收敛。
  ///
  /// 段数的**唯一写入者是阅读页**（`_afterLoad` 与 `_startSpeech`）。朗读文本现在
  /// 与页面同源于 [deriveDisplayParagraphs]，控制器自己算出的数字必然相等，因此
  /// 控制器不再调用本方法（上一子任务的 CRITICAL-1 就是「TTS 用自己的段数覆盖页面」）。
  /// 保留它给音轨路径收敛段落下标用。
  void setParagraphCount(int count) {
    if (count == _paragraphCount) return;
    _paragraphCount = count;
    _recomputeParagraph();
  }

  /// 打开一本书并从指定位置开始朗读。
  Future<void> start({
    required String bookId,
    required String bookTitle,
    required String coverUrl,
    required List<BookChapter> chapters,
    required int chapterIndex,
    int startParagraph = 0,
    double startRatio = 0,
    int toneId = 0,
  }) async {
    _finalizing = false; // 新会话复位关闭闸，恢复 isFor/isActive 判定
    final sameSession = _bookId == bookId && _playing;
    _bookId = bookId;
    _bookTitle = bookTitle;
    _coverUrl = coverUrl;
    _chapters = chapters;
    await _loadPrefs();
    if (sameSession) {
      notify();
      return;
    }
    _ensureSubs();
    // 新会话（含换书）：预取去重按 chapterId、不含书号，不同书恰好同名的章 id
    // 不能隔空挡掉本次预取，会话起点统一清空。
    _prefetcher.invalidate();
    // 音色表按**书**缓存：控制器是全局单例，听过的番茄书会留下 _tones；
    // 若不按 bookId 失效，换到第三方书时会直接跳过探测、拿 URL 当章节 id
    // 去请求音轨，报 `invalid chapter id "https://…"`。
    if (_tones != null && _tonesBookId != bookId) {
      _tones = null;
      _tone = null;
    }
    if (_tones == null) {
      try {
        _tones = await _api.audioTones(bookId);
        _tonesBookId = bookId;
      } on NoOfficialTrackException {
        // API 层已判定非番茄书（并记了调用栈日志）：按「无音轨」继续走 TTS。
        _tones = null;
        _tone = null;
      } catch (e) {
        // 第三方书源 / 本地书：id 不是番茄的，音轨接口必然拒绝。
        // 这不是错误，直接按「没有平台音轨」继续走本地合成（TTS）。
        final message = e.toString();
        final notTomato = message.contains('INVALID_OPTIONS') ||
            message.contains('invalid client options');
        _tones = null;
        _tone = null;
        if (!notTomato) {
          _error = e;
          notify();
          return;
        }
      }
      final tones = _tones;
      if (tones != null) {
        final saved = toneId > 0 ? toneId : (_store.entry(bookId)?.toneId ?? 0);
        final matched = tones.tones.where((t) => t.id == saved).toList();
        _tone = matched.isNotEmpty
            ? matched.first
            : (tones.tones.isEmpty ? null : tones.tones.first);
      }
    }
    // 硬闸门：章节 id 不是纯数字（第三方书源/本地书）→ 一律走本地合成。
    // 即使音色表探测“成功”也不碰音轨接口（番茄只认数字 item id）。
    final opening = _chapters.isEmpty
        ? ''
        : _chapters[chapterIndex.clamp(0, _chapters.length - 1)].id;
    if (_tones != null || _tone != null) {
      if (!RegExp(r'^\d+$').hasMatch(opening.trim())) {
        _tones = null;
        _tone = null;
        _tonesBookId = null;
      }
    }
    if (_tone == null) {
      // 以前这里直接报错收工。现在默认改走本地合成：绝大多数书根本没有平台音轨，
      // 「没有可用的朗读音色」对用户来说等同于「听书坏了」。开关关掉即回到今日行为。
      if (!_ttsEnabled) {
        _useTts = false;
        _error = '这本书暂时没有可用的朗读音色';
        notify();
        return;
      }
      _useTts = true;
      await _startTts(
        chapterIndex,
        startParagraph: startParagraph,
        startRatio: startRatio,
      );
      return;
    }
    _useTts = false;
    await _openChapter(
      chapterIndex,
      startParagraph: startParagraph,
      startRatio: startRatio,
    );
  }

  Future<void> toggle() async {
    if (!isActive) return;
    if (_loading) return;
    await _engine.playOrPause();
    _playing = !_playing;
    notify();
    if (!_playing) unawaited(_saveProgress());
    // BGM 跟着朗读走：人声停音乐也停，避免“朗读暂停了背景还在响”。
    _syncBgm(play: _playing);
    // 统计：播放时打点，暂停时清基线并落盘（不每秒写 prefs）。
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

  /// 把背景音乐同步到「设置 + 当前是否在播」。
  ///
  /// 三件事只在这里做：未配置就停、换了文件就重起、同文件只切播放状态。
  /// BGM 出任何问题都不影响朗读（`ListenBgm` 内部静默降级）。
  void _syncBgm({required bool play}) {
    final prefs = _prefs;
    if (prefs == null) return;
    final settings = ReaderListenSettings(prefs);
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

  /// 自动连播：先等章间间隔（可关），再切下一章。
  /// 等待期间任何会话变化（暂停/切章/关页）都让 epoch 变掉 → 不再自动跳。
  Future<void> _advanceToNextChapter() async {
    final epoch = _epoch;
    final current = await awaitChapterGap(
      chapterGapMs,
      isCurrent: () => epoch == _epoch && isActive,
    );
    if (!current) return;
    if (_chapterIndex >= _chapters.length - 1) return;
    await next();
  }

  Future<void> next() async {
    if (_chapterIndex >= _chapters.length - 1) return;
    await _saveProgress();
    await _openChapter(_chapterIndex + 1);
  }

  Future<void> previous() async {
    if (_chapterIndex <= 0) return;
    await _saveProgress();
    await _openChapter(_chapterIndex - 1);
  }

  Future<void> setTone(AudioTone tone) async {
    if (_tone?.id == tone.id) return;
    _tone = tone;
    // 换音色 = 音轨与合成产物键全变：去重集必须跟着失效，否则旧音色的
    // 「已预取」记录会挡掉新音色的真实预取（design §3，注意事项 5）。
    _prefetcher.invalidate();
    // 用户明确选了一个平台音色，这条会话就交回音轨链路；`_openChapter` 里
    // 的世代号会让进行中的合成结果作废。
    _useTts = false;
    await _saveProgress();
    // 换音色 = 换一条平台音轨：不同 tone 的时长与毫秒各不相同，把旧音轨的
    // `_position`（`keepPosition` 走毫秒 seek）灌进新音轨就是错的落点，实测会塌回
    // 段 0 从章首重读。与 setTtsVoice / setPreferredPath 同口径：用「段落 + 段内比例」
    // 锚点续读（轨道无关），落到新音轨对应段起点。
    final anchor = _currentAnchor();
    await _openChapter(
      _chapterIndex,
      startParagraph: anchor.$1,
      startRatio: anchor.$2,
      explicitStart: true,
    );
    ErrorLog.instance.record('听书音色',
        'setTone(${tone.id}) 完成：tone=${_tone?.id} 段落=$_paragraphIndex'
        '/$_paragraphCount 高亮缓存已重建');
  }

  /// 按音色 id 切换（UI 传的是 id）。
  Future<void> setToneById(int toneId) async {
    final tones = _tones?.tones ?? const <AudioTone>[];
    for (final tone in tones) {
      if (tone.id == toneId) {
        await setTone(tone);
        return;
      }
    }
  }

  /// 切 TTS 合成音色（设置页改 `listen.tts.voice` 时调用）。
  ///
  /// 之前设置页只写 prefs、控制器内存值不动：进行中的会话纹丝不动，
  /// 下次重开才生效，体验成「切了没反应」或「重开后从头读」。这里做成
  /// 热切换：音色进缓存键 → 当前章按新键取缓存/重合成，用「段 + 段内比例」
  /// 锚点续读（与 [setPreferredPath] 同口径；不同音色的音频时长不同，毫秒不可靠）。
  Future<void> setTtsVoice(String voiceId) async {
    if (_ttsVoiceId == voiceId) return;
    ErrorLog.instance.record('听书音色',
        'setTtsVoice 进入：$_ttsVoiceId → $voiceId，当前段落=$_paragraphIndex'
        '/$_paragraphCount useTts=$_useTts loading=$_loading');
    _ttsVoiceId = voiceId;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (voiceId.isEmpty) {
        await prefs.remove(ttsVoiceKey);
      } else {
        await prefs.setString(ttsVoiceKey, voiceId);
      }
    } catch (_) {}
    if (!isActive) {
      notify();
      return;
    }
    // 换音色 = 合成产物键全变：预取去重集同步失效（与 setTone 同一口径）。
    _prefetcher.invalidate();
    final anchor = _currentAnchor();
    await _openChapter(
      _chapterIndex,
      startParagraph: anchor.$1,
      startRatio: anchor.$2,
      explicitStart: true,
    );
    ErrorLog.instance.record('听书音色',
        'setTtsVoice($voiceId) 完成：段落=$_paragraphIndex/$_paragraphCount'
        ' useTts=$_useTts');
  }

  /// 同书在「平台音轨」与「自建合成」之间切换朗读路径，**不停下、不丢位置**。
  ///
  /// 保位规则（design.md §6）：当前位置 → 「段落下标 + 段内比例」→ 落到新表的段起点
  /// 毫秒（音轨侧 `AudioTimepoints.offsetMs`、合成侧 `SpeechTimeline.startMsOfParagraph`，
  /// 都是既有的「精确优先、比例兜底」）。两条链路的音频时长本来就不同，所以这里
  /// **不追求毫秒对齐**，只求回到同一段附近。
  ///
  /// `recorded` 与 `platformTone` 是同一条件链路的两面（有没有真人录音由服务端音色表
  /// 决定，不是用户能选的），所以这里只切「走不走自建合成」。失败时路径真值**回滚到
  /// 切换前**，并把原因给成 [TtsException.friendlyText] —— 绝不静默换成另一条路。
  Future<void> setPreferredPath(SpeechPath path) async {
    if (!isActive) return;
    final previousTts = _useTts;
    final wantTts = path == SpeechPath.cloudTts;
    if (wantTts == previousTts) return;
    if (!wantTts && _tone == null) {
      // 这本书根本没有平台音轨：没得切就明说，不许变成「按了但什么都没发生」。
      _error = '这本书没有平台音轨，切不回朗读前的音轨';
      notify();
      return;
    }
    final wasPlaying = _playing;
    final anchor = _currentAnchor();
    _useTts = wantTts;
    await _openChapter(
      _chapterIndex,
      startParagraph: anchor.$1,
      startRatio: anchor.$2,
      // 保位是「明确落点」，不是「续听」：anchor 为 (0, 0.0) 时也要落在段 0。
      explicitStart: true,
    );
    final failure = _error;
    if (failure == null) return;
    // 失败：路径回到切换前（后续换章、seek 也都按原路径走）。原媒体其实没被动过
    // —— 失败的那条链路在 `open()` 之前就抛了，所以播放状态如实还原。
    _useTts = previousTts;
    _playing = wasPlaying;
    _error = _friendlyOf(failure);
    notify();
  }

  /// 合成引擎的可用音色（设置页**懒加载**用）。失败照常抛出，由设置页吞掉：
  /// 拿不到列表就只显示已存值，不能挡住设置页打开（design.md §7）。
  Future<List<TtsVoice>> listTtsVoices() => _tts.voices();

  /// 当前合成引擎标识（`listen.tts.engine` 的只读回显）。
  String get ttsEngineId => _tts.id;

  /// 当前位置 → 「段落下标 + 段内比例」：路径切换保位的中间量。
  ///
  /// 比例按**当前那张表**的段起点区间算；表空、末段、算不出跨度时给 `0`，
  /// 于是落点退化成「新表里这段的起点」—— 这正是 §6 允许的不精确。
  (int, double) _currentAnchor() {
    final count = _paragraphCount;
    final paragraph = count > 0 ? _paragraphIndex.clamp(0, count - 1) : _paragraphIndex;
    if (count <= 1) return (paragraph, 0.0);
    final start = _positions.startMsOfParagraph(paragraph, paragraphCount: count);
    final next =
        _positions.startMsOfParagraph(paragraph + 1, paragraphCount: count);
    final span = next - start;
    if (span <= 0) return (paragraph, 0.0);
    return (paragraph, ((_position.inMilliseconds - start) / span).clamp(0.0, 1.0));
  }

  /// 错误 → 给用户看的文案：合成侧统一 [TtsException.friendlyText]，其它原样。
  static String _friendlyOf(Object error) {
    if (error is TtsException) return error.friendlyText;
    if (error is String) return error;
    return '$error';
  }

  Future<void> setSpeed(double speed) async {
    _speed = speed.clamp(0.5, 3.0);
    try {
      await _engine.setRate(_speed);
    } catch (_) {}
    notify();
    unawaited(_savePrefs());
  }

  Future<void> setAutoNext(bool value) async {
    _autoNext = value;
    notify();
    unawaited(_savePrefs());
  }

  /// 可读的错误文案：`error` 可能是 String（TtsException 已转过）也可能是异常对象，
  /// 只有这里允许把对象 `toString()` 给 UI（内部异常不上屏，见 listen-tts §4）。
  String? get errorText {
    final err = _error;
    if (err == null) return null;
    if (err is String) return err;
    return '$err';
  }

  /// 失败重试：清错误并**重开当前章**（沿用当前路径选择与音色）。
  ///
  /// 只做事后重来，不改任何设置 —— 用户点「重试」的预期是“再试一次”，
  /// 不是“换一种方式”。
  Future<void> retry() async {
    if (!isActive || _loading) return;
    final index = _chapterIndex;
    if (index < 0 || index >= _chapters.length) return;
    _error = null;
    notify();
    await _openChapter(index, keepPosition: true);
  }

  /// 外部改了 `listen.*` 后让控制器重读一遍（恢复默认 / 导入备份后）。
  ///
  /// 会**丢弃并重建**合成引擎：引擎与缓存都按设置里的引擎 id / 音色 / 代理构建，
  /// 不重建的话就会出现「已恢复默认，但还在用旧源合成」这种诡异状态。
  Future<void> reloadSettings() async {
    // 先把内存快照打回默认：`_loadPrefs` 的每一项都用 `?? 旧值` 兜底，
    // 不重置的话「恢复默认」会保留旧值（键已删 → 读到 null → 继续用旧值）。
    _speed = 1.0;
    _autoNext = true;
    _ttsEnabled = true;
    _ttsVoiceId = '';
    _ttsProxy = '';
    _ttsEngineId = kDefaultTtsEngineId;
    _ttsQuotaMb = TtsCacheLimits.defaultQuotaMb;
    await _loadPrefs();
    final old = _ttsEngine;
    _ttsEngine = null;
    // 引擎/音色变了，预取去重集必须跟着失效（与 setTone 同一口径）。
    _prefetcher.invalidate();
    if (old != null) {
      try {
        await old.dispose();
      } catch (_) {}
    }
    try {
      await _engine.setRate(_speed);
    } catch (_) {}
    notify();
  }

  /// 跳到上一段 / 下一段（朗读中）。
  Future<void> stepParagraph(int delta) async {
    if (_paragraphCount <= 0) return;
    final target = (_paragraphIndex + delta).clamp(0, _paragraphCount - 1);
    if (target == _paragraphIndex) return;
    final ms = _positions.startMsOfParagraph(
      target,
      paragraphCount: _paragraphCount,
    );
    if (ms <= 0) return;
    await _engine.seek(Duration(milliseconds: ms));
    _paragraphIndex = target;
    notify();
  }

  /// 跳到指定位置（拖动进度条用）。
  ///
  /// 只动播放位置，**不改任何持久化语义** —— 进度仍由 5s 节流 + 生命周期落盘；
  /// 索引要立刻重算，否则高亮会停在上一个位置直到下一条位置事件。
  Future<void> seekTo(Duration position) async {
    if (!isActive) return;
    var target = position < Duration.zero ? Duration.zero : position;
    final total = _duration;
    if (total > Duration.zero && target > total) target = total;
    try {
      await _engine.seek(target);
    } catch (_) {}
    _position = target;
    _recomputeParagraph();
    _updateHighlight();
    notify();
  }

  /// 停止朗读并清空会话（页面关闭入口调用）。控制器本身留活，供下次复用。
  Future<void> close() async {
    // 世代号 +1 就是中止信号：编排层每个 await 之后都问一次 `isCurrent`，
    // 进行中的合成会在下一段边界抛 `cancelled` 自行退出（不留半成品）。
    _epoch++;
    // 关闭闸先落下：isFor/isActive 随即翻 false，底部朗读条与全局迷你条立刻消失。
    // 仅把 notify 放在 `_bookId=''` 之前没用——显隐判据读的就是 `_bookId`，只要
    // `await _engine.stop()` 卡住或抛错，条就一直挂着（「结束朗读不消失」主诉）。
    _finalizing = true;
    notify();
    // close 也是预取的失效点（注意事项 5）：去重集独立于缓存键，不一起清会让
    // 下一次会话误判「已预取」。
    _prefetcher.invalidate();
    _clearHighlightCache();
    _saveTimer?.cancel();
    _saveTimer = null;
    unawaited(_saveProgress());
    unawaited(_bgm.stop());
    final stats = _stats;
    if (stats != null) {
      stats.pause();
      unawaited(stats.flush());
    }
    try {
      await _engine.stop();
    } catch (_) {}
    _bookId = '';
    _bookTitle = '';
    _coverUrl = '';
    _chapters = const <BookChapter>[];
    _chapterIndex = 0;
    _tones = null;
    _tone = null;
    _positions = const ParagraphTimelineAdapter(AudioTimepoints());
    _clearHighlightCache();
    _speechSnapshot = const <String>[];
    _playing = false;
    _loading = false;
    _error = null;
    _position = Duration.zero;
    _paragraphIndex = 0;
    _paragraphCount = 0;
    _useTts = false;
    _publishStoppedMedia();
    notify();
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    final tts = _ttsEngine;
    if (tts != null) unawaited(tts.dispose());
    unawaited(_bgm.dispose());
    final stats = _statsValue;
    if (stats != null) unawaited(stats.flush());
    unawaited(_engine.dispose());
    super.dispose();
  }

  // ---------- 内部 ----------

  /// 上次向媒体会话发布时间（节流用）。位置事件本就密，没必要每帧刷通知。
  DateTime _lastMediaPublish = DateTime.fromMillisecondsSinceEpoch(0);

  /// 多角色音色计划。按「当前音色 + 对话偏好」缓存一次：
  /// 每章都去拉一次音色表会让切章多一次网络往返。
  SpeechRolePlan? _rolePlanCache;
  String _rolePlanKey = '';

  /// 解析多角色计划；开关关闭 / prefs 未就绪 / 引擎无音色 → null（单音色）。
  Future<SpeechRolePlan?> _rolePlanFor(TtsVoice voice) async {
    final prefs = _prefs;
    if (prefs == null) return null;
    final settings = ReaderListenSettings(prefs);
    if (!settings.rolesEnabled) return null;
    final key = '${voice.id}|${settings.roleVoices.join(',')}';
    if (_rolePlanCache != null && _rolePlanKey == key) return _rolePlanCache;
    final voices = await listTtsVoices();
    final plan = SpeechRolePlan.fromVoices(
      voices,
      preferred: voice,
      dialoguePreferences: settings.roleVoices,
    );
    _rolePlanCache = plan;
    _rolePlanKey = key;
    return plan;
  }

  /// 缓存键里的「音色」字段：多角色时用计划签名（含全部音色），
  /// 否则同一章会用同一枚键命中单音色的旧产物。
  ///
  /// 静音裁剪会改变字节与时间点，所以开关状态也进键（`#t1`/`#t0`）：关闭后
  /// 不会命中裁剪过的旧产物，反之亦然。
  String _voiceIdFor(TtsVoice voice, SpeechRolePlan? plan) =>
      '${plan == null ? voice.id : plan.signature}#'
      '${trimSilenceEnabled ? 't1' : 't0'}';

  /// 给编排层的按单元音色解析器（plan 为空则不传，保持单音色路径不变）。
  TtsVoice Function(SpeechUnit unit)? _voiceResolver(
    List<SpeechUnit> units,
    SpeechRolePlan? plan,
  ) {
    if (plan == null) return null;
    final byUnit = <int, SpeechRoleSpan>{
      for (final span in SpeakerSplitter.split(units)) span.unit.index: span,
    };
    return (unit) {
      final span = byUnit[unit.index];
      return span == null ? plan.narrator : plan.voiceFor(span);
    };
  }

  /// 把当前状态推给通知栏 / 锁屏。桥为空（非 Android 或未装配）时直接返回。
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
    // attach 幂等：每次发布顺手挂上，避免「先播放后装配桥」的时序空洞。
    bridge.attach(_onMediaCommand);
    final chapter = currentChapter;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: chapter?.id ?? _bookId,
          title: _bookTitle,
          chapterTitle: chapter?.title ?? '',
          artUri: _coverUrl.isEmpty ? null : _coverUrl,
          playing: _playing,
          buffering: _loading,
          position: _position,
          // `_duration` 未知时给 null：拿 0 冒充总长会让锁屏进度条一直是满的。
          total: _duration > Duration.zero ? _duration : null,
          speed: _speed,
          chapterIndex: _chapterIndex,
          chapterCount: _chapters.length,
          canNext: _chapterIndex < _chapters.length - 1,
          canPrev: _chapterIndex > 0,
        ),
      ),
    );
  }

  /// 会话结束时把通知收敛为 idle 并解绑：否则会留一个「可继续」的假通知，
  /// 用户点播放却没人接（因为会话已经关了）。
  void _publishStoppedMedia() {
    final bridge = ListenMediaBridge.instance;
    if (bridge == null) return;
    unawaited(
      bridge.publish(
        ListenMediaState(
          mediaId: _bookId.isEmpty ? 'idle' : _bookId,
          title: _bookTitle,
          chapterTitle: '',
          playing: false,
          finished: true,
          speed: _speed,
        ),
      ),
    );
    bridge.detach(_onMediaCommand);
  }

  /// 系统媒体命令：**全部转给已有方法**，不在这里改进度语义。
  void _onMediaCommand(ListenMediaCommand cmd, Duration? position) {
    switch (cmd) {
      case ListenMediaCommand.play:
        if (!_playing && !_loading) unawaited(toggle());
      case ListenMediaCommand.pause:
        if (_playing) unawaited(toggle());
      case ListenMediaCommand.toggle:
        if (!_loading) unawaited(toggle());
      case ListenMediaCommand.nextChapter:
        unawaited(next());
      case ListenMediaCommand.prevChapter:
        unawaited(previous());
      case ListenMediaCommand.stop:
        unawaited(close());
      case ListenMediaCommand.seekTo:
        if (position != null) unawaited(_engine.seek(position));
      case ListenMediaCommand.prevSentence:
        unawaited(stepParagraph(-1));
      case ListenMediaCommand.nextSentence:
        unawaited(stepParagraph(1));
      case ListenMediaCommand.duck:
        // 工程没有独立音量设置：压低到 25%，unduck 恢复满。
        unawaited(_engine.setVolume(0.25));
      case ListenMediaCommand.unduck:
        unawaited(_engine.setVolume(1.0));
    }
  }

  void notify() {
    notifyListeners();
    // 通知栏/锁屏跟随状态（内部 200ms 节流）。
    _publishMedia();
  }

  void _ensureSubs() {
    if (_subs.isNotEmpty) return;
    _subs.add(_engine.stream.position.listen(_onPosition));
    // 时长只喂给预取阈值判定，不 notify：切章时先收到零、再收到真实时长，
    // 拿上一章的旧时长判定阈值会误触发（清零也发生在 _openChapter 成功处）。
    _subs.add(_engine.stream.duration.listen((d) => _duration = d));
    _subs.add(
      _engine.stream.playing.listen((playing) {
        if (_playing == playing) return;
        _playing = playing;
        notify();
      }),
    );
    _subs.add(
      _engine.stream.completed.listen((done) {
        if (!done) return;
        // 「本章播完停」：先让定时组件判决（fire 会置连播抑制位），再决定是否
        // 连播。抑制位必须在 `_autoNext` 早退**之前**消费 —— 它读一次即清，
        // 被早退挡在门外会隔空误伤之后章节的连播（注意事项 2）。
        if (_sleep.mode == SleepMode.endOfChapter) {
          final decision = _sleep.tick(
            position: _position,
            chapterCompleted: true,
          );
          if (decision.stop) unawaited(_applySleepStop());
        }
        if (_sleep.consumeSleepSuppressAutoNext()) {
          notify();
          return;
        }
        if (!_autoNext) return;
        if (_chapterIndex >= _chapters.length - 1) return;
        unawaited(_advanceToNextChapter());
      }),
    );
    _subs.add(
      _engine.stream.error.listen((message) {
        if (message.isEmpty) return;
        _error = message;
        _playing = false;
        notify();
      }),
    );
  }

  /// 位置事件的三笔账分开算（design.md §3）：
  /// 1. 词/句下标变了 → 立刻 notify，卡拉OK 不能等 250ms；
  /// 2. 段落下标变了 → 同样立刻 notify，否则自动跟随看起来「不跟」；
  /// 3. 都没变 → 只为进度条的平滑走 250ms 节流，避免阅读页整页重建。
  void _onPosition(Duration p) {
    _position = p;
    // 统计只在“确实在播”时累计：暂停时位置流仍可能来心跳。
    if (_playing) _stats?.tick();
    final paragraphMoved = _recomputeParagraph();
    final highlightMoved = _updateHighlight();
    _driveSleepAndPrefetch(p);
    final now = DateTime.now();
    if (!paragraphMoved &&
        !highlightMoved &&
        now.difference(_lastNotify) < const Duration(milliseconds: 250)) {
      return;
    }
    _lastNotify = now;
    notify();
  }

  /// 返回段落下标是否变化。
  bool _recomputeParagraph() {
    if (_paragraphCount <= 0) return false;
    final next = _positions.paragraphAt(
      _position.inMilliseconds,
      paragraphCount: _paragraphCount,
    );
    if (next == _paragraphIndex) return false;
    _paragraphIndex = next;
    return true;
  }

  /// 二分查一次词/句点并缓存，返回**区间有没有变**。
  ///
  /// 词/句/段三张表在 [SpeechTimeline] 构建时就排好了，这里只做二分；同一段朗读里
  /// 绝大多数位置事件都落在同一个词上 → 直接返回 false，一次 notify 都不发。
  bool _updateHighlight() {
    final ms = _position.inMilliseconds;
    final word = _positions.wordAt(ms);
    final sentence = _positions.sentenceAt(ms);
    final nextWord = word == null ? null : (word.charStart, word.charEnd);
    final nextSentence = sentence == null
        ? null
        : (sentence.charStart, sentence.charEnd);
    if (nextWord == _wordRange && nextSentence == _sentenceRange) return false;
    _wordRange = nextWord;
    _sentenceRange = nextSentence;
    return true;
  }

  /// 世代递增（切章/切音色/关闭）时必须清缓存：旧表算出的字符区间对新章毫无意义，
  /// 留着就是「高亮串章」。
  void _clearHighlightCache() {
    _wordRange = null;
    _sentenceRange = null;
  }

  /// 时间点真值源的唯一写入口：赋值 + 清缓存，避免哪一处忘了清。
  void _applyPositions(SpeechPositions value) {
    _positions = value;
    _clearHighlightCache();
  }

  /// 定时与预取都由位置事件驱动：引擎只在播放中发位置事件，所以暂停天然
  /// 不计时、也不推进预取判定（注意事项 1，与组件的媒体时间轴语义一致）。
  void _driveSleepAndPrefetch(Duration p) {
    if (!_playing) return;
    if (_sleep.armed) {
      // 句尾守卫取时间表里的句边界（毫秒）；音轨路径结构上没有句级点 →
      // null → 到点只能整停（注意事项 4，UI 如实说明）。
      final sentence = _positions.sentenceAt(p.inMilliseconds);
      final decision = _sleep.tick(
        position: p,
        sentenceEndMs: sentence == null
            ? null
            : Duration(milliseconds: sentence.endMs),
      );
      if (decision.stop) unawaited(_applySleepStop());
    }
    if (prefetchEnabled) _drivePrefetch(p);
  }

  /// 定时到点的硬约束（PRD）：**先落听书进度、再暂停**。用 `pause` 而非
  /// `stop`：保留会话，用户随时可继续；进度只写 [ListenProgressStore]。
  Future<void> _applySleepStop() async {
    await _saveProgress();
    // 淡出（可关）：3 秒内把音量降到 0 再暂停。无论淡出是否被取消，音量都要恢复满
    // —— 那是播放器状态，不恢复会让下次播放「没声音」且极难归因。
    var cancelled = false;
    if (sleepFadeOutEnabled) {
      final epoch = _epoch;
      try {
        final stillCurrent = await runVolumeFadeOut(
          setVolume: _engine.setVolume,
          isCurrent: () => epoch == _epoch,
          sleep: fadeSleep,
        );
        // 淡出期间用户切章/关会话：音量照旧恢复，但**绝不能把新章暂停掉**。
        cancelled = !stillCurrent;
        await _engine.setVolume(1.0);
      } catch (_) {}
    }
    if (!cancelled) {
      try {
        await _engine.pause();
      } catch (_) {}
      _playing = false;
      notify();
    }
    // 无论是否取消，定时组件已 fire 落回 off；prefs 必须同步，否则下次会复活定时。
    await persistSleep();
  }

  void _drivePrefetch(Duration p) {
    final nextIndex = _chapterIndex + 1;
    if (nextIndex >= _chapters.length) return;
    final next = _chapters[nextIndex];
    if (!_prefetcher.shouldTrigger(
      taskId: next.id,
      position: p,
      total: _duration,
    )) {
      return;
    }
    // 现场捕获世代与路径：work 落地时可能已切章/换音色，迟到产物由
    // isCurrent 丢弃（design §3）。
    final epoch = _epoch;
    final tts = activePath == SpeechPath.cloudTts;
    final toneId = _tone?.id ?? 0;
    final bookId = _bookId;
    unawaited(_prefetcher.pump(
      taskId: next.id,
      epoch: epoch,
      isCurrent: (value) => value == _epoch,
      work: () => _prefetchNextChapter(
        bookId: bookId,
        next: next,
        epoch: epoch,
        tts: tts,
        toneId: toneId,
      ),
    ));
  }

  /// `work` 闭包的两种实现（design §4）。失败一律静默：预取是锦上添花，
  /// 不许打断播放、不许弹错误；坏项成对删除是 [TtsCache] 的职责，这里不复制。
  Future<void> _prefetchNextChapter({
    required String bookId,
    required BookChapter next,
    required int epoch,
    required bool tts,
    required int toneId,
  }) async {
    try {
      if (tts) {
        // 正文必须走 _speechParagraphs（同源 deriveDisplayParagraphs）：否则
        // 预取产物与播放时派生的段落不一致 → 时间点错位（CRITICAL-1 口径）。
        final paragraphs = await _speechParagraphs(next);
        if (epoch != _epoch) return;
        final engine = _tts;
        final cache = _cache;
        final voice = TtsVoice(
          id: _ttsVoiceId.isEmpty ? kEdgeFallbackVoice : _ttsVoiceId,
        );
        final key = TtsCacheKey(
          bookId: bookId,
          chapterId: next.id,
          engineId: engine.id,
          voiceId: _voiceIdFor(voice, await _rolePlanFor(voice)),
        );
        final signature = cache.signatureOf(paragraphs);
        // 已有有效条目就不再合成：预取不许白打 Edge 的连接配额。
        if (await cache.lookup(
              key,
              textSignature: signature,
              extension: _tts.caps.container,
            ) !=
            null) {
          return;
        }
        final units = splitSpeechUnits(paragraphs);
        if (units.isEmpty) return;
        final composition = await _ttsComposer.composeChapter(
          engine: engine,
          paragraphs: paragraphs,
          voice: voice,
          voiceFor: _voiceResolver(units, await _rolePlanFor(voice)),
          epoch: epoch,
          units: units,
          isCurrent: (value) => value == _epoch,
          // 与缓存键后缀同一个取值：预取产物必须与播放时同一口径。
          trimSilence: trimSilenceEnabled,
          // 后台预取不得与正在播放的合成抢 Edge 连接配额：永远串行。
          concurrency: 1,
        );
        if (epoch != _epoch) return;
        await cache.save(
          key,
          audio: composition.audio,
          timeline: composition.timeline,
          textSignature: signature,
          extension: _tts.caps.container,
        );
        return;
      }
      // 音轨路径：audioStream 本身就是「core 下载并落 audio_cache/」
      // （reading-contract）；顺带把时间点也拿了，切章高亮立刻可用。
      if (toneId <= 0) return;
      await _api.audioStream(bookId, next.id, toneId);
      if (epoch != _epoch) return;
      await _api.audioTimepoints(bookId, next.id, toneId);
    } catch (_) {
      // 静默（含 TtsException：friendlyText 只用于打扰用户的错误展示，
      // 预取失败不弹窗也不置 error）。
    }
  }

  /// 切章/连播会让 `position` 归零 → 媒体时间轴的计时基准必须重新开始
  /// （注意事项 3）；endOfChapter 重新武装等待下一章的 completed。
  void _rearmSleepForChapter() {
    final mode = _sleep.mode;
    if (mode == SleepMode.off) return;
    _sleep.setMode(mode, minutes: _sleep.minutes);
  }

  Future<void> _openChapter(
    int index, {
    int startParagraph = 0,
    double startRatio = 0,
    bool keepPosition = false,
    bool explicitStart = false,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    // 上下章与自动连播共用一个入口：TTS 会话换章必须继续走合成，否则第二章起
    // 会退回「没有可用音色」的老错误。
    if (_useTts) {
      await _startTts(
        index,
        startParagraph: startParagraph,
        startRatio: startRatio,
        keepPosition: keepPosition,
        explicitStart: explicitStart,
      );
      return;
    }
    final tone = _tone;
    if (tone == null) return;
    final epoch = ++_epoch;
    _clearHighlightCache();
    _chapterIndex = index;
    _loading = true;
    // 音轨路径没有合成，清掉上一章的合成进度，免得 UI 残留旧数字。
    _synthDone = 0;
    _synthTotal = 0;
    // 音轨路径不派生正文：不清的话，从 TTS 章切过来会留着上一本的段落快照，
    // 让「朗读文本」类 UI 对照错（虽然不参与合成决策，但会误导排查）。
    _speechSnapshot = const <String>[];
    _error = null;
    notify();
    final chapter = _chapters[index];
    final resumeMs = keepPosition ? _position.inMilliseconds : 0;
    // 第三方书源的章节 id 是 URL / `booksrc:…`，番茄音轨接口只认纯数字。
    // 直接改走本地合成，不再把 URL 当章节号发出去。
    if (!RegExp(r'^\d+$').hasMatch(chapter.id.trim())) {
      _loading = false;
      if (!_ttsEnabled) {
        _useTts = false;
        _error = '这本书没有官方音轨（已改用本地朗读，可在设置里开启）';
        notify();
        return;
      }
      _useTts = true;
      await _startTts(
        index,
        startParagraph: startParagraph,
        startRatio: startRatio,
        keepPosition: keepPosition,
        explicitStart: explicitStart,
      );
      return;
    }
    try {
      final track = await _api.audioStream(_bookId, chapter.id, tone.id);
      if (epoch != _epoch) return;
      // 时间点与音轨并行：高亮依赖段落映射，早点拿到。
      unawaited(_loadTimepoints(chapter.id, tone.id, epoch));
      await _engine.initialize();
      if (epoch != _epoch) return;
      final lavf = [
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (track.keyHex.isNotEmpty) 'decryption_key=${track.keyHex}',
      ].join(',');
      await _engine.setProperty('demuxer-lavf-o', lavf);
      try {
        await _engine.setProperty(
          'http-header-fields',
          'User-Agent: com.dragon.read,Referer: https://reading.snssdk.com/',
        );
      } catch (_) {}
      await _engine.open(Media(track.path), play: true);
      if (epoch != _epoch) return;
      await _engine.setRate(_speed);
      if (epoch != _epoch) return;
      _playing = true;
      _loading = false;
      // 开播成功后才起 BGM：失败路径不该有音乐单独响着。
      _syncBgm(play: true);
      _position = Duration.zero;
      _paragraphIndex = 0;
      // 新媒体的真实时长由 duration 事件流回填；先清零，预取阈值不吃上一章旧值。
      _duration = Duration.zero;
      _startSaveTimer();
      _rearmSleepForChapter();

      // `explicitStart` = 调用方给了明确落点（路径切换保位）。段 0 + 比例 0 也要落在
      // 段 0：绝不能退到「上次持久化进度」那一路 —— 那个毫秒数属于**另一条**音频
      // （音轨与合成的时长本来就不同），灌进来就是跳到随机位置。
      final startFromHead =
          explicitStart && startParagraph <= 0 && startRatio <= 0;
      final targetMs = resumeMs > 0
          ? resumeMs
          : (startParagraph > 0 || startRatio > 0)
          ? null
          : startFromHead
          ? 0
          : (_store.entry(_bookId)?.positionMs ?? 0);
      if (targetMs != null && targetMs > 0) {
        await _engine.seek(Duration(milliseconds: targetMs));
      } else if (startParagraph > 0 || startRatio > 0) {
        await _waitDuration();
        if (epoch != _epoch) return;
        final points = await _api.audioTimepoints(_bookId, chapter.id, tone.id);
        if (epoch != _epoch) return;
        _applyPositions(ParagraphTimelineAdapter(points));
        final ms = points.offsetMs(
          paragraphIndex: startParagraph,
          ratio: startRatio,
        );
        if (ms > 0) await _engine.seek(Duration(milliseconds: ms));
      }
      notify();
    } catch (e) {
      if (epoch != _epoch) return;
      _error = e;
      _loading = false;
      _playing = false;
      notify();
    }
  }

  Future<void> _loadTimepoints(String chapterId, int toneId, int epoch) async {
    try {
      final points = await _api.audioTimepoints(_bookId, chapterId, toneId);
      if (epoch != _epoch) return;
      _applyPositions(ParagraphTimelineAdapter(points));
      _recomputeParagraph();
      notify();
    } catch (e, stack) {
      // 时间点拿不到就退化成不精确高亮（仍按段落数比例估算）。
      // 用户反复报「切音色后高亮/跟随没了」：新音色大概率没有时间点数据，
      // 记下来才能区分「数据缺失」与「切换逻辑 bug」。
      ErrorLog.instance.record(
          '听书时间点', 'chapter=$chapterId tone=$toneId 失败：$e', stack);
      _applyPositions(const ParagraphTimelineAdapter(AudioTimepoints()));
    }
  }

  Future<void> _waitDuration() async {
    try {
      await _engine.stream.duration
          .firstWhere((d) => d > Duration.zero)
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// 本地合成链路：正文 → 朗读单元 → 查缓存（命中零网络）→ 合成 → 成对落盘 →
  /// 播放本地 mp3。高亮/跳段与音轨路径共用 [_onPosition]/[_recomputeParagraph]，
  /// 只是把真值源换成 [SpeechTimeline]。
  Future<void> _startTts(
    int index, {
    int startParagraph = 0,
    double startRatio = 0,
    bool keepPosition = false,
    bool explicitStart = false,
  }) async {
    if (index < 0 || index >= _chapters.length) return;
    final chapter = _chapters[index];
    final epoch = ++_epoch;
    _clearHighlightCache();
    _chapterIndex = index;
    _loading = true;
    // 新一次合成：进度从 0 开始（缓存命中时不会回调，自然也不显示）。
    _synthDone = 0;
    _synthTotal = 0;
    _error = null;
    notify();
    final resumeMs = keepPosition ? _position.inMilliseconds : 0;
    try {
      final paragraphs = await _speechParagraphs(chapter);
      if (epoch != _epoch) return;
      // 只读快照：给测试与「朗读文本」类 UI 证明同源用，不参与任何合成决策。
      _speechSnapshot = paragraphs;
      final units = splitSpeechUnits(paragraphs);
      if (units.isEmpty) {
        throw const TtsException(
          TtsErrorCode.emptyAudio,
          message: '本章没有可朗读的正文',
        );
      }
      final product = await _produceChapterAudio(
        chapter: chapter,
        paragraphs: paragraphs,
        units: units,
        epoch: epoch,
      );
      if (epoch != _epoch) return;
      // 状态只在新章真正开播这一刻切换：段数与时间点必须同源，否则
      // `paragraphAt` 会把上一章的毫秒数落到下一章的段落上。
      _applyPositions(product.timeline);
      // 段数的唯一写入者是阅读页：这里只在没有阅读页在场（独立听书页、正文还没
      // 加载完）时兜底，绝不覆盖页面已经推来的数字。
      if (_paragraphCount <= 0) _paragraphCount = paragraphs.length;
      await _engine.initialize();
      if (epoch != _epoch) return;
      await _engine.setProperty('demuxer-lavf-o', _kTtsDemuxerOptions);
      await _engine.open(Media(product.audioPath), play: true);
      if (epoch != _epoch) return;
      // 倍速只交给播放器：时间点存的是媒体时间轴，改语速绝不重新合成。
      await _engine.setRate(_speed);
      if (epoch != _epoch) return;
      _playing = true;
      _loading = false;
      // 开播成功后才起 BGM：失败路径不该有音乐单独响着。
      _syncBgm(play: true);
      _position = Duration.zero;
      _paragraphIndex = 0;
      // 同上：合成新章的时长事件来自 SpeechTimeline，位置流前统一清零。
      _duration = Duration.zero;
      _startSaveTimer();
      _rearmSleepForChapter();

      final startFromHead =
          explicitStart && startParagraph <= 0 && startRatio <= 0;
      final targetMs = resumeMs > 0
          ? resumeMs
          : (startParagraph > 0 || startRatio > 0)
          ? _startMsOf(product.timeline, startParagraph, startRatio)
          : startFromHead
          ? 0
          : (_store.entry(_bookId)?.positionMs ?? 0);
      if (targetMs > 0) {
        await _engine.seek(Duration(milliseconds: targetMs));
      }
      if (epoch != _epoch) return;
      // 开播这一刻就把词/句区间算好：首帧就有高亮，不用等第一个位置事件。
      _updateHighlight();
      notify();
    } on TtsException catch (e) {
      // `cancelled` 只是「这一代已经被切章/关闭作废」，新任务正在跑，不该报错。
      if (epoch != _epoch || e.code == TtsErrorCode.cancelled) return;
      _error = e.friendlyText;
      _loading = false;
      _playing = false;
      notify();
    } catch (e) {
      if (epoch != _epoch) return;
      _error = e;
      _loading = false;
      _playing = false;
      notify();
    }
  }

  /// 取正文并派生成朗读段落。**与阅读页同调 [deriveDisplayParagraphs]**：规则与
  /// 简繁模式都从注入的 store 现取，于是「朗读段数 == 屏幕段数」是结构性结论
  /// 而不是巧合（`listen-tts-contract.md` 已知偏差 CRITICAL-1 的修法）。
  /// store 没注入时退化成「无规则 + 不转换」，与改造前的行为逐项相等。
  Future<List<String>> _speechParagraphs(BookChapter chapter) async {
    final raw = await _api.chapterText(chapter.id);
    return deriveDisplayParagraphs(
      raw: raw,
      chapterTitle: chapter.title,
      rules: _rules?.forBook(_bookId) ?? const <ReplaceRule>[],
      convert: _settings?.value.convert ?? ChineseConvert.off,
    );
  }

  /// 拿这一章的音频产物：命中缓存则一次网络都不发；未命中才合成并成对落盘。
  Future<_TtsProduct> _produceChapterAudio({
    required BookChapter chapter,
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required int epoch,
  }) async {
    final engine = _tts;
    final cache = _cache;
    final voice = TtsVoice(
      id: _ttsVoiceId.isEmpty ? kEdgeFallbackVoice : _ttsVoiceId,
    );
    final key = TtsCacheKey(
      bookId: _bookId,
      chapterId: chapter.id,
      engineId: engine.id,
      // 音色进键（缓存键里没有倍速）：换音色必须重合成，改倍速不用；
      // 多角色时用计划签名，否则会命中单音色的旧产物。
      voiceId: _voiceIdFor(voice, await _rolePlanFor(voice)),
    );
    final signature = cache.signatureOf(paragraphs);
    final hit = await cache.lookup(
      key,
      textSignature: signature,
      extension: engine.caps.container,
    );
    if (hit != null) {
      return _TtsProduct(hit.audioPath, hit.timeline);
    }
    final composition = await _composeWithFallback(
      paragraphs: paragraphs,
      units: units,
      voice: voice,
      epoch: epoch,
    );
    if (epoch != _epoch) {
      throw TtsException(
        TtsErrorCode.cancelled,
        message: '合成结束时 requestIndex=$epoch 已过期',
      );
    }
    await cache.save(
      key,
      audio: composition.audio,
      timeline: composition.timeline,
      textSignature: signature,
      extension: engine.caps.container,
    );
    if (epoch != _epoch) {
      throw TtsException(
        TtsErrorCode.cancelled,
        message: '落盘结束时 requestIndex=$epoch 已过期',
      );
    }
    // 落盘后向缓存要路径：键的构成与有效性判定只有它知道，控制器不复制一份
    // 命名规则（重复一份就会和「成对删除」的语义打架）。
    final saved = await cache.lookup(
      key,
      textSignature: signature,
      extension: engine.caps.container,
    );
    if (saved == null) {
      throw const TtsException(
        TtsErrorCode.invalidCache,
        message: '合成产物落盘后校验未通过',
      );
    }
    return _TtsProduct(saved.audioPath, saved.timeline);
  }

  /// 合成整章；建连失败或 403（纠偏已无效）时换一个 preset **整章重试一次**。
  /// 重试只有一次：第二次失败直接抛，交给友好文案，不让端点漂移变成循环。
  Future<TtsComposition> _composeWithFallback({
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required TtsVoice voice,
    required int epoch,
  }) async {
    try {
      return await _composeOnce(
        paragraphs: paragraphs,
        units: units,
        voice: voice,
        epoch: epoch,
      );
    } on TtsException catch (e) {
      if (e.code == TtsErrorCode.cancelled || !_isEndpointDrift(e)) rethrow;
      final current = _tts;
      final next = _ttsEngineFallback(current, _ttsProxy);
      if (next == null) rethrow;
      _ttsEngine = next;
      // 换引擎 = 合成产物键变化：去重集必须与缓存一起失效（design §3）。
      _prefetcher.invalidate();
      await current.dispose();
      // `dispose()` 也是一个 await：期间用户可能已切章/切音色。旧代的降级结果
      // 必须在此作废，否则会白跑一整章的合成。
      if (epoch != _epoch) {
        throw const TtsException(TtsErrorCode.cancelled, message: '降级重试前请求已过期');
      }
      return _composeOnce(
        paragraphs: paragraphs,
        units: units,
        voice: voice,
        epoch: epoch,
      );
    }
  }

  Future<TtsComposition> _composeOnce({
    required List<String> paragraphs,
    required List<SpeechUnit> units,
    required TtsVoice voice,
    required int epoch,
  }) async {
    final plan = await _rolePlanFor(voice);
    return _ttsComposer.composeChapter(
      engine: _tts,
      paragraphs: paragraphs,
      voice: voice,
      voiceFor: _voiceResolver(units, plan),
      epoch: epoch,
      units: units,
      // 取消语义交给编排层：它在每个 await 之后都判一次世代，切章即中止。
      isCurrent: (value) => value == _epoch,
      trimSilence: trimSilenceEnabled,
      // 块级进度：只驱动「等待可预期」，不参与任何时间点 / 缓存决策。
      onProgress: (done, total) {
        if (epoch != _epoch) return;
        _synthDone = done;
        _synthTotal = total;
        notify();
      },
      concurrency: ttsConcurrency,
    );
  }

  /// 只有「端点/凭据被拒」和「连不上」值得换端点；限流与内容问题重试也没用。
  static bool _isEndpointDrift(TtsException e) =>
      e.code == TtsErrorCode.authRejected || e.code == TtsErrorCode.transport;

  /// 朗读起点：段落对得上就按段内比例细分，对不上退回段起点。
  int _startMsOf(SpeechPositions positions, int paragraphIndex, double ratio) {
    final table = positions is SpeechTimeline ? positions : null;
    if (table != null) {
      for (final p in table.paragraphs) {
        if (p.paragraphIndex != paragraphIndex) continue;
        return (p.startMs + (p.endMs - p.startMs) * ratio.clamp(0.0, 1.0))
            .round();
      }
    }
    return positions.startMsOfParagraph(
      paragraphIndex,
      paragraphCount: _paragraphCount,
    );
  }

  /// 懒建合成引擎：`main.dart` 不注入任何东西，测试用构造参数换掉它。
  SpeechEngine get _tts => _ttsEngine ??= _buildTtsEngine();

  /// 按设置构建合成引擎。
  ///
  /// `http` + 源配置合法 → 第三方 HTTP 源；否则（含配置写错、未配置）**回退 Edge**
  /// —— 宁可让用户还能听，也不要因为一段 JSON 写错导致整本书不能听。
  SpeechEngine _buildTtsEngine() {
    // Windows 本机离线语音：不依赖网络，但需要本机安装语音引擎（没装则由
    // `isAvailable()` / `notConfigured` 如实告知，不会静默降级）。
    if (_ttsEngineId == kWindowsSpeechEngineId) {
      return WindowsSpeechEngine();
    }
    final prefs = _prefs;
    // Piper 离线：自备可执行文件 + 模型；**没配好就回退 Edge**（宁可降级，
    // 不要因为路径写错把整本书听挂）。
    if (_ttsEngineId == kPiperEngineId && prefs != null) {
      final settings = ReaderListenSettings(prefs);
      final exe = settings.piperExe;
      final model = settings.piperModel;
      if (exe.isNotEmpty && model.isNotEmpty) {
        return PiperSpeechEngine(executable: exe, model: model);
      }
    }
    if (_ttsEngineId == kHttpTtsEngineId && prefs != null) {
      // 多源：用列表里**当前选中**的那条（选中项失效时 store 会回落第一条）。
      final source = TtsSourceStore(prefs).active;
      if (source != null) {
        return HttpTtsEngine(source: source, proxy: _ttsProxy);
      }
    }
    return EdgeSpeechEngine(proxy: _ttsProxy);
  }

  TtsCache get _cache => _ttsCache ??= TtsCache(quotaMb: _ttsQuotaMb);

  void _startSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_saveProgress()),
    );
  }

  /// 听书进度只写 [ListenProgressStore]：与阅读进度两份文件互不覆盖
  /// （reader-paging-contract.md §9.4）。TTS 与音轨两条链路的 `positionMs`
  /// 同为媒体时间轴，可以互用。
  Future<void> _saveProgress() async {
    if (_bookId.isEmpty) return;
    final chapter = currentChapter;
    if (chapter == null) return;
    final pos = _position;
    if (pos == _lastSaved) return;
    _lastSaved = pos;
    try {
      await _store.record(
        bookId: _bookId,
        title: _bookTitle,
        coverUrl: _coverUrl,
        chapterId: chapter.id,
        chapterTitle: chapter.title,
        chapterIndex: _chapterIndex,
        chapters: _chapters.length,
        toneId: _tone?.id ?? 0,
        positionMs: pos.inMilliseconds,
      );
    } catch (_) {}
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 留实例不留快照：`listen.granularity` 这类显示偏好要现取才即时生效。
      _prefs = prefs;
      // 语速：按书优先，回落全局 —— 老键继续服务「新书默认值」。
      _speed =
          (prefs.getDouble(ReaderListenSettings.speedKeyOf(_bookId)) ??
                  prefs.getDouble(speedKey) ??
                  _speed)
              .clamp(0.5, 3.0);
      _autoNext = prefs.getBool(autoNextKey) ?? _autoNext;
      // 缺键按默认值：`listen.tts.enabled` 只有显式关掉才回滚（design.md §8）。
      _ttsEnabled = prefs.getBool(ttsEnabledKey) ?? true;
      _ttsVoiceId = prefs.getString(ttsVoiceKey) ?? '';
      _ttsProxy = prefs.getString(ttsProxyKey) ?? '';
      _ttsEngineId = prefs.getString(ttsEngineKey) ?? kDefaultTtsEngineId;
      // 旧单源配置一次性搬进多源列表（已迁移过则无操作）。
      await TtsSourceStore(prefs).ensureMigrated();
      _ttsQuotaMb = prefs.getInt(ttsQuotaKey) ?? _ttsQuotaMb;
      // 定时恢复：只在当前未武装时按 prefs 武装。sameSession 复进本页也会走
      // 到这里，进行中的定时不能被重置回满时长；fire 后组件与 prefs 都已落回
      // off，不会跨会话复活。
      if (_sleep.mode == SleepMode.off) {
        final listen = ReaderListenSettings(prefs);
        final saved = listen.sleepMode;
        if (saved == SleepMode.minutes) {
          // 用“剩余快照”恢复：只读 minutes 会把已经听过的时间又送回去。
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
    } catch (_) {}
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 两个都写：按书键保证回书恢复，全局键作为新书的默认语速。
      await prefs.setDouble(speedKey, _speed);
      if (_bookId.isNotEmpty) {
        await prefs.setDouble(
          ReaderListenSettings.speedKeyOf(_bookId),
          _speed,
        );
      }
      await prefs.setBool(autoNextKey, _autoNext);
    } catch (_) {}
  }
}

/// 一章的合成产物：可播放的本地文件 + 它对应的时间点表。
class _TtsProduct {
  const _TtsProduct(this.audioPath, this.timeline);

  final String audioPath;
  final SpeechTimeline timeline;
}
