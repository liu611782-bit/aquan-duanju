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
  group('rankBadges 跨页名次', () {
    test('首页无偏移：第1、第2', () {
      final badges = rankBadges([row('a', position: 1), row('b', position: 2)]);
      expect(badges['a'], '第1');
      expect(badges['b'], '第2');
    });

    test('第二页按已加载原始条目数接续', () {
      final badges = rankBadges(
        [row('x', position: 1), row('y', position: 2)],
        offset: 24,
      );
      expect(badges['x'], '第25');
      expect(badges['y'], '第26');
    });

    test('忽略不可靠的 rank：重复 rank 不再产生重复名次', () {
      final badges = rankBadges([
        row('a', rank: 1, position: 1),
        row('b', rank: 1, position: 2),
      ]);
      expect(badges['a'], '第1');
      expect(badges['b'], '第2', reason: '服务端两行都给 rank=1，也不能重复');
    });

    test('rank 有值也不参与计算，只用 position + offset', () {
      final badges = rankBadges([row('a', rank: 5, position: 1)], offset: 20);
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

    test('页内序号为 0 的行被跳过，不会被偏移成有效名次', () {
      final badges = rankBadges([row('a')], offset: 30);
      expect(badges, isEmpty);
    });

    test('演员行（无 series_id）被跳过', () {
      final badges = rankBadges([
        const RankItem(actor: '张三', position: 1),
        row('a', position: 2),
      ]);
      expect(badges.length, 1);
      expect(badges['a'], '第2');
    });

    test('翻三页时偏移可累加（模拟调用方累计 rawCount）', () {
      var offset = 0;
      final seen = <String, String>{};
      for (final page in const [24, 24, 24]) {
        final items = [
          for (var i = 1; i <= 3; i++)
            row('p$offset-$i', position: i),
        ];
        seen.addAll(rankBadges(items, offset: offset));
        offset += page;
      }
      expect(seen['p0-1'], '第1');
      expect(seen['p24-1'], '第25');
      expect(seen['p48-1'], '第49');
    });
  });
}
