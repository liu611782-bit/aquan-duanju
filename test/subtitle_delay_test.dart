import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/player/subtitle_delay.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('SubtitleDelay 纯逻辑', () {
    test('步进 0.5s 并吸附 0.1s 网格', () {
      expect(SubtitleDelay.step(0, 1), 0.5);
      expect(SubtitleDelay.step(0.5, 1), 1.0);
      expect(SubtitleDelay.step(0, -1), -0.5);
      expect(SubtitleDelay.step(0.1 + 0.2, 1), 0.8,
          reason: '0.30000000000000004 应吸附为 0.8');
    });

    test('钳制 ±30s', () {
      expect(SubtitleDelay.clamp(100), 30);
      expect(SubtitleDelay.clamp(-100), -30);
      expect(SubtitleDelay.step(30, 1), 30, reason: '上限不再增加');
      expect(SubtitleDelay.step(-30, -1), -30, reason: '下限不再减少');
    });

    test('文案：0=同步，正数带 +', () {
      expect(SubtitleDelay.label(0), '同步');
      expect(SubtitleDelay.label(0.5), '+0.5s');
      expect(SubtitleDelay.label(-1.0), '-1.0s');
    });
  });

  group('HistoryEntry.subtitleDelayMs 持久化', () {
    test('JSON 往返：有值与 null（旧数据）都容错', () {
      final entry = HistoryEntry(
        seriesId: 's1',
        subtitleDelayMs: 1500,
      );
      final back = HistoryEntry.fromJson(
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      expect(back.subtitleDelayMs, 1500);

      // 旧记录无该键 → null（未设置）。
      final legacy = HistoryEntry.fromJson(<String, dynamic>{
        'series_id': 's2',
      });
      expect(legacy.subtitleDelayMs, isNull);
    });

    test('setPlaybackPrefs 写入且 record 进度回写不丢', () async {
      final tmp = await Directory.systemTemp.createTemp('subtitle_delay_test');
      try {
        final store = HistoryStore(testDirectory: tmp);
        await store.setPlaybackPrefs(
            seriesId: 's1', subtitleDelayMs: -500);
        // 进度回写（record 不携带时差参数）：不得覆盖用户设置。
        await store.record(
          seriesId: 's1',
          title: '剧',
          coverUrl: '',
          episode: 2,
          episodes: 10,
          episodeId: 'e2',
          position: 30,
        );
        final entry = store.get('s1');
        expect(entry?.subtitleDelayMs, -500,
            reason: 'record 合并必须保留按剧字幕时差');
        expect(entry?.episode, 2);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
