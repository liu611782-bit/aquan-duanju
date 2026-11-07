import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/search/search_fallback.dart';
import 'package:aquan_duanju/models/models.dart';

AquaPage<SeriesSummary> _page(List<SeriesSummary> items,
        {String cursor = '', bool hasMore = false}) =>
    AquaPage<SeriesSummary>(items: items, cursor: cursor, hasMore: hasMore);

SeriesSummary _item(String id, [String title = '万妖图录']) =>
    SeriesSummary(id: id, title: title);

void main() {
  group('containsCJK', () {
    test('CJK 判定', () {
      expect(containsCJK('万妖图录传'), isTrue);
      expect(containsCJK('万妖ABC'), isTrue);
      expect(containsCJK('ABC123'), isFalse);
      expect(containsCJK(''), isFalse);
    });
  });

  group('degradedQueries', () {
    test('完整剧名：先去尾 1 字（用户实测「万妖图录」可命中），再去 2 字', () {
      expect(degradedQueries('万妖图录传'), ['万妖图录', '万妖']);
    });

    test('4 字剧名：只产出一个 ≥2 字的退化词', () {
      expect(degradedQueries('万妖图录'), ['万妖图']);
    });

    test('短词（<4 字）不退化', () {
      expect(degradedQueries('短剧'), isEmpty);
      expect(degradedQueries('三体'), isEmpty);
    });

    test('非 CJK 不退化', () {
      expect(degradedQueries('ABCD'), isEmpty);
      expect(degradedQueries('12345678'), isEmpty);
    });

    test('退化词长度不足 2 字时截断', () {
      // 5 字 → 4（去1）→ 2（去2）；再往下一步就是 0 字，不会再产。
      expect(degradedQueries('万妖图录传').every((q) => q.length >= 2), isTrue);
    });
  });

  group('searchWithDegradedRetry', () {
    test('原词直接命中：只搜一次，无退化标记', () async {
      final calls = <String>[];
      final result = await searchWithDegradedRetry((q) async {
        calls.add(q);
        return _page([_item('701')]);
      }, '万妖图录');
      expect(calls, ['万妖图录']);
      expect(result.degraded, isFalse);
      expect(result.query, '万妖图录');
      expect(result.page.items.single.id, '701');
    });

    test('全名空、退化命中：按链重试，结果与检索词来自命中层', () async {
      final calls = <String>[];
      final result = await searchWithDegradedRetry((q) async {
        calls.add(q);
        if (q == '万妖图录') return _page([_item('701', '万妖图录')]);
        return _page(const []);
      }, '万妖图录传');
      expect(calls, ['万妖图录传', '万妖图录'],
          reason: '命中即止，不再退化到「万妖」');
      expect(result.degraded, isTrue);
      expect(result.query, '万妖图录');
      expect(result.page.items.single.id, '701');
    });

    test('全链为空：至多重试 2 次（3 次调用），结果为空且不带退化标记', () async {
      final calls = <String>[];
      final result = await searchWithDegradedRetry((q) async {
        calls.add(q);
        return _page(const []);
      }, '万妖图录传');
      expect(calls, ['万妖图录传', '万妖图录', '万妖']);
      expect(result.page.items, isEmpty);
      expect(result.degraded, isFalse, reason: '没有按退化词出结果，UI 不提示');
    });

    test('合并去重：同 id 只留先到的（按 sourceItemId/seriesId）', () async {
      final result = await searchWithDegradedRetry((q) async {
        return _page([_item('701'), _item('701', '万妖图录2'), _item('702')]);
      }, '万妖图录');
      expect(result.page.items.map((s) => s.id).toList(), ['701', '702']);
    });

    test('非 CJK 词为空：不退化重试', () async {
      final calls = <String>[];
      final result = await searchWithDegradedRetry((q) async {
        calls.add(q);
        return _page(const []);
      }, 'ABCD');
      expect(calls, ['ABCD']);
      expect(result.degraded, isFalse);
    });

    test('取消令牌：原词调用后取消，退化重试不再发出', () async {
      var calls = 0;
      final result = await searchWithDegradedRetry(
        (q) async {
          calls++;
          return _page(const []);
        },
        '万妖图录传',
        isCancelled: () => calls >= 1,
      );
      expect(calls, 1, reason: '原词为空后，退化层被取消令牌拦下');
      expect(result.page.items, isEmpty);
    });

    test('发起前已取消：一次都不调用', () async {
      var calls = 0;
      final result = await searchWithDegradedRetry(
        (q) async {
          calls++;
          return _page(const []);
        },
        '万妖图录',
        isCancelled: () => true,
      );
      expect(calls, 0);
      expect(result.degraded, isFalse);
    });

    test('某层抛异常不打断后续退化，异常交给 onError（ErrorLog）', () async {
      final calls = <String>[];
      final errors = <Object>[];
      final result = await searchWithDegradedRetry(
        (q) async {
          calls.add(q);
          if (q == '万妖图录') throw StateError('模拟网络抖动');
          if (q == '万妖') return _page([_item('701')]);
          return _page(const []);
        },
        '万妖图录传',
        onError: (e, st) => errors.add(e),
      );
      expect(errors, hasLength(1));
      expect(calls, ['万妖图录传', '万妖图录', '万妖']);
      expect(result.query, '万妖');
      expect(result.page.items.single.id, '701');
    });

    test('空 id 的条目不参与去重与结果', () async {
      final result = await searchWithDegradedRetry((q) async {
        return _page([_item(''), _item('701')]);
      }, '万妖图录');
      expect(result.page.items.single.id, '701');
    });
  });
}
