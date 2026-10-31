import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/book_rule.dart';
import 'package:aquan_duanju/core/books/book_source_model.dart';

void main() {
  group('BookRule.parseSearchUrl / fillUrl', () {
    test('纯 GET 地址直接返回', () {
      final (url, options) =
          BookRule.parseSearchUrl('https://x.example/api/search');
      expect(url, 'https://x.example/api/search');
      expect(options.isPost, isFalse);
    });

    test('逗号尾随 JSON 选项拆出 POST 与 body', () {
      final (url, options) = BookRule.parseSearchUrl(
        'https://x.example/api,'
        '{"method":"POST","body":"searchkey={{key}}&page={{page}}"}',
      );
      expect(url, 'https://x.example/api');
      expect(options.isPost, isTrue);
      expect(options.body, 'searchkey={{key}}&page={{page}}');
    });

    test('占位填充：key URL 编码、page 数字', () {
      final filled = BookRule.fillUrl(
        'https://x.example/s?key={{key}}&p={{page}}',
        key: '斗 破',
        page: 2,
      );
      expect(
        filled,
        'https://x.example/s?key=${Uri.encodeComponent("斗 破")}&p=2',
      );
    });
  });

  group('BookRule JSONPath 简集（真实 JSON API 书源形态）', () {
    final page = jsonDecode('''
      {"data":{"books":[
        {"bookName":"斗破苍穹","author":"天蚕土豆","cover":"https://c/1.jpg",
         "bookUrl":"/book/1","intro":"三十年河东"},
        {"bookName":"凡人修仙传","author":"忘语","cover":"https://c/2.jpg",
         "bookUrl":"/book/2","intro":"一个凡人"}
      ]}}
    ''') as Map<String, dynamic>;

    test(r'列表规则 $.data.books', () {
      final list = BookRule.evalList(page, r'$.data.books');
      expect(list.length, 2);
    });

    test('字段规则取字符串', () {
      final book = BookRule.evalList(page, r'$.data.books').first;
      expect(BookRule.evalString(book, r'$.bookName'), '斗破苍穹');
      expect(BookRule.evalString(book, r'$.author'), '天蚕土豆');
    });

    test('相对地址补全 baseUrl', () {
      final book = BookRule.evalList(page, r'$.data.books').first;
      expect(
        BookRule.evalString(book, r'$.bookUrl', baseUrl: 'https://x.example/'),
        'https://x.example/book/1',
      );
    });
  });

  group('BookRule CSS 简集（真实 HTML 书源形态）', () {
    const page = '''
      <html><body>
        <div class="bookbox" id="b1">
          <h4><a href="/book/1">斗破苍穹</a></h4>
          <span class="author">天蚕土豆</span>
          <img src="https://c/1.jpg">
          <div class="intro"><p>三十年河东</p></div>
        </div>
        <div class="bookbox" id="b2">
          <h4><a href="/book/2">凡人修仙传</a></h4>
          <span class="author">忘语</span>
          <img src="https://c/2.jpg">
          <div class="intro"><p>一个凡人</p></div>
        </div>
      </body></html>
    ''';

    test('列表规则 class.bookbox', () {
      final list = BookRule.evalList(page, 'class.bookbox');
      expect(list.length, 2);
    });

    test('字段规则链式：列表节点内取 title/attr', () {
      final list = BookRule.evalList(page, 'class.bookbox');
      final first = list.first;
      expect(BookRule.evalString(first, 'tag.h4@tag.a@text'), '斗破苍穹');
      expect(
        BookRule.evalString(first, 'tag.h4@tag.a@href',
            baseUrl: 'https://x.example/'),
        'https://x.example/book/1',
      );
      expect(BookRule.evalString(first, 'class.author@text'), '天蚕土豆');
    });

    test('## 清洗：去广告尾巴', () {
      final (expr, clean) = (
        'class.intro@text',
        ('章节错误', ''),
      );
      expect(BookRule.applyClean('正文内容章节错误', clean), '正文内容');
      expect(expr, 'class.intro@text');
    });
  });

  group('BookSource 模型', () {
    test('fromJson 取字段子集；数组与包装格式都吃', () {
      final list = BookSource.listFromJson([
        {
          'bookSourceUrl': 'https://s/a.json',
          'bookSourceName': '源A',
          'enabled': false,
          'searchUrl': 'https://s/a/search?key={{key}}',
          'ruleSearch': {'bookList': r'$.data.books', 'name': r'$.bookName'},
        },
      ]);
      expect(list.length, 1);
      expect(list.first.name, '源A');
      expect(list.first.enabled, isFalse);
      expect(list.first.ruleSearch.bookList, r'$.data.books');
    });

    test('requiresJs：js 规则识别，纯 JSON/CSS 不误报', () {
      final jsSource = BookSource(
        url: 'https://s/js.json',
        ruleSearch: const BookRuleGroup(
          bookList: '<js>JSON.parse(result)</js>',
        ),
      );
      expect(jsSource.requiresJs, isTrue);
      final plain = BookSource(
        url: 'https://s/a.json',
        ruleContent: const BookContentRule(content: 'class.content@text'),
      );
      expect(plain.requiresJs, isFalse);
    });
  });
}
