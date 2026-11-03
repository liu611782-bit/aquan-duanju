/// 编排层：朗读单元 → 逐段合成 → 字节清洗拼接 → 累计偏移注入 → 整章时间点表。
///
/// 三件事只在这里做（引擎一律不做）：
/// 1. **累计偏移**：引擎只知道自己是第几段，只有拼接者知道前面已经落了多少字节；
///    所以 `offsetBaseMs` 由这里注入，且时长一律用**清洗后的字节数**换算，
///    不用各段自报时长求和（自报值含容器头与块间缝隙，章节越长偏得越多）。
/// 2. **容器清洗**：逐段剔除 ID3v2 与首帧 Xing/Info，只保留 MPEG 音频帧后按序拼接
///    （见 `mp3_frames.dart`）。
/// 3. **世代丢弃**：每个 await 之后都确认请求仍属于当前 epoch，迟到的段结果直接抛
///    `cancelled`，不写进已拼接的结果。
library;

import 'dart:typed_data';

import '../reader/speech/speech_unit.dart';
import 'mp3_frames.dart';
import 'silence_trim.dart';
import 'speech_engine.dart';
import 'tts_models.dart';

/// 一次整章合成的产物。
class TtsComposition {
  const TtsComposition({
    required this.audio,
    required this.timeline,
    required this.bitrateKbps,
    required this.chunkCount,
    required this.audioMsFromBytes,
  });

  /// 整章 mp3（只剩 MPEG 帧，可直接落盘给播放器）。
  final Uint8List audio;

  /// 整章时间点表，精度位取自引擎能力。
  final SpeechTimeline timeline;

  /// 字节 ↔ 毫秒换算使用的码率。
  final int bitrateKbps;

  /// 发起过几次引擎请求（诊断与限流预算用）。
  final int chunkCount;

  /// 由总字节数换算出的时长。`timeline.audioMs` 取它与末点 `endMs` 的较大者，
  /// 这里保留字节口径的原值，便于上层做「时间点总长 vs 播放器 duration」自校验。
  final int audioMsFromBytes;

  int get bytes => audio.length;
}

/// 一次请求里聚合的连续单元。
class _Chunk {
  _Chunk(this.charStart);

  /// 该 chunk 在章内字符坐标系里的起点（= 首个 unit 的 charStart）。
  final int charStart;
  final List<SpeechUnit> units = <SpeechUnit>[];

  int get charEnd => units.isEmpty ? charStart : units.last.charEnd;
}

class TtsComposer {
  TtsComposer({this.maxChunkChars = kTtsMaxChunkChars});

  /// 单次请求的文本上限（字符数）。超限只能在 unit 边界封块。
  final int maxChunkChars;

