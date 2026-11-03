import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/mp3_frames.dart';
import 'package:aquan_duanju/core/tts/silence_trim.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造 [count] 个合法 MPEG-2 Layer III 48kbps / 24kHz 帧：每帧 144 字节 = 24ms。
/// 与 `mp3_concat_test.dart` 同一套参数（Edge 输出即此规格）。
Uint8List frames(int count) {
  final out = Uint8List(count * 144);
  for (var f = 0; f < count; f++) {
    final o = f * 144;
    out[o] = 0xFF;
    out[o + 1] = 0xF3;
    out[o + 2] = 0x64;
    out[o + 3] = 0x40;
    for (var j = 4; j < 144; j++) {
      out[o + j] = 0x20 + (j % 60);
    }
  }
  return out;
}

const int _frameBytes = 144;
const int _frameMs = 24;

/// 段首 [leadMs] 静音、段尾 [tailMs] 静音的假引擎：时间点严格按契约加 offsetBase。
class _PaddedEngine implements SpeechEngine {
  _PaddedEngine({required this.leadMs, required this.tailMs});

  final int leadMs;
  final int tailMs;
  static const int frameCount = 50;

  final List<SpeechJob> jobs = <SpeechJob>[];

  @override
  String get id => 'edge';

  @override
  TtsCaps get caps => const TtsCaps(wordBoundary: true);

  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    jobs.add(job);
    await Future<void>.delayed(Duration.zero);
    final totalMs = frameCount * _frameMs;
    final start = job.offsetBaseMs + leadMs;
    final end = job.offsetBaseMs + totalMs - tailMs;
    final text = job.text;
    final points = <SpeechPoint>[
      SpeechPoint(
        startMs: start,
        endMs: start + 100,
        charStart: 0,
        charEnd: 1,
        unitIndex: 0,
        text: text.isEmpty ? '' : text[0],
      ),
      SpeechPoint(
        startMs: end - 100,
        endMs: end,
        charStart: text.length > 1 ? text.length - 1 : 0,
        charEnd: text.length,
        unitIndex: 0,
        text: text.isEmpty ? '' : text[text.length - 1],
      ),
    ];
    return TtsSegment(
      audio: frames(frameCount),
      points: points,
      audioMs: totalMs,
    );
  }
}

const TtsVoice _voice = TtsVoice(id: 'zh-CN-XiaoxiaoNeural');

Future<TtsComposition> _compose(
  SpeechEngine engine, {
  bool trimSilence = true,
  int tailKeepMs = 160,
}) => TtsComposer().composeChapter(
  engine: engine,
  paragraphs: const <String>['你好世界'],
  voice: _voice,
  epoch: 1,
  trimSilence: trimSilence,
  tailKeepMs: tailKeepMs,
);

