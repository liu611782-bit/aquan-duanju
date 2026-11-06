import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/discover_channels.dart';
import 'package:aquan_duanju/models/models.dart';

RankItem row(
  String id, {
  int rank = 0,
  int position = 0,
  bool promoted = false,
}) =>
    RankItem(
      seriesId: id,
      title: id,
      rank: rank,
      position: position,
      promoted: promoted,
    );

void main() {
  group('rankBadges 使用 Go 侧已全局化的 position', () {
    test('首页显示第1、第2', () {
      final badges = rankBadges([row('a', position: 1), row('b', position: 2)]);
      expect(badges['a'], '第1');
      expect(badges['b'], '第2');
    });

    test('第二页直接用全局 position，不再叠加已加载条数', () {
      final badges = rankBadges([
        row('x', position: 11),
        row('y', position: 12),
      ]);
      expect(badges['x'], '第11');
      expect(badges['y'], '第12');
    });

    test('回归：首页 1~10，第二页必须 11~20，不能跳到 21', () {
      final first = rankBadges([
        for (var i = 1; i <= 10; i++) row('a$i', position: i),
      ]);
      final second = rankBadges([
        for (var i = 11; i <= 20; i++) row('b$i', position: i),
      ]);
      expect(first['a10'], '第10');
      expect(second['b11'], '第11');
      expect(second['b20'], '第20');
      expect(second.values, isNot(contains('第21')));
      expect(second.values, isNot(contains('第31')));
    });

    test('忽略不可靠的 rank：重复 rank 不再产生重复名次', () {
      final badges = rankBadges([
        row('a', rank: 1, position: 1),
        row('b', rank: 1, position: 2),
      ]);
      expect(badges['a'], '第1');
      expect(badges['b'], '第2', reason: '服务端两行都给 rank=1，也不能重复');
    });

    test('rank 有值也不参与计算', () {
      final badges = rankBadges([row('a', rank: 5, position: 21)]);
      expect(badges['a'], '第21');
    });

    test('平台推荐行不显示名次，但仍占一个位置', () {
      final badges = rankBadges([
        row('p', rank: 1, position: 1, promoted: true),
        row('a', rank: 2, position: 2),
      ]);
      expect(badges.containsKey('p'), isFalse);
      expect(badges['a'], '第2');
    });

    test('position 为 0 的行被跳过', () {
      expect(rankBadges([row('a')]), isEmpty);
    });

    test('演员行（无 series_id）被跳过', () {
      final badges = rankBadges([
        const RankItem(actor: '张三', position: 1),
        row('a', position: 2),
      ]);
      expect(badges.length, 1);
      expect(badges['a'], '第2');
    });

    test('多页名次连续且互不覆盖', () {
      final seen = <String, String>{};
      var place = 1;
      for (var page = 0; page < 3; page++) {
        final items = <RankItem>[];
        for (var i = 0; i < 10; i++) {
          items.add(row('p${page}_$i', position: place++));
        }
        seen.addAll(rankBadges(items));
      }
      expect(seen.length, 30);
      expect(seen['p0_0'], '第1');
      expect(seen['p1_0'], '第11');
      expect(seen['p2_0'], '第21');
      expect(seen['p2_9'], '第30');
    });
  });
}