  /// 合成一整章。
  ///
  /// [paragraphs] 必须是阅读页**已清洗**的段落（`_displayParagraphs`）：这里不再做
  /// 第二轮清洗，否则朗读文本 ≠ 阅读文本，坐标就会串位。
  /// [units] 允许调用方复用已切好的单元（控制器切段与进度都要用它）。
  /// [epoch] 与 [isCurrent] 是取消语义的接缝：`isCurrent(epoch)` 返回 false 即中止，
  /// 已拼好的字节也随之作废（调用方丢弃本次结果即可，不留半成品）。
  Future<TtsComposition> composeChapter({
    required SpeechEngine engine,
    required List<String> paragraphs,
    required TtsVoice voice,
    /// 多角色：按单元解析音色（为空则全章用 [voice]）。
    TtsVoice Function(SpeechUnit unit)? voiceFor,
    required int epoch,
    List<SpeechUnit>? units,
    bool Function(int epoch)? isCurrent,
    /// 段首尾静音裁剪（默认开）。关掉即回到「原样拼接」的老行为，
    /// 缓存键需随开关切换（由调用方保证）。
    bool trimSilence = true,

    /// 段尾保留的静音毫秒（默认 160，整章拼接路径的既有行为）。
    ///
    /// 流式播放每个单元都要换一次媒体，播放器在切点会丢弃音频缓冲区的尾部；
    /// 调用方传更大的余量，切点就**结构性地**落在静音里，不会吃掉最后一个字。
    int tailKeepMs = 160,

    /// 合成进度回调（done, total）：每完成一块回调一次。
    ///
    /// 存在的目的只有一个 —— 把「点下去后黑等十几秒」变成可预期的等待。
    /// 预取路径**不要**传（后台任务不该驱动 UI 进度）。
    void Function(int done, int total)? onProgress,

    /// 章内并发度。默认为播放路径服务（[kTtsDefaultConcurrency]）；
    /// **预取路径必须传 1**：后台任务不能与播放抢 Edge 的连接配额。
    int concurrency = kTtsDefaultConcurrency,
  }) async {
    // 「无音频文件」的实现（未来的系统 TTS）不能进这条链路：它给不出可 seek 的
    // 字节，也拿不到时间点，硬接会把缺陷当设计兼容。
    if (!engine.caps.producesFile) {
      throw TtsException(
        TtsErrorCode.unsupportedEngine,
        message: 'engine=${engine.id} producesFile=false',
      );
    }
    final chapterText = chapterPlainText(paragraphs);
    final speakUnits = units ?? splitSpeechUnits(paragraphs);
    if (speakUnits.isEmpty) {
      throw const TtsException(
        TtsErrorCode.emptyAudio,
        message: '没有可合成的朗读单元（正文为空？）',
      );
    }
    // 精度以引擎声明的为准：默认由 wordBoundary 推导，特殊引擎可显式降级（如 Piper＝段）。
    final granularity = engine.caps.effectiveGranularity;
    final builder = SpeechTimelineBuilder(
      units: speakUnits,
      granularity: granularity,
    );
    final chunks = _groupChunks(speakUnits, chapterText, voiceFor);
    final bytes = BytesBuilder(copy: false);
    var baseMs = 0;
    var bitrateKbps = kTtsMp3BitrateKbps;
    var lastEndMs = 0;
    // 容器无关：mp3 走帧清洗 + CBR 字节换算；其他容器（wav/pcm）原样拼接，
    // 时长一律以引擎自报为准（无帧头可用来推算）。
    var allMp3 = true;
    var reportedMs = 0;

    // 取段两路径：
    // - 串行（concurrency<=1）：保持「边取边拼」，与改造前逐字节一致；
    // - 并行：先把所有块取齐（每块 offsetBaseMs=0），再按顺序消费 —— 并行时
    //   前序块的字节数未知，累计偏移只能等消费阶段由 _timeShift 补。
    List<TtsSegment?>? prefetched;
    if (concurrency > 1 && chunks.length > 1) {
      try {
        prefetched = await _synthesizeAll(
          engine: engine,
          chunks: chunks,
          chapterText: chapterText,
          voice: voice,
          voiceFor: voiceFor,
          epoch: epoch,
          concurrency: concurrency,
          isCurrent: isCurrent,
          onProgress: onProgress,
        );
      } on TtsException catch (e) {
        // 并发把配额撞了：降到串行再跑一遍。用户等的是结果，不是「聪明」。
        // 其他错误（空音频/取消）立即上抛，重跑只会更慢。
        if (e.code != TtsErrorCode.rateLimited) rethrow;
        _requireCurrent(isCurrent, epoch);
        prefetched = null;
      }
    }

    for (var i = 0; i < chunks.length; i++) {
      _requireCurrent(isCurrent, epoch);
      final chunk = chunks[i];
      // 多角色：每个块用「首单元解析出的音色」。分块时已按音色断开，
      // 所以块内音色唯一。
      final chunkVoice = voiceFor?.call(chunk.units.first) ?? voice;
      final TtsSegment segment;
      if (prefetched != null) {
        segment = prefetched[i]!;
      } else {
        segment = await engine.synthesize(
          SpeechJob(
            text: chapterText.substring(chunk.charStart, chunk.charEnd),
            voice: chunkVoice,
            // 引擎不自己算累计：前面每段贡献的毫秒数在这里累加后注入。
            offsetBaseMs: baseMs,
            requestIndex: epoch,
          ),
        );
        // await 之后才判定世代：切章时这段结果照样会回来，但不许污染已拼接的结果。
        _requireCurrent(isCurrent, epoch);
        onProgress?.call(i + 1, chunks.length);
      }

      final isMp3 = segment.container == 'mp3';
      var clean = segment.audio;
      final int segmentMs;
      // 段首被裁掉的毫秒：该段所有时间点要整体前移这么多。
      var headTrimMs = 0;
      if (isMp3) {
        clean = extractMp3AudioFrames(segment.audio);
        if (clean.isEmpty) {
          throw TtsException(
            TtsErrorCode.emptyAudio,
            message: 'engine=${engine.id} chunk=$i 清洗后没有音频帧',
          );
        }
        bitrateKbps = segment.bitrateKbps > 0
            ? segment.bitrateKbps
            : kTtsMp3BitrateKbps;
        // 段首尾静音：词级时间点告诉了我们语音边界，按整帧裁掉多余空白。
        // 时间点平移放在 _absorb 里统一做（-headTrimMs）。
        if (trimSilence) {
          final trim = _trimSilence(
            clean,
            segment.points,
            baseMs,
            bitrateKbps,
            tailKeepMs: tailKeepMs,
          );
          if (trim.trimmed) {
            clean = trim.audio;
            headTrimMs = trim.headMs;
          }
        }
        // 本段时长 = 清洗后帧的字节时长（48kbps 即 bytes / 6）。
        segmentMs = mp3BytesToMs(clean.length, bitrateKbps: bitrateKbps);
      } else {
        allMp3 = false;
        clean = segment.audio;
        // 非 mp3 没有帧结构可推算，**必须**由引擎自报时长：没有它就无法给后续段
        // 注入 offsetBase，猜一个只会让整章时间点漂移 —— 宁可报错。
        if (segment.audioMs <= 0) {
          throw TtsException(
            TtsErrorCode.emptyAudio,
            message:
                'engine=${engine.id} chunk=$i 非 mp3 但未自报 audioMs（container=${segment.container}）',
          );
        }
        segmentMs = segment.audioMs;
      }
      final segmentEndMs = _absorb(
        builder,
        chunk,
        segment,
        baseMs,
        extraShiftMs: -headTrimMs,
      );
      bytes.add(clean);
      reportedMs += segmentMs;
      baseMs += segmentMs;
      if (segmentEndMs > lastEndMs) lastEndMs = segmentEndMs;
    }

    final audio = bytes.toBytes();
    // mp3 用字节换算（与拼接后的实际时间轴天然一致）；其他容器用各段自报之和。
    final audioMs = allMp3
        ? mp3BytesToMs(audio.length, bitrateKbps: bitrateKbps)
        : reportedMs;
    builder.audioMs = audioMs > lastEndMs ? audioMs : lastEndMs;
    final timeline = builder.build();
    if (timeline.isEmpty) {
      throw TtsException(
        TtsErrorCode.emptyAudio,
        message: 'engine=${engine.id} 没有返回任何时间点（协议漂移？）',
      );
    }
    return TtsComposition(
      audio: audio,
      timeline: timeline,
      bitrateKbps: bitrateKbps,
      chunkCount: chunks.length,
      audioMsFromBytes: audioMs,
    );
  }

