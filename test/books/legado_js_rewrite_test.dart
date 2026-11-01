import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/book_rule.dart';
import 'package:aquan_duanju/core/books/legado_js/legado_js_rewrite.dart';

/// legado 规则分段器 + BookRule 拆分收敛的纯 Dart 单测（无 QuickJS）。
void main() {
  group('LegadoJsRewrite.containsJs', () {
    test('<js>/@js:/@webjs:/{{}} 命中；裸 js: 不命中（不误伤）', () {
      expect(LegadoJsRewrite.containsJs('<js>a</js>'), isTrue);
      expect(LegadoJsRewrite.containsJs('sel@js:code'), isTrue);
      expect(LegadoJsRewrite.containsJs('@webjs:abcdef'), isTrue);
      expect(LegadoJsRewrite.containsJs('url?key={{key}}&t={{Date.now()}}'),
          isTrue);
      expect(LegadoJsRewrite.containsJs('javascript:void(0)'), isFalse);
      expect(LegadoJsRewrite.containsJs(r'$.data.list[*]'), isFalse);
    });
  });

  group('LegadoJsRewrite.split', () {
    test('@js: 吃到串尾', () {
      final segs = LegadoJsRewrite.split('sel@js:var r = result;');
      expect(segs, hasLength(2));
      expect(segs.first.isJs, isFalse);
      expect(segs.first.text, 'sel');
      expect(segs.last.isJs, isTrue);
      expect(segs.last.text, 'var r = result;');
    });
    test('<js>…</js> + 尾段', () {
      final segs = LegadoJsRewrite.split(r'<js>JSON.parse(result)</js>$.data');
      expect(segs, hasLength(2));
      expect(segs.first.isJs, isTrue);
      expect(segs.first.text, 'JSON.parse(result)');
      expect(segs.last.isJs, isFalse);
      expect(segs.last.text, r'$.data');
    });
    test('无 js 单段', () {
      final segs = LegadoJsRewrite.split('class.x@tag.a');
      expect(segs, hasLength(1));
      expect(segs.single.isJs, isFalse);
    });
  });

  group('LegadoJsRewrite.splitAlternatives（|| 感知 js/引号）', () {
    test('js 块里的 || 不切', () {
      final parts = LegadoJsRewrite.splitAlternatives(
          r'<js>result.match(/a||b/)</js>tail||backup');
      expect(parts, hasLength(2));
      expect(parts.first, r'<js>result.match(/a||b/)</js>tail');
      expect(parts.last, 'backup');
    });
    test('引号里的 || 不切', () {
      final parts =
          LegadoJsRewrite.splitAlternatives(r"""x@a||y@b""");
      expect(parts, hasLength(2));
    });
  });

  group('LegadoJsRewrite.urlEmbeds', () {
    test('key/page 字面占位排除，其余进列表', () {
      final embeds = LegadoJsRewrite.urlEmbeds(
          'u?key={{key}}&page={{page}}&t={{Date.now()}}');
      expect(embeds, hasLength(1));
      expect(embeds.single.code, 'Date.now()');
    });
  });

  group('BookRule 收敛与诚实报错', () {
    test('splitClean 三形态（与旧 _splitContentRule 等价）', () {
      final (e1, c1) = BookRule.splitClean('a');
      expect(e1, 'a');
      expect(c1, isNull);
      final (e2, c2) = BookRule.splitClean('a##b');
      expect(e2, 'a');
      expect(c2, ('b', ''));
      final (e3, c3) = BookRule.splitClean('a##b##c');
      expect(e3, 'a');
      expect(c3, ('b', 'c'));
    });
    test('XPath 规则诚实报错（不再是笼统 FormatException）', () {
      expect(() => BookRule.evalString('<div>x</div>', '//div/text()'),
          throwsA(isA<FormatException>()));
    });
    test('js 无 runner 的 async 路径诚实报错', () async {
      expect(
        () => BookRule.evalStringAsync('x', '<js>a</js>'),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
