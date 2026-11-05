/// 控制器接入 TTS（design.md §9）：假引擎 + 假播放器 + 临时目录缓存，不联网。
///
/// 断言的重心是**接入而不改行为**：音轨路径的时间点/跳段逐项不变、TTS 路径复用
/// 同一套 `SpeechPositions`；世代丢弃、回滚开关、preset 降级、倍速不重合成都有
/// 独立用例守住。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/reader/reader_listen_settings.dart';
import 'package:aquan_duanju/core/reader/speech/sleep_timer.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_cache.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:aquan_duanju/models/book.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:shared_preferences/shared_preferences.dart';

/// 造 [count] 个合法 MPEG-2 Layer III 48kbps 帧：每帧 144 字节 = 24ms。
/// 缓存层只认「有音频帧且 ≥1024 字节」，10 帧刚好过线。
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

/// 一个合成块给的帧数：10 帧 = 240ms，过缓存有效性阈值。
const int _framesPerJob = 10;

/// 假合成引擎：按契约把 `offsetBaseMs` 平移到时间点上、字符位相对 `job.text`。
class _FakeTts implements SpeechEngine {
  _FakeTts({this.wordBoundary = true, this.failure, this.gate});

  final bool wordBoundary;

  /// 非空则每次 `synthesize` 都抛它（模拟 403、建连失败、空音频）。
  final Object? failure;

  /// 非空则 `synthesize` 先等它完成：用来制造「结果迟到时世代已变」。
  final Completer<void>? gate;

  final List<SpeechJob> jobs = <SpeechJob>[];

  int get calls => jobs.length;

  @override
  String get id => 'edge';

  @override
  TtsCaps get caps => TtsCaps(wordBoundary: wordBoundary);

  @override
  Future<List<TtsVoice>> voices() async => const <TtsVoice>[];

  @override
  Future<void> dispose() async {}

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    jobs.add(job);
    final failure = this.failure;
    if (failure != null) throw failure;
    final gate = this.gate;
    if (gate != null) await gate.future;
    final base = job.offsetBaseMs;
    final points = <SpeechPoint>[];
    for (var k = 0; k < job.text.length; k++) {
      final ch = job.text[k];
      if (ch.trim().isEmpty) continue; // 引擎不会为空白出 token
      points.add(
        SpeechPoint(
          startMs: base + k * 10,
          endMs: base + k * 10 + 10,
          charStart: k,
          charEnd: k + 1,
          unitIndex: 0,
          text: ch,
        ),
      );
    }
    return TtsSegment(
      audio: frames(_framesPerJob),
      points: points,
      audioMs: _framesPerJob * 24,
    );
  }
}

/// 前 [failures] 次 `synthesize` 抛错，之后成功 —— 模拟「重试后好了」。
class _FlakyTts extends _FakeTts {
  _FlakyTts(this.failures);

  int failures;

  @override
  Future<TtsSegment> synthesize(SpeechJob job) async {
    if (failures > 0) {
      failures--;
      // 先记一次 job：重试语义要看得到“确实又发了一次请求”。
      jobs.add(job);
      throw const TtsException(TtsErrorCode.transport, message: '模拟失败');
    }
    return super.synthesize(job);
  }
}

/// 假播放器：只记录调用，不碰 libmpv。
class _FakePlayer implements PlayerEngine {
  /// 测试从 `feed` 里那几个 controller 往流里灌事件，
  /// `stream` 只读（`Stream` 没有 `add`）。
  final _FakeStream feed = _FakeStream();
  final List<Media> opened = <Media>[];
  final List<String> properties = <String>[];
  final List<double> rates = <double>[];
  final List<double> volumes = <double>[];
  final List<Duration> seeks = <Duration>[];
  int stops = 0;
  int playOrPauses = 0;

  /// 非 null 时 `stop()` 挂起等它的 future，用于模拟原生桥卡住。
  Completer<void>? stopBlock;

  @override
  PlayerStream get stream => feed;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> open(Media media, {bool play = true}) async => opened.add(media);

  @override
  Future<void> playOrPause() async => playOrPauses++;

  @override
  Future<void> stop() async {
    stops++;
    if (stopBlock != null) await stopBlock!.future;
  }

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);

  @override
  Future<void> setProperty(String name, String value) async =>
      properties.add('$name=$value');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// `PlayerStream` 有 25 个流，只实现控制器真正订阅的那几个，其余交给 noSuchMethod。
