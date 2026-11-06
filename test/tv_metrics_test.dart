import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_metrics.dart';

void main() {
  group('tvColumnsFor', () {
    test('窄于 900 时 3 列（720p 电视）', () {
      expect(tvColumnsFor(720), 3);
      expect(tvColumnsFor(899), 3);
    });

    test('900 ~ 1199 时 4 列（1080p）', () {
      expect(tvColumnsFor(900), 4);
      expect(tvColumnsFor(1199), 4);
    });

    test('1200 ~ 1599 时 5 列', () {
      expect(tvColumnsFor(1200), 5);
      expect(tvColumnsFor(1599), 5);
    });

    test('1600 及以上 6 列（4K 逻辑像素）', () {
      expect(tvColumnsFor(1600), 6);
      expect(tvColumnsFor(1920), 6);
    });

    test('列数随宽度单调不减', () {
      var last = 0;
      for (final w in <double>[320, 720, 899, 900, 1200, 1600, 2400]) {
        final cols = tvColumnsFor(w);
        expect(cols, greaterThanOrEqualTo(last));
        last = cols;
      }
    });
  });

  test('聚焦放大倍数在合理区间（不遮挡相邻卡片）', () {
    expect(kTvFocusScale, greaterThan(1.0));
    expect(kTvFocusScale, lessThanOrEqualTo(1.1));
  });
}
