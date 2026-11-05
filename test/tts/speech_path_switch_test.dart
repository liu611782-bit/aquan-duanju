/// 朗读**路径切换**与精度徽标（design.md §6）：同书在「平台音轨」与「自建合成」之间
/// 来回切时保位、失败回滚，以及徽标必须把**真拿得到的精度**如实说出来。
///
/// 四条钉住的语义：
/// 1. 保位走 §6 的「段落下标 + 段内比例 → 新表段起点」换算，**不承诺毫秒对齐**，
///    所以断言写成不变量：「把落点当位置灌回位置流，段落号仍是同一段」；
/// 2. 切不过去时路径真值回滚 + `TtsException.friendlyText`，绝不静默换成另一条路；
/// 3. 没得切（这本书根本没有平台音轨）要明说，不能变成「按了但什么都没发生」；
/// 4. 音轨路径的徽标恒显「段」，即使用户偏好词级 —— 这是「禁止静默降级」的
///    用户可见落点。
library;

import 'dart:async';

import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/reader/reader_speech_settings.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:aquan_duanju/models/book.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'speech_fakes.dart';

const AudioTones _platformTones = AudioTones(
  tones: <AudioTone>[AudioTone(id: 74, title: '男声')],
);

const AudioTones _recordedTones = AudioTones(
  genreType: 1,
  tones: <AudioTone>[AudioTone(id: 75, title: '真人')],
);

/// 三段正文：假引擎每字 10ms，合成表里第二段从 40ms 起。
const String _threeParagraphHtml = '<p>甲乙。</p><p>丙丁。</p><p>戊己。</p>';

/// 音轨表：每段一个精确点，第二段起点 1000ms。
const AudioTimepoints _threeParagraphPoints = AudioTimepoints(
  points: <AudioTimepoint>[
    AudioTimepoint(startMs: 0, para: 0),
    AudioTimepoint(startMs: 1000, para: 1),
    AudioTimepoint(startMs: 2000, para: 2),
  ],
);

/// 音色列表拿不到的引擎：列音色要联网，设置页绝不能因为它而打不开（§7）。
class _NoVoicesTts extends FakeTts {
  _NoVoicesTts();

  @override
  Future<List<TtsVoice>> voices() async =>
      throw const TtsException(TtsErrorCode.transport);
}

