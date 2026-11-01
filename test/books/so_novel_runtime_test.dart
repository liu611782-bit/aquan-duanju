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
      } else if (p == '/book/1.html') {
        await reply('<html><head>'
            '<meta property="og:novel:book_name" content="斗罗">'
            '<meta property="og:novel:author" content="作者甲">'
            '</head><body><div id="info">详情</div></body></html>');
      } else if (p == '/toc.html') {
        await reply('<div id="list"><dl>'
            '<dd><a href="/ch/1.html">第一章</a></dd>'
            '<dd><a href="/ch/2.html">第二章</a></dd></dl></div>');
      } else if (p == '/ch/1.html') {
        await reply('<div id="content">第一段<br>第二段<br>第三段</div>');
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
}