  /// 并发取齐所有块（滑动窗口）。
  ///
  /// 每块 `offsetBaseMs = 0`：并行时前序块的字节数**未知**，累计偏移只能等消费
  /// 阶段由 [_timeShift] 补齐（它本就兼容“引擎没加 offset”的情况）。
  ///
  /// 错误立即上抛（`eagerError`）：一块失败就没必要再等其它块跑完。
  Future<List<TtsSegment?>> _synthesizeAll({
    required SpeechEngine engine,
    required List<_Chunk> chunks,
    required String chapterText,
    required TtsVoice voice,
    TtsVoice Function(SpeechUnit unit)? voiceFor,
    required int epoch,
    required int concurrency,
    bool Function(int epoch)? isCurrent,
    void Function(int done, int total)? onProgress,
  }) async {
    final results = List<TtsSegment?>.filled(chunks.length, null);
    var nextIndex = 0;
    var done = 0;
    var failed = false;

    Future<void> worker() async {
      while (!failed) {
        final index = nextIndex++;
        if (index >= chunks.length) return;
        try {
          _requireCurrent(isCurrent, epoch);
          final chunk = chunks[index];
          final segment = await engine.synthesize(
            SpeechJob(
              text: chapterText.substring(chunk.charStart, chunk.charEnd),
              voice: voiceFor?.call(chunk.units.first) ?? voice,
              offsetBaseMs: 0,
              requestIndex: epoch,
            ),
          );
          _requireCurrent(isCurrent, epoch);
          results[index] = segment;
          done++;
          onProgress?.call(done, chunks.length);
        } catch (_) {
          // 置位后其它 worker 不再领新任务，避免失败后还继续烧配额。
          failed = true;
          rethrow;
        }
      }
    }

    final lanes = concurrency > chunks.length ? chunks.length : concurrency;
    await Future.wait<void>(
      List<Future<void>>.generate(lanes, (_) => worker()),
      eagerError: true,
    );
    return results;
  }

  void _requireCurrent(bool Function(int epoch)? isCurrent, int epoch) {
    if (isCurrent != null && !isCurrent(epoch)) {
      throw TtsException(
        TtsErrorCode.cancelled,
        message: 'requestIndex=$epoch 已过期',
      );
    }
  }

