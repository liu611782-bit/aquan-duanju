import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;

import 'package:aquan_duanju/core/books/so_novel_selector.dart';

void main() {
  const html = '''
<div id="root">
  <dl>
    <dt class="a">t1</dt><dd>d1</dd>
    <dt class="b">t2</dt><dd>d2</dd>
    <dt>t3</dt><dd>d3</dd>
  </dl>
  <table><tbody>
    <tr><td class="even">e1</td><td>o1</td><td>x1</td></tr>
  </tbody></table>
  <p id="pagelink"><a class="pgroup">g</a><a href="/n2">2</a><a href="/n3">3</a></p>
  <p class="note">广告 请删除</p>
</div>
''';
  final doc = html_parser.parse(html);
  List<String> texts(String sel) =>
      soNovelSelect(doc, sel).map((e) => e.text.trim()).toList();

  group('so-novel 选择器 shim', () {
    test('基础：class / id / 标签 / 属性', () {
      expect(texts('td.even'), ['e1']);
      expect(texts('#pagelink > a'), ['g', '2', '3']);
      expect(texts('[href]'), ['2', '3']);
      expect(texts('a[href="/n2"]'), ['2']);
    });

    test(':nth-of-type（package:html 不支持，靠 shim）', () {
      expect(texts('td:nth-of-type(3)'), ['x1']);
      expect(texts('dt:nth-of-type(2)'), ['t2']);
    });

    test('中置 nth-of-type + ~ 兄弟（书海阁 toc.item 形状）', () {
      expect(texts('dl > dt:nth-of-type(2) ~ dd'), ['d2', 'd3']);
    });

    test(':not 与相邻兄弟 +', () {
      expect(texts('#pagelink > a:not(.pgroup)'), ['2', '3']);
      expect(texts('a + a'), ['2', '3']);
    });

    test(':nth-child 数字与 even', () {
      expect(texts('dt:nth-child(3)'), ['t2']);
      expect(texts('td:nth-child(even)'), ['o1']);
    });

    test(':contains 文本过滤（package:html 会抛，靠 shim）', () {
      expect(texts('p:contains("广告")'), ['广告 请删除']);
    });

    test('后代组合符', () {
      expect(texts('dl dd'), ['d1', 'd2', 'd3']);
    });

    test('不支持项诚实抛错', () {
      expect(() => texts('p::before'), throwsA(isA<SoNovelSelectorException>()));
      expect(() => texts('p:eq(1)'), throwsA(isA<SoNovelSelectorException>()));
    });
  });
}
