/// 朗读流式合成的**会话**（`11-02-listen-tts-streaming` S3.2 接线零件）。
///
/// 职责边界：只管「一章的单元怎么按需产出、按什么顺序交给播放器、章内毫秒怎么
/// 换算到单元内毫秒」。**不碰播放器**（切段由控制器发起 open），也不碰引擎
/// （合成由注入的 [UnitComposer] 完成）。
///
/// 为什么单元要自己合并而不是直接用 `produceUnits`：播放器的进度/高亮真值是
/// 「章内毫秒」，而 `UnitProduct` 只带字节、没有时间轴；这里用 `TtsComposer`
/// 逐单元合成，才能拿到每单元的词/句点并拼成章内时间表（否则流式一开就丢高亮）。
library;

import 'dart:async';
import 'dart:convert';

import '../../tts/tts_composer.dart';
import '../../tts/tts_models.dart';
import '../../tts/tts_unit_cache.dart';
import 'speech_unit.dart';

/// 一个单元的合成回调：入参是**章内坐标**的单元，返回该单元的产物。
typedef UnitComposer = Future<TtsComposition> Function(SpeechUnit unit);

/// 一个单元已可播放的产物。
class StreamingUnitAudio {
  const StreamingUnitAudio({
    required this.index,
    required this.path,
    required this.durationMs,
  });

  final int index;

  /// 本地文件路径（章目录里的 `u000.mp3`）。
  final String path;

  /// 单元音频时长（毫秒）。章内偏移由它累加，**不用**播放器实测值。
  final int durationMs;
}

/// 章内定位结果：第几个单元 + 单元内毫秒。
typedef UnitLocation = ({int index, int msInUnit});

/// 把段落切成「合成单元」：同段内相邻句子合并到 ≥ [minChars]，单段不跨段合并。
///
/// 不跨段是硬约束：合并后的时间点只能归到**一个** paragraphIndex，跨段合并会让
/// 段级高亮/跟随退化成「整块都算第一段」。同段合并只影响请求数，不影响坐标。
List<SpeechUnit> mergeSpeechUnits(
  List<String> paragraphs, {
  int minChars = 120,
  int maxChars = 600,
}) {
  final base = splitSpeechUnits(paragraphs);
  if (base.isEmpty) return const <SpeechUnit>[];
  final plain = chapterPlainText(paragraphs);
  final out = <SpeechUnit>[];
  var group = <SpeechUnit>[];

  void flush() {
    if (group.isEmpty) return;
    final start = group.first.charStart;
    final end = group.last.charEnd;
    out.add(
      SpeechUnit(
        index: out.length,
        paragraphIndex: group.first.paragraphIndex,
        charStart: start,
        charEnd: end,
        text: plain.substring(start, end),
      ),
    );
    group = <SpeechUnit>[];
  }

  for (final unit in base) {
    if (group.isNotEmpty) {
      final sameParagraph = unit.paragraphIndex == group.last.paragraphIndex;
      final mergedChars = unit.charEnd - group.first.charStart;
      final currentChars = group.last.charEnd - group.first.charStart;
      // 已够长就断开；合并后超上限也断开（单次请求体太大同样会超时）。
      if (sameParagraph && currentChars < minChars && mergedChars <= maxChars) {
        group.add(unit);
        continue;
      }
      flush();
    }
    group.add(unit);
  }
  flush();
  return out;
}

/// 一章的流式朗读会话。
///
/// 生命周期：`open()`（建目录 + 读整章缓存）→ `ensure(i)` 按需产出 → 播完
/// `finish`（写 index.json）。被切章/关闭作废时 `cancel()`，未写完的章目录没有
/// index.json，会被 `TtsUnitCache.pruneOrphans` 在下次启动清掉。
class StreamingTtsSession {
  StreamingTtsSession._(
    this._cache,
    this._chapter,
    this.units,
    this.granularity,
    this._compose,
    this._onChanged,
  ) : _paths = List<String?>.filled(units.length, null),
      _durationMs = List<int>.filled(units.length, 0),
      _timelines = List<SpeechTimeline?>.filled(units.length, null);

