import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/hls_adfilter.dart';

void main() {
  test('EXT-X-KEY 的密钥 URI 也经代理，且相对分片继承父清单 query', () {
    const text = '#EXTM3U\n'
        '#EXT-X-KEY:METHOD=AES-128,URI="key.key"\n'
        '#EXT-X-MAP:URI="init.mp4"\n'
        '#EXTINF:5.0,\n'
        'seg1.ts\n'
        '#EXT-X-ENDLIST\n';
    final rewritten = HlsAdFilter.rewriteManifest(
      text,
      Uri.parse('https://cdn.example.com/a.m3u8?token=T'),
      (abs) => 'PROXY<$abs>',
    );
    expect(rewritten,
        contains('URI="PROXY<https://cdn.example.com/key.key?token=T>"'));
    expect(rewritten,
        contains('URI="PROXY<https://cdn.example.com/init.mp4?token=T>"'));
    expect(rewritten,
        contains('PROXY<https://cdn.example.com/seg1.ts?token=T>'));
    // 尾部标签必须保留，否则 VOD 被当成未结束直播流。
    expect(rewritten, contains('#EXT-X-ENDLIST'));
  });

  test('主清单的非注释行也会被重写', () {
    const text = '#EXTM3U\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1000\n'
        '720/index.m3u8\n';
    final rewritten = HlsAdFilter.rewriteManifest(
      text,
      Uri.parse('https://cdn.example.com/top.m3u8'),
      (abs) => 'P($abs)',
    );
    expect(rewritten, contains('P(https://cdn.example.com/720/index.m3u8)'));
  });

  test('绝对 URI 不继承父清单 query', () {
    const text = '#EXTM3U\n'
        '#EXTINF:5.0,\n'
        'https://other.example.com/seg.ts?own=1\n'
        '#EXT-X-ENDLIST\n';
    final rewritten = HlsAdFilter.rewriteManifest(
      text,
      Uri.parse('https://cdn.example.com/a.m3u8?token=T'),
      (abs) => 'P($abs)',
    );
    expect(rewritten, contains('P(https://other.example.com/seg.ts?own=1)'));
  });
}
