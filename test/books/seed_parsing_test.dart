import 'dart:convert';

import 'package:aquan_duanju/core/books/seed_parsing.dart';
import 'package:aquan_duanju/core/reader/replace_rules.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('书源 JSON 识别', () {
    test('数组 / bookSources 包装 / 单对象都认', () {
      expect(tryDecodeBookSourceJson('[{"bookSourceUrl":"https://a"}]'),
          isA<List>());
      expect(
        tryDecodeBookSourceJson('{"bookSources":[{"bookSourceUrl":"https://a"}]}'),
        isA<List>(),
      );
      expect(tryDecodeBookSourceJson('{"bookSourceUrl":"https://a"}'),
          isA<Map>());
    });

    test('HTML / 空数组 / 坏 JSON 返回 null（不当成有效种子）', () {
      expect(tryDecodeBookSourceJson('<html></html>'), isNull);
      expect(tryDecodeBookSourceJson('[]'), isNull);
      expect(tryDecodeBookSourceJson('[{broken'), isNull);
      expect(tryDecodeBookSourceJson(''), isNull);
    });
  });

  group('索引页抽 JSON 链接', () {
    test('绝对/相对链接都绝对化，同源排前', () {
      const html = '''
<a href="https://other.example/x.json">x</a>
<a href="/sources/a.json">a</a>
<a href="b.json?t=1">b</a>''';
      final links = jsonLinksInHtml(html, baseUrl: 'https://legado.example/');
      expect(links, hasLength(3));
      expect(links.first, 'https://legado.example/sources/a.json');
      expect(links.where((l) => l.contains('other.example')), hasLength(1));
      expect(links.any((l) => l.endsWith('b.json?t=1')), isTrue);
    });

    test('深链 src= 提取出真实地址；非 http 协议丢弃', () {
      const html = '''
<a href="yuedu://import?src=https://site.example/Meow.json">y</a>
<a href="legado://import/bookSource?src=https://site.example/s.json">l</a>
<a href="javascript:void(0)">j</a>
<a href="ftp://x/y.json">f</a>''';
      final links = jsonLinksInHtml(html, baseUrl: 'https://site.example/');
      expect(links, contains('https://site.example/Meow.json'));
      expect(links, contains('https://site.example/s.json'));
      expect(links.any((l) => l.startsWith('legado://')), isFalse);
      expect(links.any((l) => l.startsWith('ftp://')), isFalse);
    });

    test('无链接返回空表', () {
      expect(jsonLinksInHtml('<html></html>', baseUrl: 'https://a/'), isEmpty);
    });
  });

  group('legado 净化规则', () {
    test('name/rule 字段与 isEnabled 映射', () {
      final json = jsonEncode([
        {'name': '去广告', 'rule': r'广告\d+', 'isEnabled': true, 'isRegex': true},
        {'name': '替换', 'rule': '本书由', 'replacement': '', 'isEnabled': false},
        {'name': '坏规则', 'rule': '(['},
      ]);
      final rules = parseLegadoPurificationRules(json);
      expect(rules, hasLength(2), reason: '坏正则应被丢弃');
      expect(rules.first.name, '去广告');
      expect(rules.first.pattern, r'广告\d+');
      expect(rules.last.enabled, isFalse);
    });

    test('replaceRules 包装与单对象也认；非 JSON 返回空', () {
      expect(
        parseLegadoPurificationRules('{"replaceRules":[{"name":"a","rule":"x"}]}'),
        hasLength(1),
      );
      expect(parseLegadoPurificationRules('{"name":"a","rule":"x"}'), hasLength(1));
      expect(parseLegadoPurificationRules('<html>'), isEmpty);
    });
  });
}
