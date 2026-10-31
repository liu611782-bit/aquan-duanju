import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/player/track_preference.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('TrackPreference', () {
    test('applicable：序号在界内/关闭偏好/越界/未设置', () {
      expect(TrackPreference.applicable(0, 3), isTrue);
      expect(TrackPreference.applicable(2, 3), isTrue);
      expect(TrackPreference.applicable(3, 3), isFalse, reason: '越界');
      expect(TrackPreference.applicable(-2, 3), isFalse);
      expect(TrackPreference.applicable(null, 3), isFalse, reason: '未设置');
      expect(TrackPreference.applicable(TrackPreference.subtitleOff, 0),
          isTrue, reason: '关闭字幕不依赖轨道列表');
    });

    test('subtitleOff 恒为 -1', () {
      expect(TrackPreference.subtitleOff, -1);
    });
  });

  group('HistoryEntry 轨道偏好持久化', () {
    test('JSON 往返：有值与 null（旧数据）都容错', () {
      final entry = HistoryEntry(
        seriesId: 's1',
        audioTrackIndex: 1,
        subtitleTrackIndex: TrackPreference.subtitleOff,
      );
      final back = HistoryEntry.fromJson(
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      expect(back.audioTrackIndex, 1);
      expect(back.subtitleTrackIndex, -1);

      final legacy = HistoryEntry.fromJson(<String, dynamic>{
        'series_id': 's2',
      });
      expect(legacy.audioTrackIndex, isNull);
      expect(legacy.subtitleTrackIndex, isNull);
    });

    test('setPlaybackPrefs 写入且 record 进度回写不丢', () async {
      final tmp = await Directory.systemTemp.createTemp('track_pref_test');
      try {
        final store = HistoryStore(testDirectory: tmp);
        await store.setPlaybackPrefs(
          seriesId: 's1',
          audioTrackIndex: 0,
          subtitleTrackIndex: TrackPreference.subtitleOff,
        );
        await store.record(
          seriesId: 's1',
          title: '剧',
          coverUrl: '',
          episode: 3,
          episodes: 12,
          episodeId: 'e3',
          position: 60,
        );
        final entry = store.get('s1');
        expect(entry?.audioTrackIndex, 0, reason: 'record 合并保留音轨偏好');
        expect(entry?.subtitleTrackIndex, -1, reason: 'record 合并保留关闭字幕偏好');
        expect(entry?.episode, 3);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