/// 音轨链路按「段落 + 段内比例」定位前会先等媒体时长事件（`_waitDuration`，3s
/// 超时）。假播放器什么都不发，这里每 10ms 喂一个时长：测试等的是行为，不是超时。
Timer _feedDuration(FakePlayer player) => Timer.periodic(
      const Duration(milliseconds: 10),
      (_) => player.feed.durationCtrl.add(const Duration(seconds: 30)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpeechHarness harness;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    harness = SpeechHarness('speech_path_switch');
    harness.api.html = _threeParagraphHtml;
  });

  tearDown(() => harness.dispose());

  group('音轨 → 自建合成', () {
    test('保位回到同一段：把落点灌回位置流，段落号仍是 1', () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _threeParagraphPoints;
      final engine = FakeTts();
      final controller = harness.build(engine);
      controller.setParagraphCount(3);
      await harness.start(controller);
      expect(controller.activePath, SpeechPath.platformTone);
      expect(engine.calls, 0, reason: '有平台音轨时不该动合成引擎');

      await harness.pumpPosition(1500); // 音轨第二段的中点
      expect(controller.paragraphIndex, 1);

      final opens = harness.player.opened.length;
      await controller.setPreferredPath(SpeechPath.cloudTts);

      expect(controller.activePath, SpeechPath.cloudTts);
      expect(controller.highlightGranularity, SpeechGranularity.word);
      expect(engine.calls, greaterThan(0), reason: '切过去就是要走合成');
      expect(
        harness.player.opened.length,
        opens + 1,
        reason: '换路径 = 换一路音频重新开播',
      );

      final seekMs = harness.player.seeks.last.inMilliseconds;
      expect(seekMs, greaterThan(0), reason: '§6：按段落下标 + 段内比例换算过落点');
      await harness.pumpPosition(seekMs);
      expect(
        controller.paragraphIndex,
        1,
        reason: '保位到同一段就够，两条链路时长本来就不同（不追求毫秒对齐）',
      );
    });

    test('同路径重复设置是空操作：不重新开播、不重复合成', () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _threeParagraphPoints;
      final engine = FakeTts();
      final controller = harness.build(engine);
      controller.setParagraphCount(3);
      await harness.start(controller);
      final opens = harness.player.opened.length;

      await controller.setPreferredPath(SpeechPath.platformTone);

      expect(harness.player.opened.length, opens);
      expect(engine.calls, 0);
      expect(controller.error, isNull);
    });
  });

  group('自建合成 → 音轨', () {
    test('来回切都回到第二段：落点用音轨表的段起点（offsetMs 精确优先）', () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _threeParagraphPoints;
      final controller = harness.build(FakeTts());
      controller.setParagraphCount(3);
      await harness.start(controller);
      await harness.pumpPosition(1500);
      expect(controller.paragraphIndex, 1);

      await controller.setPreferredPath(SpeechPath.cloudTts);
      expect(controller.activePath, SpeechPath.cloudTts);
      final ttsMs = harness.player.seeks.last.inMilliseconds;
      await harness.pumpPosition(ttsMs);
      expect(controller.paragraphIndex, 1, reason: '切过去仍落在第二段');

      final feed = _feedDuration(harness.player);
      await controller.setPreferredPath(SpeechPath.platformTone);
      feed.cancel();

      expect(controller.activePath, SpeechPath.platformTone);
      expect(
        controller.highlightGranularity,
        SpeechGranularity.paragraph,
        reason: '音轨表结构上只有段级',
      );
      expect(
        harness.player.seeks.last,
        const Duration(milliseconds: 1000),
        reason: '§6：新表侧用 startMsOfParagraph/offsetMs 的精确值',
      );
      await harness.pumpPosition(1000);
      expect(controller.paragraphIndex, 1);
    });
  });

  group('段 0 起点的保位边界（§6）', () {
    test('两个方向都不把「另一条音频的上次进度」当落点', () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _threeParagraphPoints;
      // 持久化的是音轨侧的毫秒：合成侧时长完全不同，灌进来就是跳到随机位置。
      harness.store.savedMs = 9000;
      final controller = harness.build(FakeTts());
      controller.setParagraphCount(3);
      await harness.start(controller);
      expect(controller.activePath, SpeechPath.platformTone);
      expect(controller.paragraphIndex, 0);

      harness.player.seeks.clear();
      await controller.setPreferredPath(SpeechPath.cloudTts);
      expect(controller.activePath, SpeechPath.cloudTts);
      expect(
        harness.player.seeks,
        isEmpty,
        reason: 'anchor=(0,0) 是明确落点，要落回段 0，不能退到 entry().positionMs',
      );

      harness.player.seeks.clear();
      await controller.setPreferredPath(SpeechPath.platformTone);
      expect(controller.activePath, SpeechPath.platformTone);
      expect(harness.player.seeks, isEmpty, reason: '反方向同理');
    });
  });

  group('切不过去就如实说，绝不静默换路', () {
    test('这本书没有平台音轨：路径不动 + 明确文案', () async {
      // 音色表为空（harness 默认）→ start 走合成，`_tone` 为 null，没得切回音轨。
      final controller = harness.build(FakeTts());
      await harness.start(controller);
      expect(controller.activePath, SpeechPath.cloudTts);
      final opens = harness.player.opened.length;

      await controller.setPreferredPath(SpeechPath.platformTone);

      expect(controller.activePath, SpeechPath.cloudTts);
      expect(
        controller.error,
        '这本书没有平台音轨，切不回朗读前的音轨',
        reason: '没得切要明说，不能变成「按了但什么都没发生」',
      );
      expect(harness.player.opened.length, opens);
    });

    test('合成侧失败：路径回滚到音轨，报错给 friendlyText，播放状态如实还原',
        () async {
      harness.api.tones = _platformTones;
      harness.api.timepoints = _threeParagraphPoints;
      const failure = TtsException(TtsErrorCode.transport);
      final controller = harness.build(FakeTts(failure: failure));
      controller.setParagraphCount(3);
      await harness.start(controller);
      expect(controller.activePath, SpeechPath.platformTone);
      expect(controller.playing, isTrue);

      await controller.setPreferredPath(SpeechPath.cloudTts);

      expect(
        controller.activePath,
        SpeechPath.platformTone,
        reason: '失败必须回到切换前的路径，后续换章/seek 也按原路径走',
      );
      expect(controller.error, failure.friendlyText);
      expect(
        controller.playing,
        isTrue,
        reason: '失败链路在 open() 之前就抛了，原音轨根本没被动过',
      );
    });

    test('朗读没开时 setPreferredPath 不做事', () async {
      final controller = harness.build(FakeTts());
      await controller.setPreferredPath(SpeechPath.cloudTts);
      expect(controller.isActive, isFalse);
      expect(controller.error, isNull);
      expect(harness.player.opened, isEmpty);
    });
  });

  group('精度徽标（speechBadgeOf）', () {
    test('音轨两条路恒显段，云合成按真精度', () {
      expect(
        speechBadgeOf(SpeechPath.recorded, SpeechGranularity.word),
        '真人音轨·段',
      );
      expect(
        speechBadgeOf(SpeechPath.recorded, SpeechGranularity.paragraph),
        '真人音轨·段',
      );
      expect(
        speechBadgeOf(SpeechPath.platformTone, SpeechGranularity.sentence),
        '智能朗读·段',
      );
      expect(
        speechBadgeOf(SpeechPath.cloudTts, SpeechGranularity.word),
        '云合成·词',
      );
      expect(
        speechBadgeOf(SpeechPath.cloudTts, SpeechGranularity.sentence),
        '云合成·句',
      );
      expect(
        speechBadgeOf(SpeechPath.cloudTts, SpeechGranularity.paragraph),
        '云合成·段',
      );
    });

    test('控制器 badgeText 就是 activePath + highlightGranularity 的映射',
        () async {
      final controller = harness.build(FakeTts());
      await harness.start(controller);
      expect(
        controller.badgeText,
        speechBadgeOf(
          controller.activePath,
          controller.highlightGranularity,
        ),
      );
      expect(controller.badgeText, '云合成·词');
    });

    test('真人音轨 + 偏好词级：徽标仍然是「段」（禁止静默降级可见）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        ReaderSpeechSettings.granularityKey:
            SpeechHighlightGranularity.word.name,
      });
      harness.api.tones = _recordedTones;
      harness.api.timepoints = _threeParagraphPoints;
      final controller = harness.build(FakeTts());
      controller.setParagraphCount(3);
      await harness.start(controller);

      expect(controller.activePath, SpeechPath.recorded);
      expect(controller.highlightGranularity, SpeechGranularity.paragraph);
      expect(controller.badgeText, '真人音轨·段');
    });
  });

  group('设置页要用的两个只读口', () {
    test('ttsEngineId 与 listTtsVoices：列表为空也照常返回', () async {
      final controller = harness.build(FakeTts());
      expect(controller.ttsEngineId, 'edge');
      expect(await controller.listTtsVoices(), isEmpty);
    });

    test('引擎报错时 listTtsVoices 照常抛给调用方（设置页自己吞）', () async {
      final controller = harness.build(_NoVoicesTts());
      await expectLater(
        controller.listTtsVoices(),
        throwsA(isA<TtsException>()),
      );
      expect(controller.ttsEngineId, 'edge');
    });
  });

  group('非数字章节 id 的硬闸门', () {
    test('第三方书 / URL 章节 id：即使有音色表也走本地合成', () async {
      // 闸门存在的原因：番茄音轨接口只认数字 item id，第三方书拿 URL 去请求会失败。
      // 用 'c1' 这类占位 id 写音轨用例会静默跌到 TTS —— 夹具必须用纯数字（见
      // speech_fakes.dart 的 harnessChapters）。
      harness.api.tones = _recordedTones;
      harness.api.timepoints = _threeParagraphPoints;
      final engine = FakeTts();
      final controller = harness.build(engine);

      await controller.start(
        bookId: 'csp_book',
        bookTitle: '第三方书',
        coverUrl: '',
        chapters: const <BookChapter>[
          BookChapter(id: 'https://example.com/ch1', title: '第一章', index: 0),
        ],
        chapterIndex: 0,
      );

      expect(controller.tone, isNull, reason: '非数字 id 必须清掉音色');
      expect(controller.activePath, SpeechPath.cloudTts);
      expect(engine.calls, greaterThan(0), reason: '必须落到本地合成');
      expect(harness.api.audioStreamCalls, 0, reason: '不碰音轨接口');
    });
  });
}
