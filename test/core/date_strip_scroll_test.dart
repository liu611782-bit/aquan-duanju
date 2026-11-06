import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/date_strip_scroll.dart';

void main() {
  const item = 92.0;
  const viewport = 400.0;
  const count = 15;
  // ListView.builder：两端 padding + N 个固定项宽，减去视口宽度。
  final side = dateStripSidePad(viewport, item);
  final maxExtent = side * 2 + count * item - viewport;

  test('左右留白让首尾都能居中', () {
    expect(side, (viewport - item) / 2);
    expect(dateStripCenterOffset(
        viewport: viewport,
        itemWidth: item,
        index: 0,
        maxScrollExtent: maxExtent), 0);
    expect(
      dateStripCenterOffset(
        viewport: viewport,
        itemWidth: item,
        index: count - 1,
        maxScrollExtent: maxExtent,
      ),
      maxExtent,
    );
  });

  test('任意下标的中心恰好落在视口正中', () {
    for (var i = 0; i < count; i++) {
      final offset = dateStripCenterOffset(
        viewport: viewport,
        itemWidth: item,
        index: i,
        maxScrollExtent: maxExtent,
      );
      final itemCenter = side + (i + 0.5) * item;
      expect(offset + viewport / 2, closeTo(itemCenter, 0.001),
          reason: '第 $i 个日期应居中');
      expect(offset, greaterThanOrEqualTo(0));
      expect(offset, lessThanOrEqualTo(maxExtent));
    }
  });

  test('窄视口退化到最小留白，不会算出负偏移', () {
    expect(dateStripSidePad(60, item), 12);
    final offset = dateStripCenterOffset(
      viewport: 60,
      itemWidth: item,
      index: 3,
      maxScrollExtent: 200,
    );
    expect(offset, greaterThanOrEqualTo(0));
    expect(offset, lessThanOrEqualTo(200));
  });
}