class _FakeStream implements PlayerStream {
  final StreamController<bool> playingCtrl = StreamController<bool>.broadcast();
  final StreamController<bool> completedCtrl =
      StreamController<bool>.broadcast();
  final StreamController<Duration> positionCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> durationCtrl =
      StreamController<Duration>.broadcast();
  final StreamController<String> errorCtrl =
      StreamController<String>.broadcast();

  @override
  Stream<bool> get playing => playingCtrl.stream;

  @override
  Stream<bool> get completed => completedCtrl.stream;

  @override
  Stream<Duration> get position => positionCtrl.stream;

  @override
  Stream<Duration> get duration => durationCtrl.stream;

  @override
  Stream<String> get error => errorCtrl.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 假门面：只覆盖听书链路用到的四个方法，其余一律不许碰 FFI。
class _FakeApi extends AquaApi {
  _FakeApi() : super(_StubClient());

  AudioTones tones = const AudioTones(tones: <AudioTone>[]);
  String html = '<p>甲乙。丙丁。</p><p>戊己。</p>';
  AudioStream track = const AudioStream(
    path: 'https://cdn/a.m3u8',
    keyHex: 'AA',
  );
  AudioTimepoints timepoints = const AudioTimepoints();
  int chapterTextCalls = 0;

  @override
  Future<AudioTones> audioTones(String bookId) async => tones;

  @override
  Future<String> chapterText(String itemId) async {
    chapterTextCalls++;
    return html;
  }

  @override
  Future<AudioStream> audioStream(
    String bookId,
    String itemId,
    int toneId,
  ) async => track;

  @override
  Future<AudioTimepoints> audioTimepoints(
    String bookId,
    String itemId,
    int toneId,
  ) async => timepoints;
}

class _StubClient implements AquaClient {
  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async =>
      throw UnsupportedError('测试不该走 FFI：$method');
}

/// 听书进度的记录型 store：既不碰磁盘，也能断言「进度只写听书 store」。
class _RecordingStore extends ListenProgressStore {
  final List<int> positions = <int>[];
  final List<int> tones = <int>[];

  @override
  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required int toneId,
    required int positionMs,
  }) async {
    positions.add(positionMs);
    tones.add(toneId);
  }
}

