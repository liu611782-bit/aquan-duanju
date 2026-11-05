import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/history_rail_collapse.dart';

void main() {
  group('shouldFoldHistoryRail', () {
    test('上滑超过阈值折叠', () {
      expect(
        shouldFoldHistoryRail(
            offset: 121, collapsed: false, manualExpand: false),
        isTrue,
      );
      expect(
        shouldFoldHistoryRail(
            offset: 600, collapsed: false, manualExpand: false),
        isTrue,
      );
    });

    test('阈值以下不折叠', () {
      expect(
        shouldFoldHistoryRail(offset: 0, collapsed: false, manualExpand: false),
        isFalse,
      );
      expect(
        shouldFoldHistoryRail(
            offset: kHistoryFoldOffset, collapsed: false, manualExpand: false),
        isFalse,
      );
    });

    test('已折叠时不再重复触发', () {
      expect(
        shouldFoldHistoryRail(offset: 900, collapsed: true, manualExpand: false),
        isFalse,
      );
    });

    test('手动展开期间不自动折叠', () {
      expect(
        shouldFoldHistoryRail(
            offset: 900, collapsed: false, manualExpand: true),
        isFalse,
      );
    });
  });

  group('shouldUnfoldHistoryRail', () {
    test('折叠且回到顶部时展开', () {
      expect(shouldUnfoldHistoryRail(offset: 0, collapsed: true), isTrue);
      expect(
        shouldUnfoldHistoryRail(offset: kHistoryUnfoldOffset, collapsed: true),
        isTrue,
      );
    });

    test('还没回到顶部不展开', () {
      expect(
        shouldUnfoldHistoryRail(
            offset: kHistoryUnfoldOffset + 1, collapsed: true),
        isFalse,
      );
      expect(shouldUnfoldHistoryRail(offset: 400, collapsed: true), isFalse);
    });

    test('未折叠时不触发', () {
      expect(shouldUnfoldHistoryRail(offset: 0, collapsed: false), isFalse);
    });
  });

  test('阈值方向不会互相打架', () {
    // 折叠阈值必须严格大于展开阈值，否则同一 offset 会同时满足两者。
    expect(kHistoryFoldOffset, greaterThan(kHistoryUnfoldOffset));
  });
}
