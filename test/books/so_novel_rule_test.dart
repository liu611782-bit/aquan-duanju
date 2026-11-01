import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:aquan_duanju/core/books/so_novel_rule.dart';
import 'package:aquan_duanju/core/books/so_novel_source.dart';

void main() {
  const html = '''
<div id="root">
  <table><tbody><tr>
    <td class="even"><a href="/book/1.html">书名</a></td>
    <td>o1</td><td>作者甲</td>
  </tr></tbody></table>
  <meta name="og:description" content="简介文本">
  <img src="/cover.jpg">
  <p id="b64">aGVsbG8=</p>
  <p id="dash">a-b-c</p>
</div>
''';
  final doc = html_parser.parse(html);
  const base = 'http://ex.com/x/';

  group('SoNovelRule 解析', () {
    test('selectorOf / contentTypeOf / stepsOf', () {
      expect(SoNovelRule.selectorOf('td.even > a@href'), 'td.even > a');
      expect(SoNovelRule.contentTypeOf('a@href').name, 'href');
      expect(SoNovelRule.contentTypeOf('img@src').name, 'src');
      expect(
        SoNovelRule.contentTypeOf('meta[name="x"]').name, 'content');
      expect(SoNovelRule.contentTypeOf('p').name, 'text');
      final steps =
          SoNovelRule.stepsOf('p@js:r=r.replace(/a/,"b");@java:base64.decode()');
      expect(steps.map((s) => s.lang).toList(), ['js', 'java']);
      expect(steps.first.code, contains('r.replace'));
    });
  });

  group('SoNovelRule.extract 内容抽取', () {
    test('text / @href 绝对化 / meta content / @src', () {
      expect(SoNovelRule.extract(doc, 'td.even > a'), '书名');
      expect(
        SoNovelRule.extract(doc, 'td.even > a@href', baseUri: base),
        'http://ex.com/book/1.html',
      );
      expect(
        SoNovelRule.extract(doc, 'meta[name="og:description"]'),
        '简介文本',
      );
      expect(SoNovelRule.extract(doc, 'img@src', baseUri: base),
          'http://ex.com/cover.jpg');
    });

    test('@java:base64.decode()', () {
      expect(
        SoNovelRule.extract(doc, '#b64@java:base64.decode()'),
        'hello',
      );
    });

    test('@java:string.replace(a,b) 走正则语义', () {
      expect(
        SoNovelRule.extract(doc, r"#dash@java:string.replace('-','_')"),
        'a_b_c',
      );
    });

    test('@js: 经注入 runner；缺 runner 诚实抛错', () {
      final out = SoNovelRule.extract(doc, '#dash@js:wrapped',
          runJs: (code, input) => '[$code<$input>]');
      expect(out, '[wrapped<a-b-c>]');
      expect(
        () => SoNovelRule.extract(doc, '#dash@js:x'),
        throwsA(isA<Exception>()),
      );
    });

    test('空选择器/无命中返回空串', () {
      expect(SoNovelRule.extract(doc, 'nope'), '');
      expect(SoNovelRule.extract(doc, ''), '');
    });
  });

  group('SoRule 反序列化（真实源形状）', () {
    test('香书小说（research §1.8 A）', () {
      final rule = SoRule.fromJson(<String, dynamic>{
        'url': 'http://www.ibiqugu.net/',
        'name': '香书小说',
        'search': {
          'url': 'http://www.ibiqugu.net/modules/article/waps.php',
          'method': 'post',
          'data': '{searchkey: %s}',
          'result': '#checkform > table > tbody > tr',
          'bookName': 'td.even > a',
          'author': 'td:nth-of-type(3)',
        },
        'toc': {'item': '#list > dl > dd > a'},
        'chapter': {
          'title': '.bookname > h1',
          'content': '#content',
          'paragraphTagClosed': false,
          'paragraphTag': '<br>+',
        },
      });
      expect(rule.name, '香书小说');
      expect(rule.search?.method, 'post');
      expect(rule.search?.bookName, 'td.even > a');
      expect(rule.toc.item, '#list > dl > dd > a');
      expect(rule.chapter.paragraphTag, '<br>+');
      expect(rule.chapter.paragraphTagClosed, isFalse);
    });
  });
}
