import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/search/suggest_submit.dart';
import 'package:aquan_duanju/models/models.dart';

void main() {
  group('suggestSubmitText', () {
    test('纯数字 keyword（内容 ID）回落显示文本', () {
      expect(
        suggestSubmitText(const Suggestion(
            text: '万妖图录传第十四季', keyword: '7700926270980246552')),
        '万妖图录传第十四季',
      );
    });

    test('正常文本 keyword 原样提交', () {
      expect(
        suggestSubmitText(
            const Suggestion(text: '万妖图录传', keyword: '万妖图录传')),
        '万妖图录传',
      );
      expect(
        suggestSubmitText(const Suggestion(text: '万妖图录传', keyword: '万妖图录')),
        '万妖图录',
      );
    });

    test('keyword 为空回落显示文本', () {
      expect(suggestSubmitText(const Suggestion(text: '万妖图录传')), '万妖图录传');
      expect(suggestSubmitText(const Suggestion(text: '万妖图录传', keyword: '  ')),
          '万妖图录传');
    });

    test('含字母/符号的 keyword 不是内容 ID，原样提交', () {
      expect(
        suggestSubmitText(
            const Suggestion(text: '万妖图录传', keyword: '万妖图录传2024')),
        '万妖图录传2024',
      );
      expect(
        suggestSubmitText(
            const Suggestion(text: '剧名', keyword: 'abc123')),
        'abc123',
      );
    });
  });
}
