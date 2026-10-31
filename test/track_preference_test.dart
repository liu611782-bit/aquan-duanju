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

    test('stableTrackKey：归一化 + 无名轨 null', () {
      expect(
        TrackPreference.stableTrackKey(language: ' Chi ', title: ' 中文配音  2'),
        'chi|中文配音 2',
        reason: '小写 + 空白压扁',
      );
      expect(TrackPreference.stableTrackKey(language: '', title: '   '), isNull);
      expect(TrackPreference.stableTrackKey(), isNull);
    });

    test('uniqueMatchIndex：唯一命中才应用（Pathfin singleOrNull）', () {
      final keys = <String?>['chi|中文', null, 'chi|中文', 'eng'];
      // 命中两条 → 不应用（宁可保持默认，不错配）。
      expect(TrackPreference.uniqueMatchIndex('chi|中文', keys), isNull);
      // 唯一命中。
      expect(TrackPreference.uniqueMatchIndex('eng', keys), 3);
      // 无命中。
      expect(TrackPreference.uniqueMatchIndex('jpn', keys), isNull);
    });
  });

  group('HistoryEntry 轨道偏好持久化', () {
    test('JSON 往返：有值与 null（旧数据）都容错', () {
      final entry = HistoryEntry(
        seriesId: 's1',
        audioTrackIndex: 1,
        subtitleTrackIndex: TrackPreference.subtitleOff,
        audioTrackKey: 'chi|中文',
        subtitleTrackKey: 'eng|english',
      );
      final back = HistoryEntry.fromJson(
          jsonDecode(jsonEncode(entry.toJson())) as Map<String, dynamic>);
      expect(back.audioTrackIndex, 1);
      expect(back.subtitleTrackIndex, -1);
      expect(back.audioTrackKey, 'chi|中文');
      expect(back.subtitleTrackKey, 'eng|english');

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
          audioTrackKey: 'chi|中文',
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
        expect(entry?.audioTrackKey, 'chi|中文', reason: 'record 合并保留身份键');
        expect(entry?.episode, 3);
      } finally {
        await tmp.delete(recursive: true);
      }
    });
  });
}
