import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/next_episode_prompt.dart';

void main() {
  const consumed = <String>{};

  NextEpisodePrompt? prompt({
    Duration position = const Duration(minutes: 9, seconds: 50),
    Duration duration = const Duration(minutes: 10),
    bool hasNext = true,
    bool autoNext = false,
    bool outroConfigured = false,
    Set<String> consumedSet = consumed,
    String key = 'next',
  }) =>
      nextEpisodePrompt(
        position: position,
        duration: duration,
        hasNext: hasNext,
        autoNext: autoNext,
        outroConfigured: outroConfigured,
        consumed: consumedSet,
        key: key,
      );

  group('nextEpisodePrompt 触发', () {
    test('剩余 15s 内出现，剩余毫秒正确', () {
      final p = prompt(position: const Duration(minutes: 9, seconds: 46));
      expect(p, isNotNull);
      expect(p!.remainingMs, 14000);
      expect(p.autoAdvance, isFalse);
    });

    test('未到阈值不出', () {
      expect(prompt(position: const Duration(minutes: 9, seconds: 44)), isNull);
    });

    test('恰好等于阈值触发（含边界）', () {
      expect(prompt(position: const Duration(minutes: 9, seconds: 45)), isNotNull);
    });

    test('autoNext 映射到 autoAdvance', () {
      expect(prompt(autoNext: true)!.autoAdvance, isTrue);
    });

    test('播完（position >= duration）不出', () {
      expect(prompt(position: const Duration(minutes: 10)), isNull);
    });

    test('时长未知不出；负位置不出', () {
      expect(prompt(duration: Duration.zero), isNull);
      expect(prompt(position: const Duration(seconds: -1)), isNull);
    });
  });

  group('nextEpisodePrompt 边界', () {
    test('最后一集不出', () {
      expect(prompt(hasNext: false), isNull);
    });

    test('已配置片尾不出（走片尾路径，两机制互斥）', () {
      expect(prompt(outroConfigured: true), isNull);
    });

    test('同一集只出现一次（consumed 命中不出）', () {
      final set = <String>{'next'};
      expect(prompt(consumedSet: set), isNull);
    });

    test('片长不足提前量不出（trigger<=0）', () {
      expect(
        prompt(
          position: const Duration(seconds: 5),
          duration: const Duration(seconds: 10),
        ),
        isNull,
      );
    });

    test('自定义 key 隔离', () {
      final set = <String>{'other'};
      expect(prompt(consumedSet: set, key: 'next'), isNotNull);
      expect(prompt(consumedSet: set, key: 'other'), isNull);
    });
  });

  group('消费与释放', () {
    test('consumePrompt 永久消费', () {
      final set = <String>{};
      consumePrompt(set);
      expect(prompt(consumedSet: set), isNull);
      // releasePrompt 后可重新出现（模拟播放器在 seek 回退时释放）
      releasePrompt(set);
      expect(prompt(consumedSet: set), isNotNull);
    });

    test('releasePrompt 对未消费集合是空操作', () {
      final set = <String>{};
      releasePrompt(set);
      expect(set, isEmpty);
    });
  });

  group('seek 回退收起判定', () {
    test('回到阈值区之前超过防抖距离 → 收起', () {
      expect(
        shouldHideNextPromptOnSeek(
          position: const Duration(minutes: 9, seconds: 20),
          duration: const Duration(minutes: 10),
          outroConfigured: false,
        ),
        isTrue,
      );
    });

    test('仍在阈值区内不收起（防抖）', () {
      expect(
        shouldHideNextPromptOnSeek(
          position: const Duration(minutes: 9, seconds: 44),
          duration: const Duration(minutes: 10),
          outroConfigured: false,
        ),
        isFalse,
      );
    });

    test('片尾配置/时长未知不参与判定', () {
      expect(
        shouldHideNextPromptOnSeek(
          position: const Duration(minutes: 9, seconds: 20),
          duration: const Duration(minutes: 10),
          outroConfigured: true,
        ),
        isFalse,
      );
      expect(
        shouldHideNextPromptOnSeek(
          position: const Duration(minutes: 9, seconds: 20),
          duration: Duration.zero,
          outroConfigured: false,
        ),
        isFalse,
      );
    });
  });
}
