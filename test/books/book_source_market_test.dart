import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/book_source_market.dart';
import 'package:aquan_duanju/core/books/book_source_seed.dart';

/// 书源仓库扫描编排（本地 HTTP 夹具）：种子抓取→解析 legado 数组→逐源三连校验，
/// 离线跑通，不依赖外网。可达性由设备内扫描负责，这里验证编排逻辑。
void main() {
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      Future<void> reply(
        String body, {
        int status = 200,
        String ctype = 'text/html; charset=utf-8',
      }) async {
        req.response.statusCode = status;
        req.response.headers.contentType = ContentType.parse(ctype);
        req.response.write(body);
        await req.response.close();
      }

      final p = req.uri.path;
      if (p == '/feed') {
        final arr = jsonEncode([
          {
            'bookSourceUrl': base,
            'bookSourceName': '夹具源',
            'searchUrl': '$base/search?key={{key}}',
            'ruleSearch': {
              'bookList': r'$.data.books',
              'name': r'$.bookName',
              'author': r'$.author',
              'bookUrl': r'$.bookUrl',
            },
            'ruleBookInfo': {
              'name': 'id.main@class.title@text',
              'tocUrl': 'id.main@class.toc@href',
            },
            'ruleToc': {
              'chapterList': 'id.list@tag.li',
              'chapterName': 'tag.a@text',
              'chapterUrl': 'tag.a@href',
            },
            'ruleContent': {'content': 'id.content@text##广告位永远不要出现##'},
          },
          {
            'bookSourceUrl': '$base/js',
            'bookSourceName': 'JS源',
            'searchUrl': '$base/search',
            'ruleSearch': {'bookList': '<js>x</js>'},
          },
        ]);
        await reply(arr, ctype: 'application/json; charset=utf-8');
      } else if (p == '/htmlpage') {
        await reply('<html><body>not a feed</body></html>');
      } else if (p == '/search') {
        await reply(
          '{"data":{"books":[{"bookName":"斗破苍穹","author":"天蚕土豆",'
          '"bookUrl":"/book/1","cover":"https://c/1.jpg","intro":"x"}]}}',
          ctype: 'application/json; charset=utf-8',
        );
      } else if (p == '/book/1') {
        await reply('<html><body><div id="main"><h1 class="title">斗破苍穹</h1>'
            '<a class="toc" href="/book/1/toc">目录</a></div></body></html>');
      } else if (p == '/book/1/toc') {
        await reply('<html><body><ul id="list">'
            '<li><a href="/chapter/1">第一章</a></li>'
            '<li><a href="/chapter/2">第二章</a></li></ul></body></html>');
      } else {
        await reply('not found', status: 404);
      }
    });
  });

  tearDown(() async => server.close(force: true));

  test('扫描 feed：解析 2 源，good 三连通过、js 源真实执行（不再入口即拒）', () async {
    final market = BookSourceMarket(enforceSsrf: false);
    final seed = BookSeed(id: 't', name: 't', urls: ['$base/feed']);
    final events = await market.scan(seeds: [seed], query: '斗破').toList();

    final parsed = events.whereType<BookSeedParsed>().toList();
    expect(parsed, hasLength(1));
    expect(parsed.single.sourceCount, 2);

    final checks = events.whereType<BookSourceChecked>().toList();
    expect(checks, hasLength(2));
    expect(checks.any((e) => e.check.ok), isTrue,
        reason: '夹具源应搜书+详情+目录三连通过');
    final js = checks.firstWhere((e) => e.check.source.name == 'JS源').check;
    // js 源走真实执行：bookList js 求值为空 → 搜索无结果（而非「暂不支持」拒绝）。
    expect(js.ok, isFalse);
    expect(js.reason, isNot(contains('暂不支持')));

    final stats = events.whereType<BookScanDone>().single.stats;
    expect(stats.sources, 2);
    expect(stats.ok, 1);
    expect(stats.failedSeeds, 0);
  });

  test('网页型种子（非 JSON 数组）→ BookSeedFailed 且不静默当可用', () async {
    final market = BookSourceMarket(enforceSsrf: false);
    final seed = BookSeed(id: 'h', name: 'h', urls: ['$base/htmlpage']);
    final events = await market.scan(seeds: [seed], query: 'x').toList();

    expect(events.whereType<BookSeedFailed>(), hasLength(1));
    expect(events.whereType<BookScanDone>().single.stats.failedSeeds, 1);
  });

  test('BookSeed.github 生成三镜像，raw 垫底（国内常被重置）', () {
    final urls = BookSeed.github('o/r/br/path.json');
    expect(urls, hasLength(3));
    // 顺序：fastly → cdn → raw（命中即用，不会全跑一遍）
    expect(urls[0], 'https://fastly.jsdelivr.net/gh/o/r@br/path.json');
    expect(urls[1], 'https://cdn.jsdelivr.net/gh/o/r@br/path.json');
    expect(urls[2], 'https://raw.githubusercontent.com/o/r/br/path.json');
  });
}
