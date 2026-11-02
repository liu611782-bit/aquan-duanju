import 'package:aquan_duanju/core/tts/tts_unit_queue.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  UnitDurations durations() => UnitDurations([10000, 20000, 30000, 40000]);

  test('begin 从指定单元与偏移开始', () {
    final queue = UnitQueue(durations: durations(), startIndex: 1);
    final events = queue.begin(startMs: 1500);
    expect(events, hasLength(1));
    final play = events.single as UnitPlay;
    expect(play.index, 1);
    expect(play.startMs, 1500);
  });

  test('播到 70% 触发下一段预取，且只触发一次', () {
    final queue = UnitQueue(durations: durations());
    queue.begin();
    expect(queue.onProgress(6999), isEmpty);
    final events = queue.onProgress(7000);
    expect(events.single, isA<UnitPrefetch>());
    expect((events.single as UnitPrefetch).index, 1);
    // 再报进度不重复预取
    expect(queue.onProgress(7500), isEmpty);
  });

  test('最后一段不预取越界单元', () {
    final queue = UnitQueue(durations: durations(), startIndex: 3);
    queue.begin();
    expect(queue.onProgress(39999), isEmpty);
  });

  test('单元播完自动切下一段；末段结束宣告整章完成', () {
    final queue = UnitQueue(durations: durations(), startIndex: 2);
    queue.begin();
    final next = queue.onUnitCompleted();
    expect((next.single as UnitPlay).index, 3);

    final done = queue.onUnitCompleted();
    expect(done.single, isA<UnitQueueFinished>());
    expect(queue.isFinished, isTrue);
    // 结束后不再响应
    expect(queue.onUnitCompleted(), isEmpty);
  });

  test('按整章毫秒定位到「单元 + 单元内偏移」', () {
    final queue = UnitQueue(durations: durations());
    queue.begin();
    // 0-10s=u0, 10-30s=u1, 30-60s=u2, 60-100s=u3
    var play = queue.seekToChapterMs(15000).single as UnitPlay;
    expect(play.index, 1);
    expect(play.startMs, 5000);

    play = queue.seekToChapterMs(45000).single as UnitPlay;
    expect(play.index, 2);
    expect(play.startMs, 15000);

    // 超出总长落在最后一段末尾
    play = queue.seekToChapterMs(999999).single as UnitPlay;
    expect(play.index, 3);
    expect(play.startMs, 40000);
  });

  test('chapterMs / chapterRatio 与单元起点一致', () {
    final queue = UnitQueue(durations: durations(), startIndex: 2);
    queue.begin();
    expect(queue.chapterMs, 30000);
    expect(queue.chapterRatio, closeTo(0.3, 1e-9));
  });

  test('时长未知时按 fallback 估算（不出现 0 导致除零）', () {
    final d = UnitDurations([0, 0, 0], fallbackUnitMs: 5000);
    expect(d[1], 5000);
    expect(d.startOf(2), 10000);
    expect(d.totalMs, 15000);
  });

  test('reset 后重新 begin 会重新预取', () {
    final queue = UnitQueue(durations: durations());
    queue.begin();
    queue.onProgress(8000);
    queue.reset();
    queue.begin();
    expect(queue.onProgress(8000).single, isA<UnitPrefetch>());
  });
}