void main() {
  group('mp3FrameOffsetAtOrAfterMs', () {
    test('向上取整到帧边界', () {
      final bytes = frames(10); // 240ms
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 0), 0);
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 1), _frameBytes);
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 24), _frameBytes);
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 25), _frameBytes * 2);
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 240), bytes.length);
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 9999), bytes.length);
    });

    test('非法帧立刻停：不越过未知区域', () {
      final bytes = frames(4);
      bytes[2 * _frameBytes] = 0x00; // 第三帧头被破坏
      expect(mp3FrameOffsetAtOrAfterMs(bytes, 100), _frameBytes * 2);
    });
  });

  group('trimMp3Silence', () {
    test('首部静音 300ms → 裁到 220ms 目标 → 实际 240ms（10 帧）', () {
      final source = frames(50); // 1200ms
      final trim = trimMp3Silence(
        source,
        firstSpeechMs: 300,
        lastSpeechEndMs: 1000, // 尾静音仅 200ms，不到阈值
      );
      expect(trim.headMs, 240);
      expect(trim.tailMs, 0);
      expect(trim.audio.length, (50 - 10) * _frameBytes);
      // 切片起点必须落在帧边界：首字节仍是合法帧头。
      expect(mp3FrameSize(trim.audio, 0), _frameBytes);
    });

    test('尾部静音 400ms → 保留 160ms → 裁到帧边界 240ms', () {
      final source = frames(50);
      final trim = trimMp3Silence(
        source,
        firstSpeechMs: 0, // 首点 0：精度不足，不裁头
        lastSpeechEndMs: 800,
      );
      expect(trim.headMs, 0);
      expect(trim.tailMs, 240);
      expect(trim.audio.length, 40 * _frameBytes);
    });

    test('首尾同时裁', () {
      final source = frames(50);
      final trim = trimMp3Silence(
        source,
        firstSpeechMs: 300,
        lastSpeechEndMs: 800,
      );
      expect(trim.headMs, 240);
      expect(trim.tailMs, 240);
      expect(trim.audio.length, 30 * _frameBytes);
    });

    test('静音不足阈值时逐字节不变', () {
      final source = frames(50);
      final trim = trimMp3Silence(
        source,
        firstSpeechMs: 200, // 目标 120ms < 220ms
        lastSpeechEndMs: 1000, // 尾静音 200ms < 260ms
      );
      expect(trim.trimmed, isFalse);
      expect(trim.audio.length, source.length);
      expect(trim.audio, same(source));
    });

    test('时间点早于 0 或超出段尾：一律不裁', () {
      final source = frames(20);
      expect(
        trimMp3Silence(source, firstSpeechMs: -5, lastSpeechEndMs: 0).trimmed,
        isFalse,
      );
      expect(
        trimMp3Silence(source, firstSpeechMs: 9999, lastSpeechEndMs: 0).trimmed,
        isFalse,
      );
    });

    test('空音频安全返回', () {
      final trim = trimMp3Silence(
        Uint8List(0),
        firstSpeechMs: 300,
        lastSpeechEndMs: 900,
      );
      expect(trim.trimmed, isFalse);
      expect(trim.audio, isEmpty);
    });
  });

  group('composer 接入', () {
    test('裁头后时间点整体前移，章时长按新字节换算', () async {
      final composition = await _compose(
        _PaddedEngine(leadMs: 300, tailMs: 200),
      );
      // 50 帧 - 10 帧（240ms 头静音）
      expect(composition.audio.length, 40 * _frameBytes);
      expect(composition.timeline.words.first.startMs, 60); // 300 - 240
      expect(composition.audioMsFromBytes, mp3BytesToMs(40 * _frameBytes));
      expect(composition.timeline.audioMs, composition.audioMsFromBytes);
      for (final word in composition.timeline.words) {
        expect(word.startMs, greaterThanOrEqualTo(0));
        expect(word.endMs, lessThanOrEqualTo(composition.timeline.audioMs));
      }
    });

    test('裁尾后章时长变短，末点仍在音频内', () async {
      final composition = await _compose(
        _PaddedEngine(leadMs: 0, tailMs: 400),
      );
      expect(composition.audio.length, 40 * _frameBytes);
      final last = composition.timeline.words.last;
      expect(last.endMs, 800);
      expect(last.endMs, lessThanOrEqualTo(composition.timeline.audioMs));
    });

    test('流式尾部余量：静音不够余量大时不裁，最后一个字得以保留', () async {
      // 尾静音 400ms：默认 160 会裁掉 240ms（切段时缓冲一冲就吃到语音）；
      // 流式用 480 余量 → 目标超出段尾 → 原样保留。
      final safe = await _compose(
        _PaddedEngine(leadMs: 0, tailMs: 400),
        tailKeepMs: 480,
      );
      expect(safe.audio.length, 50 * _frameBytes);
      expect(safe.audioMsFromBytes, 1200);
      expect(safe.timeline.words.last.endMs, 800);

      final tight = await _compose(_PaddedEngine(leadMs: 0, tailMs: 400));
      expect(tight.audio.length, 40 * _frameBytes, reason: '默认余量仍是 160ms');
    });

    test('trimSilence=false 与裁剪前逐字节一致', () async {
      final raw = await _compose(
        _PaddedEngine(leadMs: 300, tailMs: 400),
        trimSilence: false,
      );
      expect(raw.audio.length, 50 * _frameBytes);
      expect(raw.timeline.words.first.startMs, 300);
      expect(raw.audioMsFromBytes, 1200);
    });

    test('段级精度（首点 0）不裁：整章字节与老行为一致', () async {
      final raw = await _compose(
        _PaddedEngine(leadMs: 0, tailMs: 0),
      );
      expect(raw.audio.length, 50 * _frameBytes);
      expect(raw.audioMsFromBytes, 1200);
    });
  });
}
