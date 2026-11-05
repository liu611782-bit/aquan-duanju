import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/season_number.dart';

void main() {
  group('seasonOrdinal 三级兜底', () {
    test('index > 0 直接采用', () {
      expect(seasonOrdinal(index: 3, title: '任意标题', position: 0), 3);
      // index 有效时不被标题覆盖。
      expect(seasonOrdinal(index: 2, title: '第九季', position: 5), 2);
    });

    test('index 为 0 时从标题解析阿拉伯数字', () {
      expect(seasonOrdinal(index: 0, title: '万妖图录传第三季', position: 0), 3);
      expect(seasonOrdinal(index: 0, title: '万妖图录传第2部', position: 0), 2);
      expect(seasonOrdinal(index: 0, title: '第 12 季', position: 0), 12);
    });

    test('index 为 0 时从标题解析中文数字', () {
      expect(seasonOrdinal(index: 0, title: '第十季', position: 0), 10);
      expect(seasonOrdinal(index: 0, title: '第十二季', position: 0), 12);
      expect(seasonOrdinal(index: 0, title: '第二十季', position: 0), 20);
      expect(seasonOrdinal(index: 0, title: '第二十三季', position: 0), 23);
    });

    test('全角括号里的季记号也能解析', () {
      expect(seasonOrdinal(index: 0, title: '万妖图录传（第三季）', position: 0), 3);
      expect(seasonOrdinal(index: 0, title: '万妖图录传(第 4 季)', position: 0), 4);
    });

    test('标题无记号时用列表位置 + 1', () {
      expect(seasonOrdinal(index: 0, title: '万妖图录传', position: 0), 1);
      expect(seasonOrdinal(index: 0, title: '万妖图录传', position: 4), 5);
    });

    test('位置非法时回退到 1', () {
      expect(seasonOrdinal(index: 0, title: '万妖图录传', position: -1), 1);
    });

    test('永远不会返回 0', () {
      for (var i = -3; i < 5; i++) {
        expect(
          seasonOrdinal(index: 0, title: '第0季', position: i),
          greaterThanOrEqualTo(1),
        );
        expect(
          seasonOrdinal(index: 0, title: '', position: i),
          greaterThanOrEqualTo(1),
        );
      }
    });
  });

  group('seasonNumberFromTitle', () {
    test('没有季记号返回 null', () {
      expect(seasonNumberFromTitle('万妖图录传'), isNull);
      expect(seasonNumberFromTitle(''), isNull);
      expect(seasonNumberFromTitle('第一集'), isNull);
    });

    test('第0季视为无效', () {
      expect(seasonNumberFromTitle('第0季'), isNull);
    });
  });

  group('seasonTitleLabel', () {
    test('序号 + 原标题', () {
      expect(
        seasonTitleLabel(index: 1, title: '万妖图录传第一季', position: 0),
        '1. 万妖图录传第一季',
      );
      expect(
        seasonTitleLabel(index: 0, title: '万妖图录传第三季', position: 5),
        '3. 万妖图录传第三季',
      );
    });

    test('空标题只留序号', () {
      expect(seasonTitleLabel(index: 2, title: '', position: 0), '2.');
    });

    test('不会出现 0. 前缀', () {
      final label = seasonTitleLabel(index: 0, title: '无名合集', position: 0);
      expect(label.startsWith('0.'), isFalse);
      expect(label, '1. 无名合集');
    });
  });
}
