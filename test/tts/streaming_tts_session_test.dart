/// 流式朗读会话（S3.2 接线零件）：单元合并、按需产出、章内时间轴拼接、定位与取消。
///
/// 全程不联网、不碰播放器：`compose` 是注入的回调，直接把「单元」变成一段
/// 手搓的 `TtsComposition`，于是可以精确断言偏移与请求次数。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/reader/speech/speech_unit.dart';
import 'package:aquan_duanju/core/reader/speech/streaming_tts_session.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/core/tts/tts_unit_cache.dart';
import 'package:flutter_test/flutter_test.dart';

/// 每个单元固定 240ms / 1440 字节：时长可预测，偏移断言就不用反推编码。
const int _unitMs = 240;

/// 手搓一个单元的产物：词/句/段点都是**单元内相对时间**、章内绝对字符位。
TtsComposition _compositionOf(SpeechUnit unit, {int ms = _unitMs}) {
  final point = SpeechPoint(
    startMs: 0,
    endMs: ms - 40,
    charStart: unit.charStart,
    charEnd: unit.charEnd,
    unitIndex: unit.index,
    text: unit.text.isEmpty ? '' : unit.text.substring(0, 1),
  );
  return TtsComposition(
    audio: Uint8List(1440),
    timeline: SpeechTimeline(
      granularity: SpeechGranularity.word,
      audioMs: ms,
      words: <SpeechPoint>[point],
      sentences: <SpeechPoint>[point],
      paragraphs: <ParagraphTiming>[
        ParagraphTiming(
          paragraphIndex: unit.paragraphIndex,
          charStart: unit.charStart,
          charEnd: unit.charEnd,
          startMs: 0,
          endMs: ms - 40,
        ),
      ],
    ),
    bitrateKbps: 48,
    chunkCount: 1,
    audioMsFromBytes: ms,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late TtsUnitCache cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('streaming_session');
    cache = TtsUnitCache(root: Directory('${root.path}/units'));
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  TtsUnitKey key(String chapterId) => TtsUnitKey(
    bookId: '7001',
    chapterId: chapterId,
    engineId: 'edge',
    voiceId: 'voice#t1',
  );

  Future<StreamingTtsSession> open(
    List<String> paragraphs, {
    String chapterId = 'c1',
    int calls = 0,
    void Function(int count)? onCall,
  }) {
    var counter = calls;
    return StreamingTtsSession.open(
      cache: cache,
      key: key(chapterId),
      paragraphs: paragraphs,
      textSignature: 'sig-$chapterId',
      extension: 'mp3',
      granularity: SpeechGranularity.word,
      compose: (unit) async {
        counter++;
        onCall?.call(counter);
        return _compositionOf(unit);
      },
    );
  }

  test('同段短句合并到阈值，不跨段合并（段级坐标不能串）', () {
    final merged = mergeSpeechUnits(<String>['甲乙。丙丁。', '戊己。'], minChars: 6);
    expect(merged, hasLength(2), reason: '第一段两句合并、第二段独立');
    expect(merged[0].text, '甲乙。丙丁。');
    expect(merged[0].paragraphIndex, 0);
    expect(merged[1].text, '戊己。');
    expect(merged[1].paragraphIndex, 1);

    final each = mergeSpeechUnits(<String>['甲乙。丙丁。'], minChars: 1);
    expect(each, hasLength(2), reason: '阈值低于单句长度时保持逐句');
  });

  test('按需合成：ensure(0) 先发一次，随后 1-ahead 预取下一单元', () async {
    final calls = <int>[];
    final session = await open(
      <String>['甲乙。丙丁。', '戊己。'],
      onCall: calls.add,
    );
    expect(calls, isEmpty, reason: 'open 只读缓存，不该合成');

    await session.ensure(0);
    // 首单元落盘即排下一段（1-ahead）：`ensure(0)` 返回时第二发可能已在飞。
    expect(calls, hasLength(2), reason: '当前单元就绪即预取下一段，切段不空档');
    await _waitFor(
      () => session.producedCount == 2,
      reason: '预取的单元要真的落盘才算就绪',
    );
  });

  test('章内时间表 = 单元时间轴按 Σ 前序时长平移', () async {
    final session = await open(<String>['甲乙。丙丁。', '戊己。']);
    await session.ensure(0);
    await session.ensure(1);

    expect(session.startOf(0), 0);
    expect(session.startOf(1), _unitMs);
    expect(session.totalKnownMs, _unitMs * 2);

    final positions = session.positions;
    final words = positions.words;
    expect(words, hasLength(2));
    expect(words[0].startMs, 0);
    expect(words[1].startMs, _unitMs, reason: '第二单元的 0ms 就是章内 240ms');
    expect(
      words[1].charStart,
      session.units[1].charStart,
      reason: '字符位保持章内绝对坐标',
    );
    expect(positions.paragraphs.last.startMs, _unitMs);
  });

  test('locateChapterMs：章内毫秒 → 单元 + 单元内偏移', () async {
    final session = await open(<String>['甲乙。丙丁。', '戊己。']);
    final hit = await session.locateChapterMs(_unitMs + 60);
    expect(hit.index, 1);
    expect(hit.msInUnit, 60);
    expect(session.currentStartMs, 0, reason: 'locate 不改当前指针');
  });

  test('chapterMsOfParagraph：按段定位，单段内还能按比例细分', () async {
    final session = await open(<String>['甲乙。丙丁。', '戊己。']);
    expect(await session.chapterMsOfParagraph(1), _unitMs);
    expect(
      await session.chapterMsOfParagraph(1, ratio: 0.5),
      _unitMs + (_unitMs - 40) ~/ 2,
      reason: '有时间点就用段级点算比例，而不是拿单元起点糊弄',
    );
  });

  test('整章单元齐全后重开：零合成、路径直接可播', () async {
    final first = await open(<String>['甲乙。丙丁。', '戊己。']);
    await first.ensure(0);
    await first.ensure(1);
    // finish 是后台原子写：等到 index.json 出现再重开，否则断言的是竞态。
    await _waitFor(
      () => _hasIndex(cache),
      reason: 'index.json 必须由 finish 落盘',
    );

    var calls = 0;
    final second = await open(
      <String>['甲乙。丙丁。', '戊己。'],
      onCall: (_) => calls++,
    );
    expect(second.producedCount, 2, reason: '命中后所有单元立即可用');
    expect(second.totalKnownMs, _unitMs * 2);
    expect(second.positions.words, hasLength(2));
    final audio = await second.ensure(1);
    expect(audio.path, endsWith('u001.mp3'));
    expect(calls, 0, reason: '命中缓存不许再发一次合成');
  });

  test('取消后不再合成新单元', () async {
    final session = await open(<String>['甲乙。丙丁。', '戊己。']);
    session.cancel();
    expect(
      session.ensure(0),
      throwsA(
        isA<TtsException>().having(
          (e) => e.code,
          'code',
          TtsErrorCode.cancelled,
        ),
      ),
    );
  });
}

bool _hasIndex(TtsUnitCache cache) {
  final dir = Directory(cache.root.path);
  if (!dir.existsSync()) return false;
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .any((file) => file.path.endsWith('index.json'));
}

Future<void> _waitFor(bool Function() predicate, {String? reason}) async {
  for (var i = 0; i < 200; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason ?? '等待超时');
}