  /// 把 unit 聚成 chunk：只允许被**空白**隔开的相邻 unit 合并，且合并后不超上限。
  ///
  /// 于是 `job.text` 永远是章内明文的一个连续切片 —— 引擎返回的相对字符位可以整体
  /// 平移回章内绝对坐标，不需要插值或猜测。跨段落合并时中间那个 `'\n'` 本来就在原文
  /// 里：朗读不念它，但坐标必须留着（`speech_unit.dart` 的往返不变量）。
  List<_Chunk> _groupChunks(
    List<SpeechUnit> units,
    String chapterText,
    TtsVoice Function(SpeechUnit unit)? voiceFor,
  ) {
    final chunks = <_Chunk>[];
    _Chunk? current;
    String? currentVoiceId;
    for (final unit in units) {
      final candidate = current;
      final unitVoiceId = voiceFor?.call(unit).id;
      if (candidate != null && candidate.units.isNotEmpty) {
        final gap = chapterText.substring(candidate.charEnd, unit.charStart);
        final mergedChars = unit.charEnd - candidate.charStart;
        // 音色不同必须断开：一个块只能发一个 voice（引擎接口如此），
        // 合并了就只能用块首音色，后半句会被错误角色朗读。
        final sameVoice = unitVoiceId == currentVoiceId;
        if (gap.trim().isEmpty && sameVoice && mergedChars <= maxChunkChars) {
          candidate.units.add(unit);
          continue;
        }
      }
      current = _Chunk(unit.charStart)..units.add(unit);
      currentVoiceId = unitVoiceId;
      chunks.add(current);
    }
    return chunks;
  }

  /// 用段内相对时间点算裁剪量。
  ///
  /// 「相对」的口径必须与 [_absorb] 完全一致：引擎可能已加 `offsetBaseMs`，也可能
  /// 没加（[_timeShift] 判据）。两处用同一个 shift，词点才不会因为裁剪整体错位。
  Mp3SilenceTrim _trimSilence(
    Uint8List frames,
    List<SpeechPoint> points,
    int baseMs,
    int bitrateKbps, {
    int tailKeepMs = 160,
  }) {
    if (points.isEmpty) {
      return Mp3SilenceTrim(audio: frames, headMs: 0, tailMs: 0);
    }
    final shift = _timeShift(points, baseMs);
    var firstMs = points.first.startMs + shift - baseMs;
    var lastEndMs = points.first.endMs + shift - baseMs;
    for (final point in points) {
      final start = point.startMs + shift - baseMs;
      final end = point.endMs + shift - baseMs;
      if (start < firstMs) firstMs = start;
      if (end > lastEndMs) lastEndMs = end;
    }
    if (firstMs < 0) firstMs = 0;
    if (lastEndMs < firstMs) lastEndMs = firstMs;
    return trimMp3Silence(
      frames,
      firstSpeechMs: firstMs,
      lastSpeechEndMs: lastEndMs,
      bitrateKbps: bitrateKbps,
      tailKeepMs: tailKeepMs,
    );
  }

  /// 归一一个段的时间点并追加进时间表，返回本段最大的绝对 `endMs`。
  ///
  /// 契约（见 `speech_engine.dart`）：时间由引擎按 `offsetBaseMs` 平移、字符位相对
  /// `job.text`。漏做时间平移的引擎在这里补齐；字符位一律平移，越界则夹回本段范围，
  /// 保证坐标永远落在章内（违约的代价是可见的偏差，而不是把点撒到章外）。
  int _absorb(
    SpeechTimelineBuilder builder,
    _Chunk chunk,
    TtsSegment segment,
    int baseMs, {
    int extraShiftMs = 0,
  }) {
    final points = segment.points;
    final shiftMs = _timeShift(points, baseMs) + extraShiftMs;
    var maxEndMs = 0;
    for (final point in points) {
      var startMs = point.startMs + shiftMs;
      var endMs = point.endMs + shiftMs;
      // 裁掉段首静音后，首点可能落到 0 之前：媒体时间轴不存在负值，夹回来。
      if (startMs < 0) startMs = 0;
      if (endMs < startMs) endMs = startMs;
      final charStart = (chunk.charStart + point.charStart).clamp(
        chunk.charStart,
        chunk.charEnd,
      );
      final charEnd = (chunk.charStart + point.charEnd).clamp(
        charStart,
        chunk.charEnd,
      );
      builder.addWord(
        SpeechPoint(
          startMs: startMs,
          endMs: endMs,
          charStart: charStart,
          charEnd: charEnd,
          unitIndex: _unitIndexOf(chunk, charStart),
          text: point.text,
        ),
      );
      if (endMs > maxEndMs) maxEndMs = endMs;
    }
    return maxEndMs;
  }

  /// 「首点早于本段在整章中的起点」只可能是引擎忘了平移 —— 按此判据补齐，
  /// 因此两种写法都不会被双重平移。
  static int _timeShift(List<SpeechPoint> points, int baseMs) {
    if (baseMs <= 0 || points.isEmpty) return 0;
    var min = points.first.startMs;
    for (final point in points) {
      if (point.startMs < min) min = point.startMs;
    }
    return min < baseMs ? baseMs : 0;
  }

  /// 时间点落在哪个 unit：最后一个 `charStart <= 位置` 的 unit（unit 坐标递增）。
  int _unitIndexOf(_Chunk chunk, int charPosition) {
    if (chunk.units.isEmpty) return 0;
    var index = chunk.units.first.index;
    for (final unit in chunk.units) {
      if (unit.charStart > charPosition) break;
      index = unit.index;
    }
    return index;
  }
}
