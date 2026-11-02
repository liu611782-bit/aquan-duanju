import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/so_novel_runtime.dart';
import 'package:aquan_duanju/core/books/so_novel_source.dart';

/// so-novel 运行时端到端（本地 HTTP 夹具，注入桩 runJs，不依赖 flutter_qjs）。
void main() {
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late String base;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final p = req.uri.path;
      Future<void> reply(String body) async {
        req.response
          ..statusCode = 200
          ..headers.contentType = ContentType('text', 'html', charset: 'utf-8')
          ..write(body);
        await req.response.close();
      }

      if (p == '/waps.php') {
        await reply('<div id="checkform"><table><tbody><tr>'
            '<td class="even"><a href="/book/1.html">斗罗</a></td>'
            '<td>x</td><td>作者甲</td></tr></tbody></table></div>');
      } else if (p == '/search_p1.html') {
        // 搜索分页：多页码 <a> 一次拿全（page1 命中 + page2 链接）。
        await reply('<div id="box"><dl><dt><a href="/book/1.html">书甲</a></dt></dl></div>'
            '<div id="pg"><a class="pgroup">上一页</a>'
            '<a href="/search_p2.html">2</a></div>');
      } else if (p == '/search_p2.html') {
        await reply('<div id="box"><dl><dt><a href="/book/2.html">书乙</a></dt></dl></div>'
            '<div id="pg"><a class="pgroup">上一页</a></div>');
      } else if (p == '/book/1.html') {
        await reply('<html><head>'
            '<meta property="og:novel:book_name" content="斗罗">'
            '<meta property="og:novel:author" content="作者甲">'
            '</head><body><div id="info">详情</div></body></html>');
      } else if (p == '/toc.html') {
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/1.html">第一章</a></dd>'
            '<dd><a href="/ch/2.html">第二章</a></dd></dl></div>');
      } else if (p == '/toc_pages.html') {
        // 目录分页：下拉 option 一次拿全（含第 1 页自身）。
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/1.html">第一章</a></dd>'
            '<dd><a href="/ch/2.html">第二章</a></dd></dl></div>'
            '<select id="pages">'
            '<option value="/toc_pages.html">1</option>'
            '<option value="/toc_pages2.html">2</option>'
            '</select>');
      } else if (p == '/toc_pages2.html') {
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/3.html">第三章</a></dd>'
            '<dd><a href="/ch/4.html">第四章</a></dd></dl></div>');
      } else if (p == '/toc_rec.html') {
        // 目录分页：单个「下一页」链接递归。
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/1.html">第一章</a></dd></dl></div>'
            '<div id="np"><a href="/toc_rec2.html">下一页</a></div>');
      } else if (p == '/toc_rec2.html') {
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/2.html">第二章</a></dd></dl></div>');
      } else if (p == '/ch/1.html') {
        await reply('<div id="content">第一段<br>第二段<br>第三段</div>');
      } else if (p == '/ch_p1.html') {
        // 正文分页：#np 链到第 2 页（按钮文本「下一页」→ 继续拼）。
        await reply('<div id="content">前半段<br></div>'
            '<div id="np"><a href="/ch_p2.html">下一页</a></div>');
      } else if (p == '/ch_p2.html') {
        // 第 2 页的按钮文本「下一章」→ 终止分页。
        await reply('<div id="content">后半段</div>'
            '<div id="np"><a href="/ch/2.html">下一章</a></div>');
      } else {
        await reply('nf');
      }
    });
  });

  tearDown(() async => server.close(force: true));

  SoRule rule() => SoRule.fromJson(<String, dynamic>{
        'url': base,
        'name': '夹具so',
        'search': {
          'url': '$base/waps.php',
          'method': 'get',
          'result': '#checkform > table > tbody > tr',
          'bookName': 'td.even > a',
          'author': 'td:nth-of-type(3)',
        },
        'book': <String, dynamic>{},
        'toc': {'url': '$base/toc.html', 'item': '#list dd a'},
        'chapter': {
          'content': '#content',
          'paragraphTagClosed': false,
          'paragraphTag': '<br>+',
        },
      });

  SoNovelRuntime rt() =>
      SoNovelRuntime(enforceSsrf: false, runJs: (code, input) => input);

  test('search：容器→书名/作者/绝对URL', () async {
    final hits = await rt().search(rule(), '斗罗');
    expect(hits, hasLength(1));
    expect(hits.first.name, '斗罗');
    expect(hits.first.author, '作者甲');
    expect(hits.first.bookUrl, '$base/book/1.html');
    expect(hits.first.isMeaningful, isTrue);
  });

  test('bookInfo：meta 回落书名/作者', () async {
    final meta = await rt().bookInfo(rule(), '$base/book/1.html');
    expect(meta.name, '斗罗');
    expect(meta.author, '作者甲');
  });

  test('toc：item 选择器→章节标题与绝对URL', () async {
    final chapters = await rt().toc(rule(), '$base/book/1.html');
    expect(chapters, hasLength(2));
    expect(chapters.first.title, '第一章');
    expect(chapters.first.url, '$base/ch/1.html');
  });

  test('content：#content + <br> 分段', () async {
    final text = await rt().content(rule(), '$base/ch/1.html');
    expect(text, '第一段\n第二段\n第三段');
  });

  test('search.nextPage：分页结果 union 去重', () async {
    final r = SoRule.fromJson(<String, dynamic>{
      'url': base,
      'name': '夹具so',
      'search': {
        'url': '$base/search_p1.html',
        'method': 'get',
        'result': '#box dl dt',
        'bookName': 'a',
        'nextPage': '#pg a:not(.pgroup)',
      },
      'book': <String, dynamic>{},
      'toc': {'item': '#list dd a'},
      'chapter': {'content': '#content'},
    });
    final hits = await rt().search(r, 'x');
    // page1 命中书甲 + 分页链接补抓 page2 命中书乙。
    expect(hits.map((h) => h.name), containsAll(['书甲', '书乙']));
    expect(hits.map((h) => h.bookUrl).toSet().length, hits.length);
  });

  test('toc.nextPage：下拉 option 一次拿全', () async {
    final r = SoRule.fromJson(<String, dynamic>{
      'url': base,
      'name': '夹具so',
      'book': <String, dynamic>{},
      'toc': {
        'url': '$base/toc_pages.html',
        'item': '#list dd a',
        'nextPage': '#pages option',
      },
      'chapter': {'content': '#content'},
    });
    final chapters = await rt().toc(r, '$base/book/1.html');
    expect(chapters.map((c) => c.title),
        ['第一章', '第二章', '第三章', '第四章']);
  });

  test('toc.nextPage：单链接递归', () async {
    final r = SoRule.fromJson(<String, dynamic>{
      'url': base,
      'name': '夹具so',
      'book': <String, dynamic>{},
      'toc': {
        'url': '$base/toc_rec.html',
        'item': '#list dd a',
        'nextPage': '#np a',
      },
      'chapter': {'content': '#content'},
    });
    final chapters = await rt().toc(r, '$base/book/1.html');
    expect(chapters.map((c) => c.title), ['第一章', '第二章']);
  });

  test('chapter.nextPage：分页正文拼接，按钮文本「下一章」终止', () async {
    final r = SoRule.fromJson(<String, dynamic>{
      'url': base,
      'name': '夹具so',
      'book': <String, dynamic>{},
      'toc': {'item': '#list dd a'},
      'chapter': {'content': '#content', 'nextPage': '#np a'},
    });
    final text = await rt().content(r, '$base/ch_p1.html');
    expect(text, '前半段\n后半段');
  });

  test('XPath 选择器（so-novel 混用 XPath 的源）', () async {
    // 注意：so-novel DSL 在第一个 `@` 处截断选择器（上游 HtmlExtractor 同款），
    // 故 XPath 谓词 `[@id=…]` 不可用——真实 so-novel XPath 源同样受此限制。
    final r = SoRule.fromJson(<String, dynamic>{
      'url': base,
      'name': '夹具so',
      'book': <String, dynamic>{},
      'toc': {'url': '$base/toc.html', 'item': r'//dl/dd/a'},
      'chapter': {'content': r'//div'},
    });
    final chapters = await rt().toc(r, '$base/book/1.html');
    expect(chapters, hasLength(2));
    expect(chapters.first.url, '$base/ch/1.html');
    final text = await rt().content(r, '$base/ch/1.html');
    expect(text, '第一段\n第二段\n第三段');
  });
}
