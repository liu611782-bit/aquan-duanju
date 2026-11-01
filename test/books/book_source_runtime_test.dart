import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/book_source_checker.dart';
import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_runtime.dart';

/// runtime 全链路（本地 HTTP 夹具）：书源规则 → HTTP → 解析，离线跑通。
void main() {
  // flutter_test 的 binding 会把 HttpClient 换成一律 400 的 mock；
  // 跑真实本地夹具必须恢复实现（项目既有约定）。
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final path = request.uri.path;
      if (path == '/search') {
        const body = '{"data":{"books":[{"bookName":"斗破苍穹",'
            '"author":"天蚕土豆","bookUrl":"/book/1","cover":"https://c/1.jpg",'
            '"intro":"三十年河东"}]}}';
        await _reply(request, body);
      } else if (path == '/book/1') {
        const body = '<html><body><div id="main">'
            '<h1 class="title">斗破苍穹</h1><em class="author">天蚕土豆</em>'
            '<div class="intro">三十年河东，三十年河西</div>'
            '<a class="toc" href="/book/1/toc">目录</a>'
            '</body></html>';
        await _reply(request, body);
      } else if (path == '/book/1/toc') {
        const body = '<html><body><ul id="list">'
            '<li><a href="/chapter/1">第一章 陨落的天才</a></li>'
            '<li><a href="/chapter/2">第二章 斗之气三段</a></li>'
            '</ul></body></html>';
        await _reply(request, body);
      } else if (path == '/chapter/1') {
        const body = '<html><body><div id="content">三十年河东，三十年河西，'
            '莫欺少年穷。本文出自测试夹具。广告位永远不要出现。</div>'
            '</body></html>';
        await _reply(request, body);
      } else {
        await _reply(request, 'not found', status: 404);
      }
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  // base 是 setUp 里才知道的运行期值：不能用 const 构造。
  // base 是 setUp 里才知道的运行期值：夹具源在测试内构造。
  BookSource sourceFor(String base) => BookSource(
    url: 'https://fixture.example/source.json',
    name: '夹具源',
    searchUrl: '$base/search?key={{key}}&page={{page}}',
    ruleSearch: const BookRuleGroup(
      bookList: r'$.data.books',
      name: r'$.bookName',
      author: r'$.author',
      bookUrl: r'$.bookUrl',
      coverUrl: r'$.cover',
      intro: r'$.intro',
    ),
    ruleBookInfo: const BookRuleGroup(
      name: 'id.main@class.title@text',
      author: 'id.main@tag.em@text',
      intro: 'id.main@class.intro@text',
      tocUrl: 'id.main@class.toc@href',
    ),
    ruleToc: const BookTocRule(
      chapterList: 'id.list@tag.li',
      chapterName: 'tag.a@text',
      chapterUrl: 'tag.a@href',
    ),
    ruleContent: const BookContentRule(
      content: 'id.content@text##广告位永远不要出现##',
    ),
  );

  test('search：JSON 列表 → BookHit（相对地址补全）', () async {
    final rt = BookSourceRuntime(enforceSsrf: false);
    final hits = await rt.search(sourceFor(base), '斗破');
    expect(hits.length, 1);
    expect(hits.first.name, '斗破苍穹');
    expect(hits.first.author, '天蚕土豆');
    expect(hits.first.bookUrl, '$base/book/1');
  });

  test('search：相对 searchUrl 按 bookSourceUrl 补全（修 importSsrf 非法地址）',
      () async {
    final rt = BookSourceRuntime(enforceSsrf: false);
    // 站点根作 bookSourceUrl，searchUrl 给相对路径 + POST 选项，复现真实源的形状。
    final relative = BookSource(
      url: base,
      name: '相对源',
      searchUrl: '/search,{"method":"POST","body":"key={{key}}&page={{page}}"}',
      ruleSearch: sourceFor(base).ruleSearch,
    );
    final hits = await rt.search(relative, '斗破');
    expect(hits.length, 1);
    expect(hits.first.name, '斗破苍穹');
    expect(hits.first.bookUrl, '$base/book/1');
  });

  test('bookInfo + toc：HTML 详情与目录', () async {
    final rt = BookSourceRuntime(enforceSsrf: false);
    final info = await rt.bookInfo(sourceFor(base), '$base/book/1');
    expect(info.name, '斗破苍穹');
    expect(info.author, '天蚕土豆');
    expect(info.tocUrl, '$base/book/1/toc');
    expect(info.chapters.length, 2);
    expect(info.chapters.first.title, '第一章 陨落的天才');
    expect(info.chapters.first.url, '$base/chapter/1');
  });

  test('content：正文 + ## 清洗', () async {
    final rt = BookSourceRuntime(enforceSsrf: false);
    final text = await rt.content(sourceFor(base), '$base/chapter/1');
    expect(text, contains('莫欺少年穷'));
    expect(text, isNot(contains('广告位')));
  });

  test('checker 三连：本地夹具全链路通过（略正文）', () async {
    final checker = BookSourceChecker(
      runtime: BookSourceRuntime(enforceSsrf: false),
    );
    final check = await checker.check(
      sourceFor(base),
      '斗破',
      fetchContent: false,
    );
    expect(check.ok, isTrue);
    expect(check.sampleHit?.name, '斗破苍穹');
    expect(check.sampleChapterCount, 2);
  });

  test('js 规则源被诚实拒绝', () async {
    final jsSource = BookSource(
      url: 'https://fixture.example/js.json',
      searchUrl: '$base/search',
      ruleSearch: BookRuleGroup(bookList: '<js>x</js>'),
    );
    final checker = BookSourceChecker(
      runtime: BookSourceRuntime(enforceSsrf: false),
    );
    final check = await checker.check(jsSource, 'x');
    expect(check.ok, isFalse);
    expect(check.reason, contains('js'));
  });
}

Future<void> _reply(
  HttpRequest request,
  String body, {
  int status = 200,
}) async {
  request.response.statusCode = status;
  request.response.headers.contentType =
      ContentType('text', 'html', charset: 'utf-8');
  request.response.write(body);
  await request.response.close();
}
