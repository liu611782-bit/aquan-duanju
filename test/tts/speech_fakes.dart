/// 听书控制器测试的**共用假件**：假合成引擎 / 假播放器 / 假门面 / 记录型进度 store。
///
/// 单独成一个文件而不是继续抄 `speech_controller_tts_test.dart` 里的私有 `_Fake*`：
/// 本任务新增的两组用例（高亮区间 `test/tts/speech_highlight_test.dart`、派生同源
/// `test/reader_paragraphs_test.dart`）都要走同一条开播链路，抄第三套假件迟早走样。
/// 全程不联网、不碰 libmpv、不写真实目录。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/player/player_engine.dart';
import 'package:aquan_duanju/core/reader/reader_speech_controller.dart';
import 'package:aquan_duanju/core/tts/speech_engine.dart';
import 'package:aquan_duanju/core/tts/tts_cache.dart';
import 'package:aquan_duanju/core/tts/tts_composer.dart';
import 'package:aquan_duanju/core/tts/tts_models.dart';
import 'package:aquan_duanju/core/tts/tts_unit_cache.dart';
import 'package:aquan_duanju/models/audio.dart';
import 'package:aquan_duanju/models/book.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;

/// 造 [count] 个合法 MPEG-2 Layer III 48kbps 帧：每帧 144 字节 = 24ms。
/// 缓存层只认「有音频帧且 ≥1024 字节」。
Uint8List mp3Frames(int count) {
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

/// 每个合成块给的帧数：10 帧 = 240ms，过缓存有效性阈值。
const int framesPerJob = 10;

/// 每个字符念 10ms 的假引擎：字符位**相对 `job.text`**，由 composer 平移成章内坐标。
class FakeTts implements SpeechEngine {
  FakeTts({this.wordBoundary = true, this.failure, this.gate});

  final bool wordBoundary;
  final Object? failure;
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
      audio: mp3Frames(framesPerJob),
      points: points,
      audioMs: framesPerJob * 24,
    );
  }
}

/// 假播放器：只记录调用。
class FakePlayer implements PlayerEngine {
  final FakeStream feed = FakeStream();
  final List<Media> opened = <Media>[];
  final List<String> properties = <String>[];
  final List<Duration> seeks = <Duration>[];
  int playOrPauses = 0;

  @override
  PlayerStream get stream => feed;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> open(Media media, {bool play = true}) async => opened.add(media);

  @override
  Future<void> playOrPause() async => playOrPauses++;

  @override
  Future<void> stop() async {}

  @override
  Future<void> seek(Duration position) async => seeks.add(position);

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setProperty(String name, String value) async =>
      properties.add('$name=$value');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// `PlayerStream` 有 25 个流，只实现控制器真正订阅的那几个。
class FakeStream implements PlayerStream {
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

class StubClient implements AquaClient {
  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async =>
      throw UnsupportedError('测试不该走 FFI：$method');
}

/// 假门面：只覆盖听书链路用到的四个方法。
class FakeApi extends AquaApi {
  FakeApi() : super(StubClient());

  AudioTones tones = const AudioTones(tones: <AudioTone>[]);
  String html = '<p>甲乙。丙丁。</p><p>戊己。</p>';
  AudioStream track = const AudioStream(
    path: 'https://cdn/a.m3u8',
    keyHex: 'AA',
  );
  AudioTimepoints timepoints = const AudioTimepoints();
  int chapterTextCalls = 0;

  /// 音轨预取断言用调用计数（块 B 接线测试消费；既有用例不读这两个数）。
  int audioStreamCalls = 0;
  int audioTimepointsCalls = 0;

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
  ) async {
    audioStreamCalls++;
    return track;
  }

  @override
  Future<AudioTimepoints> audioTimepoints(
    String bookId,
    String itemId,
    int toneId,
  ) async {
    audioTimepointsCalls++;
    return timepoints;
  }
}

/// 听书进度的记录型 store：不碰磁盘，也能断言写入次数。
class RecordingStore extends ListenProgressStore {
  final List<int> positions = <int>[];

  /// 手工放一条「上次听到哪儿」的持久进度。假件以前 `entry()` 恒 null，
  /// 于是「把**另一条**音频的上次毫秒当落点」这类 bug 天生隐形 —— 保位用例
  /// 必须能喂进非 null 才能钉住（design.md §6）。
  int? savedMs;

  @override
  ListenEntry? entry(String bookId) => savedMs == null
      ? null
      : ListenEntry(bookId: bookId, positionMs: savedMs!);

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
  }
}

const List<BookChapter> harnessChapters = <BookChapter>[
  BookChapter(id: 'c1', title: '第一章 起风了', index: 0),
  BookChapter(id: 'c2', title: '第二章 雪停了', index: 1),
];

/// 一套完整的开播环境：临时缓存目录 + 假件 + 被建出来的控制器（统一 dispose）。
class SpeechHarness {
  SpeechHarness(String tag)
    : root = Directory.systemTemp.createTempSync(tag),
      api = FakeApi(),
      player = FakePlayer(),
      store = RecordingStore() {
    cache = TtsCache(rootDirectory: () async => root);
    unitCache = TtsUnitCache(
      root: Directory('${root.path}/audio_cache_units'),
    );
  }

  final Directory root;
  final FakeApi api;
  final FakePlayer player;
  final RecordingStore store;
  late final TtsCache cache;

  /// 流式链路的单元缓存：与整章缓存同根（临时目录），测试之间互不污染。
  late final TtsUnitCache unitCache;

  final List<ReaderSpeechController> controllers = <ReaderSpeechController>[];

  ReaderSpeechController build(
    SpeechEngine engine, {
    ReplaceRuleStore? rules,
    ReaderSettingsStore? settings,
    TtsUnitCache? ttsUnitCache,
  }) {
    final controller = ReaderSpeechController(
      api: api,
      store: store,
      engine: player,
      ttsEngine: engine,
      ttsCache: cache,
      ttsComposer: TtsComposer(),
      ttsUnitCache: ttsUnitCache ?? unitCache,
      rules: rules,
      settings: settings,
    );
    controllers.add(controller);
    return controller;
  }

  Future<void> start(
    ReaderSpeechController controller, {
    String bookId = '7001',
    int chapterIndex = 0,
  }) => controller.start(
    bookId: bookId,
    bookTitle: '一本书',
    coverUrl: '',
    chapters: harnessChapters,
    chapterIndex: chapterIndex,
  );

  /// 灌一个位置事件并等异步链路走完。
  Future<void> pumpPosition(int ms) async {
    player.feed.positionCtrl.add(Duration(milliseconds: ms));
    await pumpEventQueue();
  }

  void dispose() {
    for (final controller in controllers) {
      try {
        controller.dispose();
      } catch (_) {}
    }
    controllers.clear();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }
}
