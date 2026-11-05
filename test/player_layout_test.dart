import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player_layout.dart';

void main() {
  group('底栏紧凑阈值', () {
    test('常见竖屏手机宽度使用紧凑底栏', () {
      for (final width in <double>[320, 360, 393, 412, 419]) {
        expect(
          useCompactPlayerBar(desktop: false, width: width),
          isTrue,
          reason: '$width 应使用紧凑底栏',
        );
      }
    });

    test('达到阈值后不再紧凑', () {
      expect(useCompactPlayerBar(desktop: false, width: 420), isFalse);
      expect(useCompactPlayerBar(desktop: false, width: 780), isFalse);
    });

    test('桌面端永远不紧凑', () {
      expect(useCompactPlayerBar(desktop: true, width: 360), isFalse);
      expect(useCompactPlayerBar(desktop: true, width: 200), isFalse);
    });

    test('阈值覆盖完整底栏的固定宽度', () {
      // 5 个主按钮 48dp + 睡眠(40) + 倍速(50) + 横竖屏(48) + padding(16)。
      const fixedBarWidth = 5 * 48.0 + 40 + 50 + 48 + 16;
      expect(fixedBarWidth, lessThanOrEqualTo(kCompactPlayerBarWidth));
    });
  });
}
