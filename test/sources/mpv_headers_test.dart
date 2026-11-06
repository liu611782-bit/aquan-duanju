import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/mpv_headers.dart';

void main() {
  test('UA 里的逗号用 \\, 转义，不再被百分号编码破坏', () {
    final fields = MpvHeaders.formatHttpHeaderFields(<String, String>{
      'User-Agent': 'Mozilla/5.0 (KHTML, like Gecko) Chrome/120',
      'Referer': 'https://r.example/',
    });
    expect(fields, contains(r'KHTML\, like Gecko'));
    expect(fields, isNot(contains('%2C')));
    expect(fields, contains('Referer: https://r.example/'));
  });

  test('CR/LF 与非法键字符被清理，不注入额外字段', () {
    final fields = MpvHeaders.formatHttpHeaderFields(<String, String>{
      'Bad:Key,Name': 'one\r\ntwo',
      '': 'empty-key',
      'Empty': '',
    });
    expect(fields, 'BadKeyName: one two');
  });

  test('空头表返回空串', () {
    expect(MpvHeaders.formatHttpHeaderFields(const <String, String>{}), '');
  });
}