// 章节 id 用纯数字：控制器对非数字 id 有「强制本地合成」硬闸门（第三方书源），
// 用 'c1' 会让音轨路径用例全部跌到 TTS。
const List<BookChapter> _chapters = <BookChapter>[
  BookChapter(id: '7001', title: '第一章 起风了', index: 0),
  BookChapter(id: '7002', title: '第二章 雪停了', index: 1),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late _FakeApi api;
  late _FakePlayer player;
  late _RecordingStore store;
  late TtsCache cache;
  final controllers = <ReaderSpeechController>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('speech_tts');
    api = _FakeApi();
    player = _FakePlayer();
    store = _RecordingStore();
    cache = TtsCache(rootDirectory: () async => root);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    for (final controller in controllers) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    controllers.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  ReaderSpeechController build(
    SpeechEngine engine, {
    TtsEngineFallback? fallback,
    TtsComposer? composer,
    int Function()? clockMs,
    int concurrency = kTtsDefaultConcurrency,
    Future<void> Function(Duration duration)? fadeSleep,
  }) {
    final controller = ReaderSpeechController(
      api: api,
      store: store,
      engine: player,
      ttsEngine: engine,
      ttsCache: cache,
      ttsComposer: composer ?? TtsComposer(),
      ttsEngineFallback: fallback,
      clockMs: clockMs,
      // 淡出等待默认即时：断言只关心曲线与恢复，不关心真实 3 秒。
      fadeSleep: fadeSleep ?? (_) async {},
      ttsConcurrency: concurrency,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> start(
    ReaderSpeechController controller, {
    int chapterIndex = 0,
  }) => controller.start(
    bookId: '7001',
    bookTitle: '一本书',
    coverUrl: '',
    chapters: _chapters,
    chapterIndex: chapterIndex,
  );

  /// `audio_cache/7001`：缓存按书分目录。
  Directory bookDir() => Directory(
    '${root.path}${Platform.pathSeparator}audio_cache'
    '${Platform.pathSeparator}7001',
  );

  void expectChapterPair({
    String engineId = 'edge',
    String voiceId = 'zh-CN-XiaoxiaoNeural',
    // 静音裁剪开关也进缓存键（默认开 → `#t1`，文件名字符过滤后是 `_t1`）。
    String trimSuffix = '_t1',
  }) {
    // 缓存键含章节 id：`_chapters[0].id` 是 7001（必须是纯数字，见文件头注释）。
    final stem = '7001-$engineId-$voiceId$trimSuffix';
    expect(
      File('${bookDir().path}${Platform.pathSeparator}$stem.mp3').existsSync(),
      isTrue,
      reason: '音频必须落盘',
    );
    expect(
      File('${bookDir().path}${Platform.pathSeparator}$stem.jsonl')
          .existsSync(),
      isTrue,
      reason: '时间点必须与音频成对',
    );
  }

  group('结束朗读立即收起朗读条（fix: 不消失主诉）', () {
    test('stop 卡住时 isFor/isActive 也随 close() 同步前缀翻 false', () async {
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.isFor('7001'), isTrue);
      expect(controller.isActive, isTrue);

      // 让 _engine.stop() 永不返回，模拟原生桥卡住。
      player.stopBlock = Completer<void>();
      final closeFuture = controller.close();

      // close() 同步前缀已落下 _finalizing：不依赖 stop 是否完成，条判定即时失效。
      expect(controller.isFor('7001'), isFalse);
      expect(controller.isActive, isFalse);

      await pumpEventQueue();
      expect(controller.isActive, isFalse, reason: 'stop 仍卡住时不得复活');
      expect(player.stops, 1);

      // 放行 stop，收尾不悬挂（tearDown 会 dispose）。
      player.stopBlock!.complete();
      await closeFuture;
    });

    test('close() 后重新 start() 复位关闭闸，朗读条判定恢复', () async {
      final controller = build(_FakeTts());
      await start(controller);
      await controller.close();
      expect(controller.isActive, isFalse);
      expect(controller.isFor('7001'), isFalse);

      await start(controller);
      expect(controller.isFor('7001'), isTrue);
      expect(controller.isActive, isTrue);
    });
  });

  group('无平台音色时改走本地合成', () {
    test('不再报「没有可用的朗读音色」，而是合成后开播并成对落盘', () async {
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);

      expect(controller.error, isNull);
      expect(controller.loading, isFalse);
      expect(controller.playing, isTrue);
      expect(engine.calls, 1);
      expect(player.opened, hasLength(1));
      expect(player.opened.single.uri, contains('.mp3'));
      expectChapterPair();
      // 与阅读页同一入口：正文来自 chapterText，段数由控制器自己收敛。
      expect(api.chapterTextCalls, 1);
      expect(controller.tone, isNull);
    });

    test('首段等于章标题时去掉，朗读文本里不念标题', () async {
      api.html = '<p>第一章 起风了</p><p>甲乙。丙丁。</p><p>戊己。</p>';
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);

      final spoken = engine.jobs.map((j) => j.text).join('\n');
      expect(spoken, contains('甲乙'));
      expect(spoken, isNot(contains('起风了')));
      expect(controller.playing, isTrue);
    });

    test('二次开播命中缓存：一次网络都不发', () async {
      final first = _FakeTts();
      await start(build(first));
      expect(first.calls, 1);

      final second = _FakeTts();
      final controller = build(second);
      await start(controller);

      expect(second.calls, 0, reason: '命中缓存不得再合成');
      expect(controller.error, isNull);
      expect(controller.playing, isTrue);
      // 正文仍要取一次：指纹是缓存有效性判定的一部分。
      expect(api.chapterTextCalls, 2);
    });

    test('回滚开关 listen.tts.enabled=false 时保持原文案与原行为', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.tts.enabled': false,
      });
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);

      expect(controller.error, '这本书暂时没有可用的朗读音色');
      expect(controller.loading, isFalse);
      expect(controller.playing, isFalse);
      expect(engine.calls, 0);
      expect(player.opened, isEmpty);
    });

    test('进度只写 ListenProgressStore：没有平台音色时 toneId 记 0', () async {
      final controller = build(_FakeTts());
      await start(controller);
      // 位置事件是异步派发的：必须先 pump 一轮，控制器里的 _position 才是新值。
      player.feed.positionCtrl.add(const Duration(milliseconds: 1200));
      await pumpEventQueue();
      await controller.toggle(); // 暂停时立即落一次进度
      await pumpEventQueue();
      expect(store.positions, isNotEmpty);
      expect(store.positions.last, 1200);
      expect(store.tones.every((t) => t == 0), isTrue);
    });
  });

  group('时间点真值源统一到 SpeechPositions', () {
    test('词级引擎时 currentWord 给出当前字', () async {
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.currentWord, isNotNull);
      expect(controller.currentWord!.text, isNotEmpty);
    });

    test('句级引擎不伪造精度：currentWord 为 null', () async {
      final controller = build(_FakeTts(wordBoundary: false));
      await start(controller);
      expect(controller.currentWord, isNull);
      expect(controller.playing, isTrue);
    });

    test('音轨路径逐项不变：paragraphIndex 与 AudioTimepoints.paragraphAt 相等', () async {
      api.tones = const AudioTones(
        tones: <AudioTone>[AudioTone(id: 74, title: '男声')],
      );
      api.timepoints = const AudioTimepoints(
        points: <AudioTimepoint>[
          AudioTimepoint(startMs: 0, para: 0),
          AudioTimepoint(startMs: 1000, para: 1),
          AudioTimepoint(startMs: 2000, para: 2),
        ],
      );
      final engine = _FakeTts();
      final controller = build(engine);
      controller.setParagraphCount(3);
      await start(controller);
      await pumpEventQueue();

      expect(controller.tone?.id, 74);
      expect(engine.calls, 0, reason: '有平台音轨时不该动合成引擎');
      expect(api.chapterTextCalls, 0, reason: '音轨路径不取正文');
      expect(player.opened.single.uri, contains('a.m3u8'));
      // 密钥与请求头仍按原样写进 mpv（行为不变的硬证据）。
      expect(
        player.properties.firstWhere((p) => p.startsWith('demuxer-lavf-o')),
        contains('decryption_key=AA'),
      );

      for (final ms in <int>[0, 500, 1000, 1500, 1999, 2000, 9000]) {
        player.feed.positionCtrl.add(Duration(milliseconds: ms));
        await pumpEventQueue();
        expect(
          controller.paragraphIndex,
          api.timepoints.paragraphAt(ms, paragraphCount: 3),
        );
      }
      expect(controller.currentWord, isNull, reason: '音轨侧拿不到词级');

      // 跳段也仍然落到同一个毫秒源。
      player.feed.positionCtrl.add(const Duration(milliseconds: 1500));
      await pumpEventQueue();
      await controller.stepParagraph(1);
      expect(
        player.seeks.last,
        Duration(
          milliseconds: api.timepoints.startMsOfParagraph(2, paragraphCount: 3),
        ),
      );
    });
  });

  group('世代丢弃与中止', () {
    test('close() 后迟到结果被丢弃，且不再请求下一块（串行）', () async {
      final gate = Completer<void>();
      final engine = _FakeTts(gate: gate);
      final controller = build(
        engine,
        composer: TtsComposer(maxChunkChars: 4),
        concurrency: 1,
      );
      final pending = start(controller);
      // 等到第一块真的发出去再关：文件 IO 会让它晚于一轮 pump。
      for (var i = 0; i < 100 && engine.calls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.calls, 1);

      await controller.close();
      gate.complete();
      await pending;
      await pumpEventQueue();

      expect(engine.calls, 1, reason: '切章即中止：下一块不再请求');
      expect(player.opened, isEmpty, reason: '迟到结果不许开播');
      expect(controller.error, isNull, reason: 'cancelled 不是错误');
      expect(controller.isActive, isFalse);
    });

    test('并发下 close()：不再领新块，在飞的结果也不许开播', () async {
      final gate = Completer<void>();
      final engine = _FakeTts(gate: gate);
      final controller = build(
        engine,
        composer: TtsComposer(maxChunkChars: 4),
        concurrency: 2,
      );
      final pending = start(controller);
      // 并发 2：两块会同时在飞，等它们都发出去再关。
      for (var i = 0; i < 100 && engine.calls < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(engine.calls, 2, reason: '并发 2 应该两块同时在飞');

      await controller.close();
      gate.complete();
      await pending;
      await pumpEventQueue();

      expect(engine.calls, 2, reason: '关闭后不再领第三块（已发出的最多 2 个）');
      expect(player.opened, isEmpty, reason: '在飞的结果已作废，不许开播');
      expect(controller.error, isNull);
    });

    test('切到下一章时旧章的合成结果不再污染状态', () async {
      final gate = Completer<void>();
      final engine = _FakeTts(gate: gate);
      final controller = build(engine, composer: TtsComposer(maxChunkChars: 4));
      final pending = start(controller);
      // 首块真的发出去了才往下切章：文件 IO 会让它晚于一轮 pump。
      for (var i = 0; i < 100 && engine.calls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(controller.chapterIndex, 0);

      // 上一章还在合成时用户跳章：新章自己会跑一轮（同一个 gate 已放行前会被卡住），
      // 因此先切章再放行，旧那一代必须整体作废。
      final second = controller.next();
      await pumpEventQueue();
      gate.complete();
      await pending;
      await second;
      await pumpEventQueue();

      expect(controller.chapterIndex, 1);
      expect(controller.error, isNull);
      expect(player.opened, hasLength(1));
    });
  });

  group('失败处理与 preset 降级', () {
    test('TtsException 只把 friendlyText 放进 error', () async {
      const failure = TtsException(TtsErrorCode.emptyAudio);
      final engine = _FakeTts(failure: failure);
      final controller = build(engine, fallback: (current, proxy) => null);
      await start(controller);

      expect(controller.error, failure.friendlyText);
      expect('${controller.error}', isNot(contains('TtsException')));
      expect(controller.loading, isFalse);
      expect(controller.playing, isFalse);
    });

    test('403 纠偏无效 → 换 preset 整章重试一次并成功', () async {
      final first = _FakeTts(
        failure: const TtsException(TtsErrorCode.authRejected),
      );
      final second = _FakeTts();
      var fallbackCalls = 0;
      final controller = build(
        first,
        fallback: (current, proxy) {
          fallbackCalls++;
          return second;
        },
      );
      await start(controller);

      expect(fallbackCalls, 1);
      expect(first.calls, 1);
      expect(second.calls, 1);
      expect(controller.error, isNull);
      expect(controller.playing, isTrue);
    });

    test('换端点仍失败 → 报友好文案，且不再无限降级', () async {
      final first = _FakeTts(
        failure: const TtsException(
          TtsErrorCode.transport,
          message: '连不上',
          retryable: true,
        ),
      );
      final second = _FakeTts(
        failure: const TtsException(TtsErrorCode.authRejected),
      );
      var fallbackCalls = 0;
      final controller = build(
        first,
        fallback: (current, proxy) {
          fallbackCalls++;
          return fallbackCalls == 1 ? second : null;
        },
      );
      await start(controller);

      expect(fallbackCalls, 1, reason: '整章只重试一次');
      expect(second.calls, 1);
      expect(
        controller.error,
        const TtsException(TtsErrorCode.authRejected).friendlyText,
      );
    });

    test('限流不换端点（重试也没用），直接报文案', () async {
      final engine = _FakeTts(
        failure: const TtsException(TtsErrorCode.rateLimited),
      );
      var fallbackCalls = 0;
      final controller = build(
        engine,
        fallback: (current, proxy) {
          fallbackCalls++;
          return _FakeTts();
        },
      );
      await start(controller);

      expect(fallbackCalls, 0);
      expect(engine.calls, 1);
      expect(
        controller.error,
        const TtsException(TtsErrorCode.rateLimited).friendlyText,
      );
    });

    test('正文为空时按空音频报错，不打开播放器', () async {
      api.html = '<p>第一章 起风了</p>';
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);

      expect(engine.calls, 0);
      expect(player.opened, isEmpty);
      expect(
        controller.error,
        const TtsException(TtsErrorCode.emptyAudio).friendlyText,
      );
    });
  });

  group('语速与缓存键', () {
    test('语速按书记忆：按书键优先，全局键只做新书默认', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.speed': 1.2,
        'listen.speed.7001': 1.8,
      });
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.speed, 1.8, reason: '按书键优先于全局键');

      await controller.setSpeed(2.2);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble('listen.speed.7001'), 2.2);
      expect(prefs.getDouble('listen.speed'), 2.2, reason: '全局键随之为新书默认');

      // 另一本书：没有按书键 → 回落全局（2.2），不再沿用 7001 的旧值以外的猜测。
      await controller.start(
        bookId: '7002',
        bookTitle: '另一本',
        coverUrl: '',
        chapters: _chapters,
        chapterIndex: 0,
      );
      expect(controller.speed, 2.2);
    });

    test('改倍速只调播放器，不重新合成、不产生新缓存文件', () async {
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);
      expect(engine.calls, 1);
      expect(player.rates, contains(1.0));
      final before = bookDir().listSync().length;

      await controller.setSpeed(1.5);

      expect(engine.calls, 1, reason: '倍速绝不触发重新合成');
      expect(player.rates.last, 1.5);
      expect(bookDir().listSync().length, before, reason: '倍速不进缓存键');
    });

    test('换音色重新合成：音色进键，两份产物并存', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.tts.voice': 'zh-CN-XiaoyiNeural',
      });
      final engine = _FakeTts();
      final controller = build(engine);
      await start(controller);
      expect(engine.calls, 1);
      expect(engine.jobs.single.voice.id, 'zh-CN-XiaoyiNeural');
      expect(
        File(
          '${bookDir().path}${Platform.pathSeparator}'
          '7001-edge-zh-CN-XiaoyiNeural_t1.mp3',
        ).existsSync(),
        isTrue,
      );
      expect(controller.playing, isTrue);
    });
  });

  group('自动连播与章间间隔', () {
    test('间隔结束后自动切到下一章', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.chapterGapMs': 40,
      });
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.chapterIndex, 0);

      player.feed.completedCtrl.add(true);
      await Future<void>.delayed(const Duration(milliseconds: 250));

      expect(controller.chapterIndex, 1);
      expect(controller.currentChapter?.id, '7002');
    });

    test('间隔期间关闭会话：不再自动切章', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.chapterGapMs': 80,
      });
      final controller = build(_FakeTts());
      await start(controller);

      player.feed.completedCtrl.add(true);
      // 让 completed 监听器先进到「等待间隔」里面，再关会话。
      await Future<void>.delayed(Duration.zero);
      await controller.close();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(controller.chapterIndex, 0, reason: '会话已失效，不应再自动跳章');
    });
  });

  group('定时跨宿主恢复', () {
    test('按剩余快照续上，不重新计满', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.sleepMode': 'minutes',
        'listen.sleepMinutes': 30,
        'listen.sleep.remainingMs': 30 * 60 * 1000,
        'listen.sleep.savedAtMs': now - 10 * 60 * 1000,
      });
      final controller = build(_FakeTts());
      await start(controller);

      expect(controller.sleepMode, SleepMode.minutes);
      expect(
        controller.sleepMinutes,
        20,
        reason: '30 分钟的定时已过 10 分钟，恢复应是 20 而不是重新计满',
      );
    });

    test('快照已过期：不武装定时', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.sleepMode': 'minutes',
        'listen.sleep.remainingMs': 60 * 1000,
        'listen.sleep.savedAtMs': now - 5 * 60 * 1000,
      });
      final controller = build(_FakeTts());
      await start(controller);

      expect(controller.sleepMode, SleepMode.off);
    });
  });

  group('剩余时间', () {
    test('未知时长 → null；有 duration 后按倍速折算', () async {
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.remaining, isNull, reason: '还没拿到 duration 事件');

      player.feed.durationCtrl.add(const Duration(seconds: 100));
      player.feed.positionCtrl.add(const Duration(seconds: 40));
      await pumpEventQueue();
      expect(controller.remaining, const Duration(seconds: 60));

      await controller.setSpeed(2.0);
      expect(
        controller.remaining,
        const Duration(seconds: 30),
        reason: '2 倍速下 60s 媒体时间 = 30s 真实时间',
      );
    });

    test('位置越过总时长 → 0，绝不出现负数', () async {
      final controller = build(_FakeTts());
      await start(controller);
      player.feed.durationCtrl.add(const Duration(seconds: 60));
      player.feed.positionCtrl.add(const Duration(seconds: 90));
      await pumpEventQueue();
      expect(controller.remaining, Duration.zero);
    });
  });

  group('恢复默认设置', () {
    test('resetAll + reloadSettings：倍速回到默认（内存快照也得重置）', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'listen.speed': 1.8,
        'listen.tts.voice': 'zh-CN-XiaoyiNeural',
      });
      final controller = build(_FakeTts());
      await start(controller);
      expect(controller.speed, 1.8);

      final prefs = await SharedPreferences.getInstance();
      final removed = await ReaderListenSettings(prefs).resetAll();
      expect(removed, greaterThan(0));

      await controller.reloadSettings();
      expect(
        controller.speed,
        1.0,
        reason: '_loadPrefs 用 `?? 旧值` 兜底，不先重置会保留 1.8',
      );
      expect(controller.error, isNull);
    });
  });

  group('失败重试', () {
    test('失败后 errorText 可读；retry 成功后恢复播放', () async {
      // 第一次 synthesize 报 transport（不会降级：fallback 显式给 null）。
      final engine = _FlakyTts(1);
      final controller = build(
        engine,
        fallback: (current, proxy) => null,
      );
      await start(controller);

      expect(controller.errorText, isNotNull);
      expect(
        controller.errorText,
        isNot(contains('TtsException')),
        reason: '内部异常类型不上屏',
      );
      expect(controller.playing, isFalse);

      await controller.retry();

      expect(controller.errorText, isNull);
      expect(controller.playing, isTrue, reason: '重试应重新开播');
    });
  });

  group('拖动定位', () {
    test('seekTo：夹在 0..duration，位置与引擎同步', () async {
      final controller = build(_FakeTts());
      await start(controller);
      player.feed.durationCtrl.add(const Duration(seconds: 100));
      await pumpEventQueue();

      await controller.seekTo(const Duration(seconds: -5));
      expect(player.seeks.last, Duration.zero, reason: '负值夹到 0');
      expect(controller.position, Duration.zero);

      await controller.seekTo(const Duration(seconds: 250));
      expect(
        player.seeks.last,
        const Duration(seconds: 100),
        reason: '超出总时长要夹回',
      );

      await controller.seekTo(const Duration(seconds: 30));
      expect(player.seeks.last, const Duration(seconds: 30));
      expect(controller.position, const Duration(seconds: 30));
    });
  });

  group('定时关闭淡出', () {
    test('淡出期间切章：新章不被暂停，定时仍落回 off', () async {
      var nowMs = 0;
      late ReaderSpeechController controller;
      var waits = 0;
      controller = build(
        _FakeTts(),
        clockMs: () => nowMs,
        fadeSleep: (duration) async {
          waits++;
          if (waits == 1) {
            // 第一次等待时就切章（模拟用户在 3 秒淡出里点了下一章）。
            await Future<void>.delayed(const Duration(milliseconds: 20));
            unawaited(controller.next());
          } else {
            await Future<void>.delayed(const Duration(milliseconds: 5));
          }
        },
      );
      await start(controller);
      await controller.setSleepMode(SleepMode.minutes, minutes: 1);
      player.feed.positionCtrl.add(Duration.zero);
      await pumpEventQueue();
      nowMs += 61000;
      player.feed.positionCtrl.add(const Duration(minutes: 1, seconds: 1));

      // 等淡出（10 步）与切章都跑完。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(controller.chapterIndex, 1, reason: '切章应生效');
      expect(
        controller.playing,
        isTrue,
        reason: '淡出被取消后绝不能把新章 pause 掉',
      );
      expect(controller.sleepMode, SleepMode.off, reason: '定时仍应落回 off');
    });

    test('到点：先渐弱再暂停，最后必须恢复满音量', () async {
      var nowMs = 0;
      final controller = build(_FakeTts(), clockMs: () => nowMs);
      await start(controller);
      expect(controller.playing, isTrue);

      await controller.setSleepMode(SleepMode.minutes, minutes: 1);
      // 首 tick 只建时钟基线，再让墙钟走过 61 秒才判到点。
      player.feed.positionCtrl.add(Duration.zero);
      await pumpEventQueue();
      nowMs += 61000;
      player.feed.positionCtrl.add(const Duration(minutes: 1, seconds: 1));
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(controller.sleepMode, SleepMode.off);
      expect(player.volumes, isNotEmpty);
      expect(player.volumes.any((v) => v < 1.0), isTrue, reason: '要有渐弱过程');
      expect(player.volumes.last, 1.0, reason: '淡出后必须恢复满音量');
      expect(controller.playing, isFalse);
    });
  });
}
