import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player_volume.dart';

void main() {
  group('volumeIconFor', () {
    test('0 及以下显示静音图标', () {
      expect(volumeIconFor(0), Icons.volume_off_rounded);
      expect(volumeIconFor(-5), Icons.volume_off_rounded);
    });

    test('低于一半用小喇叭', () {
      expect(volumeIconFor(0.1), Icons.volume_down_rounded);
      expect(volumeIconFor(30), Icons.volume_down_rounded);
      expect(volumeIconFor(49.9), Icons.volume_down_rounded);
    });

    test('一半及以上用大喇叭', () {
      expect(volumeIconFor(50), Icons.volume_up_rounded);
      expect(volumeIconFor(80), Icons.volume_up_rounded);
      expect(volumeIconFor(100), Icons.volume_up_rounded);
    });
  });

  group('showVolumeBar', () {
    test('桌面端达到阈值才显示', () {
      expect(showVolumeBar(desktop: true, width: kVolumeBarMinWidth), isTrue);
      expect(showVolumeBar(desktop: true, width: 1200), isTrue);
    });

    test('桌面端窗口过窄时隐藏', () {
      expect(showVolumeBar(desktop: true, width: kVolumeBarMinWidth - 1),
          isFalse);
      expect(showVolumeBar(desktop: true, width: 380), isFalse);
    });

    test('非桌面端永不显示', () {
      expect(showVolumeBar(desktop: false, width: 400), isFalse);
      expect(showVolumeBar(desktop: false, width: 1200), isFalse);
    });
  });
}
