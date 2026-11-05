import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/discover_channels.dart';
import 'package:aquan_duanju/models/models.dart';

void main() {
  group('kContentTypes', () {
    test('类型顺序与数量', () {
      expect(kContentTypes.map((t) => t.name).toList(), const [
        '短剧',
        '漫剧',
        '电影',
        '小说',
      ]);
      // 漫画 tab 因「进入即黑屏且无法返回」已下线（2026-11-05）；
      // 修复 Venera 源 / 阅读器链路后再把 ContentType 加回。
      expect(kContentTypes.any((t) => t.name == '漫画'), isFalse);
    });

    test('默认类型与默认频道是首项本身', () {
      expect(kContentTypes.first, same(kDefaultContentType));
      expect(kDefaultContentType.channels.first, same(kDefaultChannel));
      expect(kDefaultChannel.name, '推荐');
      expect(kDefaultChannel.value, isEmpty);
    });

    test('短剧有四个频道，榜单频道不向 discover 传频道名', () {
      final shortPlay = kContentTypes.first;
      expect(shortPlay.channels.map((c) => c.name).toList(),
          const ['推荐', '新剧', '热剧', '爆款好剧']);

      final ranking = shortPlay.channels
          .where((c) => c.source == DiscoverSource.ranking)
          .toList();
      expect(ranking.map((c) => c.name).toList(), const ['新剧', '热剧', '爆款好剧']);
      for (final c in ranking) {
        // 这三个名字在 Go core 的 channel.go 里没有映射，传给 discover 就是
        // UNKNOWN → 「出了点小问题，请稍后再试」。
        expect(c.value, isEmpty, reason: '${c.name} 会把未识别的频道名传给 core');
        expect(c.boardKeywords, isNotEmpty, reason: '${c.name} 缺少榜名关键字');
      }
    });

    test('其余类型只有一个频道且取值就是类型名', () {
      for (final type in kContentTypes.skip(1)) {
        expect(type.channels.length, 1, reason: '${type.name} 只有默认频道');
        expect(type.channels.single.value, type.name);
      }
    });

    test('所有榜单频道都不带书城频道名', () {
      for (final type in kContentTypes) {
        for (final c in type.channels
            .where((c) => c.source == DiscoverSource.ranking)) {
          expect(c.value, isEmpty, reason: '${type.name}/${c.name}');
        }
      }
    });

    test('书城频道的取值都是 core 已支持的名字', () {
      const supported = {
        '',
        '真人剧',
        '漫剧',
        '电影',
        '听书',
        '小说',
        '漫画',
      };
      for (final type in kContentTypes) {
        for (final c
            in type.channels.where((c) => c.source == DiscoverSource.feed)) {
          expect(supported, contains(c.value), reason: '${type.name}/${c.name}');
        }
      }
    });

    test('每个类型都有明确的点开行为', () {
      for (final type in kContentTypes) {
        expect(
          type.kind,
          isIn(<ContentKind>[
            ContentKind.video,
            ContentKind.book,
            ContentKind.manga,
            ContentKind.community,
          ]),
          reason: '${type.name} 缺 kind',
        );
      }
      final novel = kContentTypes.firstWhere((t) => t.name == '小说');
      expect(novel.kind, ContentKind.book);
      // 社区不在内容类型条里：它是发现页顶栏的独立入口。
      expect(kContentTypes.any((t) => t.name == '社区'), isFalse);
    });

    test('小说类型直接进阅读器', () {
      final novel = kContentTypes.firstWhere((t) => t.name == '小说');
      expect(novel.kind, ContentKind.book);
    });

    test('漫画类型已从发现页下线', () {
      // 进入即黑屏且无法返回，先整体下线入口；修复后再恢复 ContentKind.manga。
      expect(kContentTypes.any((t) => t.kind == ContentKind.manga), isFalse);
    });
  });

  group('channelKey', () {
    test('带类型前缀，避免「推荐」跨类型串缓存', () {
      expect(channelKey(kDefaultContentType, kDefaultChannel), '短剧/推荐');
      final manju = kContentTypes.firstWhere((t) => t.name == '漫剧');
      expect(channelKey(manju, manju.channels.single), '漫剧/推荐');
    });

    test('所有类型与频道的组合唯一', () {
      final keys = <String>{};
      var total = 0;
      for (final type in kContentTypes) {
        for (final channel in type.channels) {
          total++;
          expect(keys.add(channelKey(type, channel)), isTrue,
              reason: '重复的频道键：${channelKey(type, channel)}');
        }
      }
      expect(keys.length, total);
    });
  });

  group('matchBoard', () {
    const boards = [
      RankBoard(id: 'b1', name: '热搜榜'),
      RankBoard(id: 'b2', name: '热播榜'),
      RankBoard(id: 'b3', name: '新剧榜'),
    ];

    test('按关键字顺序命中第一个', () {
      expect(matchBoard(boards, const ['热播', '热搜'])?.id, 'b2');
      expect(matchBoard(boards, const ['热搜', '热播'])?.id, 'b1');
    });

    test('无命中返回 null', () {
      expect(matchBoard(boards, const ['爆款']), isNull);
    });

    test('没有 id 的榜不参与匹配', () {
      expect(
          matchBoard(const [RankBoard(id: '', name: '热播榜')], const ['热播']),
          isNull);
    });

    test('空关键字跳过', () {
      expect(matchBoard(boards, const ['', '新剧'])?.id, 'b3');
    });
  });

  group('defaultBoard', () {
    test('selected 优先', () {
      const boards = [
        RankBoard(id: 'b1', name: 'A'),
        RankBoard(id: 'b2', name: 'B', selected: true),
      ];
      expect(defaultBoard(boards)?.id, 'b2');
    });

    test('没有 selected 时取第一个', () {
      expect(defaultBoard(const [RankBoard(id: 'b1')])?.id, 'b1');
    });

    test('空列表返回 null', () {
      expect(defaultBoard(const []), isNull);
    });
  });

  group('primaryRankContent', () {
    test('优先「全部」内容', () {
      const contents = [
        RankContent(id: 'human', name: '真人剧', selected: true),
        RankContent(id: 'all', name: '全部'),
      ];
      expect(primaryRankContent(contents)?.id, 'all');
    });

    test('没有 all 时取 selected', () {
      const contents = [
        RankContent(id: 'human', name: '真人剧'),
        RankContent(id: 'comic_series_rank', name: '漫剧', selected: true),
      ];
      expect(primaryRankContent(contents)?.id, 'comic_series_rank');
    });

    test('空目录返回 null', () {
      expect(primaryRankContent(const []), isNull);
    });
  });

  group('rankItemsToSummaries', () {
    test('过滤没有剧集 id 的行并保留顺序', () {
      const items = [
        RankItem(
          rank: 1,
          seriesId: '1001',
          title: '第一部',
          episodeCount: 80,
          coverUrl: 'c1',
        ),
        RankItem(rank: 2, actorId: 'a1', title: '演员行'),
        RankItem(rank: 3, seriesId: ' 1003 ', title: '第三部'),
      ];
      final out = rankItemsToSummaries(items);
      expect(out.map((s) => s.id).toList(), const ['1001', '1003']);
      expect(out.first.title, '第一部');
      expect(out.first.episodeCount, 80);
      expect(out.first.coverUrl, 'c1');
    });

    test('空列表安全', () {
      expect(rankItemsToSummaries(const []), isEmpty);
    });
  });

  group('rankBadges', () {
    test('rank 缺失时回落到 position', () {
      const items = [
        RankItem(position: 1, rank: 1, seriesId: '1001'),
        RankItem(position: 2, rank: 0, seriesId: '1002'),
        RankItem(position: 3, rank: 0, seriesId: ''),
      ];
      expect(rankBadges(items), const {'1001': '第1', '1002': '第2'});
    });

    test('推广行不出角标（它的名次复制了下一行）', () {
      const items = [
        RankItem(position: 4, seriesId: '1004', promoted: true),
        RankItem(position: 5, rank: 5, seriesId: '1005'),
      ];
      expect(rankBadges(items), const {'1005': '第5'});
    });

    test('名次和位置都没有的行不出角标', () {
      expect(rankBadges(const [RankItem(seriesId: '1001')]), isEmpty);
    });
  });
}
