/// S3.2 接线：流式朗读真的接到了控制器上（首段即播 / 位置换算 / 切段 / 拖动 / 回滚）。
///
/// 断言只碰**对外可观察量**：打开过哪些文件、`position`/`duration`、合成调用次数。
/// 内部状态（会话、单元指针）不直接读 —— 接线错了就应该在这些数字上露出来。
library;

import 'dart:io';

import 'package:aquan_duanju/core/tts/tts_unit_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'speech_fakes.dart';

/// 默认正文：两段 = 两个合成单元（同段内短句合并，不跨段合并）。
const String _html = '<p>甲乙。丙丁。</p><p>戊己。</p>';

Future<void> _waitFor(bool Function() predicate, {String? reason}) async {
  for (var i = 0; i < 300; i++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail(reason ?? '等待超时');
}

bool _hasChapterIndex(TtsUnitCache cache) {
  final dir = Directory(cache.root.path);
  if (!dir.existsSync()) return false;
  return dir
      .listSync(recursive: true)
      .whereType<File>()
      .any((file) => file.path.endsWith('index.json'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SpeechHarness harness;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'listen.tts.streaming': true,
      // 关掉自动连播：本章结束后的切章会污染「打开了几个文件」的断言。
      'listen.autoNext': false,
    });
    harness = SpeechHarness('streaming_wiring');
    harness.api.html = _html;
  });

  tearDown(() => harness.dispose());

  test('首单元写完就开播，不等整章', () async {
    final tts = FakeTts();
    final controller = harness.build(tts);
    await harness.start(controller);
    await pumpEventQueue();

    expect(harness.player.opened, hasLength(1));
    expect(harness.player.opened.single.uri, endsWith('u000.mp3'));
    // 只允许「当前单元 + 一个预取」两发请求：首播延迟不该由整章决定。
    expect(tts.calls, lessThanOrEqualTo(2));
  });

  test('位置事件换算成章内毫秒；播完自动切下一段', () async {
    final controller = harness.build(FakeTts());
    await harness.start(controller);
    await pumpEventQueue();

    await harness.pumpPosition(100);
    expect(controller.position, const Duration(milliseconds: 100));
    expect(controller.paragraphIndex, 0);

    harness.player.feed.completedCtrl.add(true);
    // 切段要等第 1 段落盘（可能还在预取）：等到真的 open 才算接线成功。
    await _waitFor(
      () => harness.player.opened.length == 2,
      reason: '播完第 0 段要 open 第 1 段',
    );
    expect(harness.player.opened.last.uri, endsWith('u001.mp3'));
    expect(
      controller.position,
      const Duration(milliseconds: 240),
      reason: '切段后位置是「新单元起点」，不是归零',
    );

    await harness.pumpPosition(60);
    expect(
      controller.position,
      const Duration(milliseconds: 300),
      reason: '章内毫秒 = Σ前序单元时长 + 单元内毫秒',
    );
    expect(controller.paragraphIndex, 1);
  });

  test('拖动到后面的单元：切文件 + 单元内 offset', () async {
    final controller = harness.build(FakeTts());
    await harness.start(controller);
    // 等第 1 段预取完成：总时长 480ms 才谈得上「章内 300ms」这个落点。
    await _waitFor(
      () => controller.duration.inMilliseconds >= 480,
      reason: '两段都产出后章总长才是 480ms',
    );

    await controller.seekTo(const Duration(milliseconds: 300));
    await pumpEventQueue();

    expect(harness.player.opened, hasLength(2));
    expect(harness.player.opened.last.uri, endsWith('u001.mp3'));
    expect(harness.player.seeks.last, const Duration(milliseconds: 60));
    expect(controller.position, const Duration(milliseconds: 300));
  });

  test('整章缓存命中后重开：零合成、直接播第一段', () async {
    final tts = FakeTts();
    final controller = harness.build(tts);
    await harness.start(controller);
    await _waitFor(
      () => _hasChapterIndex(harness.unitCache),
      reason: '全部单元写完才落 index.json',
    );

    await controller.close();
    await pumpEventQueue();
    final callsBefore = tts.calls;

    await harness.start(controller);
    await pumpEventQueue();
    expect(controller.errorText, isNull);
    expect(harness.player.opened.last.uri, endsWith('u000.mp3'));
    expect(tts.calls, callsBefore, reason: '命中缓存不许再合成一次');
  });

  test('开关关掉：回到整章单文件老路径', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'listen.tts.streaming': false,
      'listen.autoNext': false,
    });
    final controller = harness.build(FakeTts());
    await harness.start(controller);
    await pumpEventQueue();

    expect(harness.player.opened, hasLength(1));
    expect(
      harness.player.opened.single.uri,
      isNot(contains('u000.mp3')),
      reason: '开关关 = 完全走整章合成，不许再碰单元目录',
    );
  });
}
