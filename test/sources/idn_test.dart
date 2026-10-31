// IDN/Punycode 单测：RFC 3492 教科书用例 + uriForRequest 归一。
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/idn.dart';

void main() {
  test('punycodeEncode：RFC 3492 教科书用例', () {
    expect(punycodeEncode('München'), 'mnchen-3ya');
    expect(punycodeEncode('Bücher'), 'bcher-kva');
    expect(punycodeEncode('中国'), isNotEmpty, reason: 'CJK 覆盖');
  });

  test('punycodeEncode：纯 ASCII 原样返回', () {
    expect(punycodeEncode('example'), 'example');
    expect(punycodeEncode('c.icu'), 'c.icu');
  });

  test('uriForRequest：百分号编码 IDN host → xn-- ASCII（连接层可用的形态）', () {
    final uri = uriForRequest(
        'http://c.%E5%B0%8F%E8%83%A1.icu/api.php/provide/vod?ac=videolist&pg=1');
    expect(uri.host.contains('%'), isFalse, reason: 'host 不得残留 %（Socket 层会当 IPv6 scope）');
    expect(uri.host.startsWith('c.xn--'), isTrue);
    expect(uri.host.endsWith('.icu'), isTrue);
    expect(uri.path, '/api.php/provide/vod');
    expect(uri.queryParameters['ac'], 'videolist');
  });

  test('uriForRequest：纯 ASCII URL 原样', () {
    const url = 'http://api.example.com/vod?ac=videolist&pg=1';
    final uri = uriForRequest(url);
    expect(uri.host, 'api.example.com');
    expect(uri.queryParameters['pg'], '1');
  });
}
