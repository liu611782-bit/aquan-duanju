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
  group('rankBadges 名次按展示顺序连续编号', () {
    test('首页显示第1、第2', () {
      final badges =
          rankBadges([row('a', position: 1), row('b', position: 2)]).badges;
      expect(badges['a'], '第1');
      expect(badges['b'], '第2');
    });

    test('不读 rank：服务端重复 rank=1 也不产生重复名次', () {
      final badges = rankBadges([
        row('a', rank: 1, position: 1),
        row('b', rank: 1, position: 2),
      ]).badges;
      expect(badges['a'], '第1');
      expect(badges['b'], '第2', reason: '服务端两行都给 rank=1，也不能重复');
    });

    test('平台推荐行显示「广告」，但不占号', () {
      final result = rankBadges([
        row('p', position: 10, promoted: true),
        row('a', position: 11),
        row('b', position: 12),
      ], start: 9);
      expect(result.badges['p'], '广告');
      expect(result.badges['a'], '第10', reason: '推荐行不占号，下一张卡接第10');
      expect(result.badges['b'], '第11');
      expect(result.places, 2);
    });

    test('两个推荐行都出「广告」，名次仍连续', () {
      final result = rankBadges([
        row('p1', position: 1, promoted: true),
        row('a', position: 2),
        row('p2', position: 3, promoted: true),
        row('b', position: 4),
      ]);
      expect(result.badges['p1'], '广告');
      expect(result.badges['p2'], '广告');
      expect(result.badges['a'], '第1');
      expect(result.badges['b'], '第2');
      expect(result.places, 2);
    });

    test('position 为 0 的行被跳过', () {
      final result = rankBadges([row('a')]);
      expect(result.badges, isEmpty);
      expect(result.places, 0);
    });

    test('演员行（无 series_id）被跳过', () {
      final result = rankBadges([
        const RankItem(actor: '张三', position: 1),
        row('a', position: 2),
      ]);
      expect(result.badges.length, 1);
      expect(result.badges['a'], '第1');
    });

    test('翻页：名次接着上一页继续，不回到 1 也不跳到 21', () {
      final first = rankBadges([
        for (var i = 1; i <= 10; i++) row('a$i', position: i),
      ]);
      expect(first.badges['a10'], '第10');
      expect(first.places, 10);

      final second = rankBadges([
        for (var i = 11; i <= 20; i++) row('b$i', position: i),
      ], start: first.places);
      expect(second.badges['b11'], '第11');
      expect(second.badges['b20'], '第20');
      expect(second.places, 10);

      final all = {...first.badges, ...second.badges};
      expect(all.values, isNot(contains('第21')));
      expect(all.values, isNot(contains('第31')));
    });

    test('翻页：上一页有广告行时下一页名次不后移', () {
      final first = rankBadges([
        for (var i = 1; i <= 9; i++) row('a$i', position: i),
        row('ad', position: 10, promoted: true),
      ]);
      expect(first.places, 9, reason: '广告行不占号');

      final second = rankBadges(
        [row('b1', position: 11), row('b2', position: 12)],
        start: first.places,
      );
      expect(second.badges['b1'], '第10');
      expect(second.badges['b2'], '第11');
    });
  });
}
