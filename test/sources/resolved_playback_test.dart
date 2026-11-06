import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/resolved_playback.dart';

void main() {
  const defaultUa = 'UA-DEFAULT';

  group('resolvePlayback — 本地与投屏共用一份解析结果', () {
    test('非 HLS + 去广告开启也默认直链', () {
      final pb = resolvePlayback(
        rawUrl: 'https://cdn.example.com/movie.mp4',
        sourceHeaders: const {},
        adFilterEnabled: true,
        defaultUa: defaultUa,
      );
      expect(pb.url, 'https://cdn.example.com/movie.mp4');
      expect(pb.isHls, isFalse);
      expect(pb.needsProxy, isFalse);
      expect(pb.headers['User-Agent'], defaultUa);
      expect(pb.mimeType, 'video/mp4');
    });

    test('HLS + 去广告开启才尝试代理；关闭时直链', () {
      final on = resolvePlayback(
        rawUrl: 'https://cdn.example.com/index.m3u8?token=x',
        sourceHeaders: const {},
        adFilterEnabled: true,
        defaultUa: defaultUa,
      );
      expect(on.isHls, isTrue);
      expect(on.needsProxy, isTrue);
      expect(on.mimeType, 'application/vnd.apple.mpegurl');

      final off = resolvePlayback(
        rawUrl: 'https://cdn.example.com/index.m3u8',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: defaultUa,
      );
      expect(off.isHls, isTrue);
      expect(off.needsProxy, isFalse);
    });

    test('源级 UA / Referer 不被默认 UA 覆盖', () {
      final pb = resolvePlayback(
        rawUrl: 'https://cdn.example.com/a.mp4',
        sourceHeaders: const {
          'User-Agent': 'CustomUA',
          'Referer': 'https://r.example/',
        },
        adFilterEnabled: false,
        defaultUa: defaultUa,
      );
      expect(pb.headers['User-Agent'], 'CustomUA');
      expect(pb.headers['Referer'], 'https://r.example/');
      expect(castHeadersOf(pb, defaultUa: defaultUa)['Referer'],
          'https://r.example/');
      expect(castHeadersOf(pb, defaultUa: defaultUa)['User-Agent'],
          'CustomUA');
    });

    test('仅默认 UA 的源投屏不带防盗链头（手机可离开前台）', () {
      final pb = resolvePlayback(
        rawUrl: 'https://cdn.example.com/a.mp4',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: defaultUa,
      );
      expect(castHeadersOf(pb, defaultUa: defaultUa), isEmpty);
    });

    test('URL 形态与 MIME 推断', () {
      expect(looksLikeHls('https://x/a.M3U8?sign=1'), isTrue);
      expect(looksLikeHls('https://x/a.mp4'), isFalse);
      expect(mimeTypeForMedia('https://x/a.mkv'), 'video/x-matroska');
      expect(mimeTypeForMedia('https://x/a.ts'), 'video/mp2t');
      expect(mimeTypeForMedia('https://x/a.mp3'), 'audio/mpeg');
    });

    test('诊断标签不含完整 URL / 凭据', () {
      final pb = resolvePlayback(
        rawUrl: 'https://u:p@cdn.example.com/secret.mp4?token=abcd',
        sourceHeaders: const {'Referer': 'https://r.example/'},
        adFilterEnabled: false,
        defaultUa: defaultUa,
      );
      expect(pb.diagnostic, contains('cdn.example.com'));
      // 诊断允许带 path 尾段（判断地址形态），但不含完整 URL / query /
      // 凭据 / Referer 域名。
      expect(pb.diagnostic, isNot(contains('token')));
      expect(pb.diagnostic, isNot(contains('u:p')));
      expect(pb.diagnostic, isNot(contains('https://')));
      expect(pb.diagnostic, isNot(contains('r.example')));
    });
  });
}