  /// 打开一章：切单元、建目录、整章命中则直接填满。
  ///
  /// 缓存命中时不发一次网络请求，`ensure` 全部同步返回路径。
  static Future<StreamingTtsSession> open({
    required TtsUnitCache cache,
    required TtsUnitKey key,
    required List<String> paragraphs,
    required String textSignature,
    required String extension,
    required SpeechGranularity granularity,
    required UnitComposer compose,
    void Function()? onChanged,
    int minChars = 120,
    int maxChars = 600,
  }) async {
    final units = mergeSpeechUnits(
      paragraphs,
      minChars: minChars,
      maxChars: maxChars,
    );
    if (units.isEmpty) {
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: '本章没有可朗读的正文',
      );
    }
    final chapter = await cache.openChapter(
      key,
      unitCount: units.length,
      textSignature: textSignature,
      extension: extension,
    );
    final session = StreamingTtsSession._(
      cache,
      chapter,
      units,
      granularity,
      compose,
      onChanged,
    );
    final hit = await cache.lookup(
      key,
      textSignature: textSignature,
      extension: extension,
    );
    if (hit != null && hit.units.length == units.length) {
      session._adoptHit(hit);
    }
    return session;
  }

  final TtsUnitCache _cache;
  final TtsChapterUnits _chapter;
  final UnitComposer _compose;
  final void Function()? _onChanged;

  /// 合成单元（章内字符坐标；同段内已合并）。
  final List<SpeechUnit> units;

  /// 引擎声明的精度（词/句/段），拼章内时间表时原样带出。
  final SpeechGranularity granularity;

  final List<String?> _paths;
  final List<int> _durationMs;
  final List<SpeechTimeline?> _timelines;
  final Map<int, Future<StreamingUnitAudio>> _inflight =
      <int, Future<StreamingUnitAudio>>{};

  int _index = 0;
  bool _cancelled = false;
  bool _finishRequested = false;

  int get unitCount => units.length;
  int get index => _index;
  bool get isCancelled => _cancelled;
  bool get hasNext => _index + 1 < unitCount;

  /// 当前单元在整章里的起点（毫秒）。
  int get currentStartMs => startOf(_index);

  /// 当前单元时长（毫秒）。未知（尚未产出）时为 0。
  int get currentDurationMs =>
      _index >= 0 && _index < unitCount ? _durationMs[_index] : 0;

  /// 已连续产出的总时长：时间轴/进度条只认这一段（后面还是未知）。
  int get totalKnownMs => startOf(_contiguousKnown());

  /// 已连续产出的单元数（用于「正在合成 x / y 段」）。
  int get producedCount => _contiguousKnown();

  void moveTo(int index) =>
      _index = index.clamp(0, unitCount > 0 ? unitCount - 1 : 0);

  /// 第 [index] 个单元在整章里的起点。未产出的按已知时长累加（缺的记 0）。
  int startOf(int index) {
    var total = 0;
    final end = index.clamp(0, unitCount);
    for (var i = 0; i < end; i++) {
      total += _durationMs[i];
    }
    return total;
  }

  /// 作废本次会话：不再发起合成，已发出的结果直接丢弃。
  void cancel() => _cancelled = true;

  /// 取第 [index] 个单元的音频；未产出则现场合成（同一单元只发一次请求）。
  Future<StreamingUnitAudio> ensure(int index) {
    final known = _knownAt(index);
    if (known != null) return Future<StreamingUnitAudio>.value(known);
    final running = _inflight[index];
    if (running != null) return running;
    final future = _produce(index);
    _inflight[index] = future;
    return future;
  }

  /// 预取下一单元（播到 70% 或当前单元刚就绪时调用）。失败静默。
  void prefetchNext() => _kick(_index + 1);

  /// 按章内毫秒定位到「单元 + 单元内毫秒」。
  ///
  /// 只向后推进到目标所在单元：命中缓存时零网络；未命中时与整章合成同一量级
  /// （要等前面的单元产出才知道边界），但**不会**白合成目标之后的单元。
  Future<UnitLocation> locateChapterMs(int chapterMs) async {
    if (chapterMs <= 0) return (index: 0, msInUnit: 0);
    var acc = 0;
    for (var i = 0; i < unitCount; i++) {
      final audio = await ensure(i);
      if (chapterMs < acc + audio.durationMs || i == unitCount - 1) {
        final local = (chapterMs - acc).clamp(0, audio.durationMs);
        return (index: i, msInUnit: local);
      }
      acc += audio.durationMs;
    }
    return (index: unitCount - 1, msInUnit: 0);
  }

  /// 某段落在整章里的起点毫秒（[ratio] 为段内比例）。
  ///
  /// 优先用该单元时间表里的段级点；拿不到时退到「单元起点 + 单元时长 × 比例」。
  Future<int> chapterMsOfParagraph(int paragraphIndex, {double ratio = 0}) async {
    var target = 0;
    for (var i = 0; i < unitCount; i++) {
      if (units[i].paragraphIndex <= paragraphIndex) {
        target = i;
      } else {
        break;
      }
    }
    var start = 0;
    for (var i = 0; i < target; i++) {
      start += (await ensure(i)).durationMs;
    }
    final audio = await ensure(target);
    final clamped = ratio.clamp(0.0, 1.0);
    final timeline = _timelines[target];
    if (timeline != null) {
      for (final p in timeline.paragraphs) {
        if (p.paragraphIndex != paragraphIndex) continue;
        return start + (p.startMs + (p.endMs - p.startMs) * clamped).round();
      }
    }
    return start + (audio.durationMs * clamped).round();
  }

  /// 把已产出的单元时间轴拼成**章内坐标系**的时间表。
  ///
  /// 只拼连续已知前缀：时间轴必须是单调的，跳过中间缺失的单元会让高亮跳变。
  SpeechTimeline get positions {
    final words = <SpeechPoint>[];
    final sentences = <SpeechPoint>[];
    final paragraphs = <ParagraphTiming>[];
    var offset = 0;
    for (var i = 0; i < unitCount; i++) {
      final timeline = _timelines[i];
      if (timeline == null) break;
      for (final w in timeline.words) {
        words.add(
          SpeechPoint(
            startMs: w.startMs + offset,
            endMs: w.endMs + offset,
            charStart: w.charStart,
            charEnd: w.charEnd,
            unitIndex: w.unitIndex,
            text: w.text,
          ),
        );
      }
      for (final s in timeline.sentences) {
        sentences.add(
          SpeechPoint(
            startMs: s.startMs + offset,
            endMs: s.endMs + offset,
            charStart: s.charStart,
            charEnd: s.charEnd,
            unitIndex: s.unitIndex,
          ),
        );
      }
      for (final p in timeline.paragraphs) {
        paragraphs.add(
          ParagraphTiming(
            paragraphIndex: p.paragraphIndex,
            charStart: p.charStart,
            charEnd: p.charEnd,
            startMs: p.startMs + offset,
            endMs: p.endMs + offset,
          ),
        );
      }
      offset += _durationMs[i];
    }
    return SpeechTimeline(
      granularity: granularity,
      audioMs: offset,
      words: words,
      sentences: sentences,
      paragraphs: paragraphs,
    );
  }

  // ---------- 内部 ----------

  int _contiguousKnown() {
    var n = 0;
    while (n < unitCount && _paths[n] != null) {
      n++;
    }
    return n;
  }

  StreamingUnitAudio? _knownAt(int index) {
    if (index < 0 || index >= unitCount) return null;
    final path = _paths[index];
    if (path == null) return null;
    return StreamingUnitAudio(
      index: index,
      path: path,
      durationMs: _durationMs[index],
    );
  }

  Future<StreamingUnitAudio> _produce(int index) async {
    if (_cancelled) {
      throw const TtsException(
        TtsErrorCode.cancelled,
        message: '会话已作废，不再合成新单元',
      );
    }
    try {
      final composition = await _compose(units[index]);
      if (_cancelled) {
        throw const TtsException(
          TtsErrorCode.cancelled,
          message: '单元合成完成时会话已作废',
        );
      }
      final durationMs = composition.audioMsFromBytes > 0
          ? composition.audioMsFromBytes
          : composition.timeline.audioMs;
      await _cache.writeUnit(
        _chapter,
        index,
        composition.audio,
        durationMs: durationMs,
        timelineJson: jsonEncode(composition.timeline.toJson()),
      );
      _paths[index] = _chapter.unitFile(index).path;
      _durationMs[index] = durationMs;
      _timelines[index] = composition.timeline;
      _inflight.remove(index);
      _maybeFinish();
      _onChanged?.call();
      // 当前单元一就绪就把下一单元排队：这是「切段不空档」的主抓手。
      _kick(index + 1);
      return StreamingUnitAudio(
        index: index,
        path: _paths[index]!,
        durationMs: durationMs,
      );
    } catch (_) {
      _inflight.remove(index);
      rethrow;
    }
  }

  /// 后台预取：失败静默（预取失败不该把正在播的章打断）。
  void _kick(int index) {
    if (_cancelled || index < 0 || index >= unitCount) return;
    if (_paths[index] != null || _inflight.containsKey(index)) return;
    unawaited(
      ensure(index).then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  void _maybeFinish() {
    if (_finishRequested) return;
    if (_contiguousKnown() < unitCount) return;
    _finishRequested = true;
    unawaited(
      _cache.finish(_chapter).then<void>(
        (_) {},
        // index.json 写失败只是「下次不命中」，音频本身还能播，不打断会话。
        onError: (Object _, StackTrace _) {},
      ),
    );
  }

  void _adoptHit(TtsChapterHit hit) {
    for (final unit in hit.units) {
      final i = unit.index;
      if (i < 0 || i >= unitCount) continue;
      _paths[i] = unit.audioPath;
      _durationMs[i] = unit.durationMs;
      final raw = unit.timelineJson;
      if (raw.isEmpty) continue;
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          _timelines[i] = SpeechTimeline.fromJson(json);
        }
      } catch (_) {
        // 时间轴坏了不致命：音频齐全还能播，只是这一段没有词级高亮。
      }
    }
  }
}
