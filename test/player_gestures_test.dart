import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player_gestures.dart';

void main() {
  group('longPressZoneAt（宽度 300 时 1/3 = 100，2/3 = 200）', () {
    test('左 1/3 快退', () {
      expect(longPressZoneAt(dx: 0, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 50, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 99.9, width: 300), LongPressZone.rewind);
    });

    test('中 1/3 不响应', () {
      expect(longPressZoneAt(dx: 100, width: 300), LongPressZone.none);
      expect(longPressZoneAt(dx: 150, width: 300), LongPressZone.none);
      expect(longPressZoneAt(dx: 200, width: 300), LongPressZone.none);
    });

    test('右 1/3 快进', () {
      expect(longPressZoneAt(dx: 200.1, width: 300), LongPressZone.forward);
      expect(longPressZoneAt(dx: 260, width: 300), LongPressZone.forward);
      expect(longPressZoneAt(dx: 300, width: 300), LongPressZone.forward);
    });

    test('越界坐标夹到边界内', () {
      expect(longPressZoneAt(dx: -50, width: 300), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 999, width: 300), LongPressZone.forward);
    });

    test('宽度不合法时不响应', () {
      expect(longPressZoneAt(dx: 10, width: 0), LongPressZone.none);
      expect(longPressZoneAt(dx: 10, width: -1), LongPressZone.none);
    });

    test('竖屏手机宽度（393）同样三分', () {
      expect(longPressZoneAt(dx: 60, width: 393), LongPressZone.rewind);
      expect(longPressZoneAt(dx: 196, width: 393), LongPressZone.none);
      expect(longPressZoneAt(dx: 330, width: 393), LongPressZone.forward);
    });
  });
}
