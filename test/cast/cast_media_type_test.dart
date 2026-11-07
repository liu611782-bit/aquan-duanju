import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_type.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';

CastMediaType _resolveSync(Uri url) => castMediaTypeFromUrlPath(url);

/// 构造 ftyp box 头字节：size(4) + 'ftyp'(4) + brand 逐个 4 字节。
List<int> _ftypHead(List<String> brands) {
  final size = 8 + brands.length * 4;
  return <int>[
    (size >> 24) & 0xFF,
    (size >> 16) & 0xFF,
    (size >> 8) & 0xFF,
    size & 0xFF,
    ...'ftyp'.codeUnits,
    ...brands.expand((b) => b.codeUnits),
  ];
}

void main() {
  group('判定表：URL 扩展名（design §4.1）', () {
    test('HLS → vnd.apple.mpegurl + index.m3u8', () {
      final t = _resolveSync(Uri.parse('http://x/a/b.M3U8?token=1'));
      expect(t.mime, 'application/vnd.apple.mpegurl');
      expect(t.fileName, 'index.m3u8');
      expect(t.kind, CastMediaKind.video);
      expect(t.isHls, isTrue);
      expect(_resolveSync(Uri.parse('http://x/a.m3u')).isHls, isTrue);
    });

    test('.ts → video/mp2t + stream.ts', () {
      final t = _resolveSync(Uri.parse('http://x/live/1.ts'));
      expect(t.mime, 'video/mp2t');
      expect(t.fileName, 'stream.ts');
    });

    test('.mp4/.m4v → video/mp4 + video.mp4', () {
      for (final path in ['http://x/ep.mp4', 'http://x/ep.m4v']) {
        final t = _resolveSync(Uri.parse(path));
        expect(t.mime, 'video/mp4', reason: path);
        expect(t.fileName, 'video.mp4', reason: path);
      }
    });

    test('.mkv → video/x-matroska；.flv → video/x-flv', () {
      expect(_resolveSync(Uri.parse('http://x/a.mkv')).mime,
          'video/x-matroska');
      expect(_resolveSync(Uri.parse('http://x/a.mkv')).fileName, 'video.mkv');
      expect(
          _resolveSync(Uri.parse('http://x/a.flv')).mime, 'video/x-flv');
    });

    test('.mp3 → audio/mpeg；.m4a/.aac → audio/mp4', () {
      expect(_resolveSync(Uri.parse('http://x/a.mp3')).mime, 'audio/mpeg');
      expect(_resolveSync(Uri.parse('http://x/a.mp3')).fileName, 'audio.mp3');
      for (final path in ['http://x/a.m4a', 'http://x/a.AAC']) {
        final t = _resolveSync(Uri.parse(path));
        expect(t.mime, 'audio/mp4', reason: path);
        expect(t.kind, CastMediaKind.audio, reason: path);
      }
    });

    test('.jpg/.png → image 类', () {
      final jpg = _resolveSync(Uri.parse('http://x/cover.jpg'));
      expect(jpg.mime, 'image/jpeg');
      expect(jpg.kind, CastMediaKind.image);
      expect(_resolveSync(Uri.parse('http://x/cover.png')).mime, 'image/png');
    });

    test('未知扩展名与无扩展名 → unknown（绝不 video/mp4 兜底）', () {
      expect(_resolveSync(Uri.parse('http://x/a.divx')).kind,
          CastMediaKind.unknown);
      final none = _resolveSync(Uri.parse('http://x/api/play?u=1'));
      expect(none.kind, CastMediaKind.unknown);
      expect(none.mime, 'application/octet-stream');
      expect(none.fileName, isNot(contains('.')), reason: '无证据不带扩展名');
    });

    test('query 里的扩展名不算（路径判定）', () {
      expect(
        _resolveSync(Uri.parse('http://x/get?u=a.m3u8')).kind,
        CastMediaKind.unknown,
        reason: '判定表按路径扩展名；query 场景由 hint/嗅探兜住',
      );
    });
  });

  group('三级判定：显式 hint 优先', () {
    test('hint 优先于 URL 扩展名', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.ts'),
        hintMime: 'application/x-mpegurl',
      );
      expect(t.mime, 'application/x-mpegurl');
      expect(t.fileName, 'index.m3u8');
    });

    test('HLS 别名组 hint 原样保留拼写', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        hintMime: 'application/x-mpegurl',
      );
      expect(t.mime, 'application/x-mpegurl');
      expect(t.isHls, isTrue);
    });

    test('video/mp4 兜底提示 + 无扩展名 → 交给嗅探（不采信）', () async {
      var sniffed = false;
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        hintMime: 'video/mp4',
        sniffHead: (u) async {
          sniffed = true;
          return utf8.encode('....ftypisom')..[0] = 0;
        },
      );
      expect(sniffed, isTrue, reason: 'mimeTypeForMedia 的兜底不是证据');
      expect(t.mime, 'video/mp4');
    });

    test('video/mp4 兜底提示 + 无扩展名 + 嗅探失败 → unknown', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        hintMime: 'video/mp4',
        sniffHead: (u) async => null,
      );
      expect(t.kind, CastMediaKind.unknown);
    });

    test('无 hint + 已知扩展名 → 不嗅探', () async {
      var sniffed = false;
      await resolveCastMediaType(
        url: Uri.parse('http://x/a.mp4'),
        sniffHead: (u) async {
          sniffed = true;
          return null;
        },
      );
      expect(sniffed, isFalse);
    });
  });

  group('内容嗅探（前 8KB 字节）', () {
    test('#EXTM3U → HLS（容忍 BOM 与前导空白）', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        sniffHead: (u) async => utf8.encode('\uFEFF\n #EXTM3U\n#EXTINF:4,\n'),
      );
      expect(t.mime, 'application/vnd.apple.mpegurl');
      expect(t.fileName, 'index.m3u8');
    });

    test('ftyp@4 → video/mp4', () async {
      final bytes = <int>[0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70, 0x69];
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => bytes,
      );
      expect(t.mime, 'video/mp4');
    });

    test('TS sync（0x47@0 且 0x47@188）→ video/mp2t', () async {
      final bytes = List<int>.filled(256, 0xAB)..[0] = 0x47..[188] = 0x47;
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => bytes,
      );
      expect(t.mime, 'video/mp2t');
      expect(t.fileName, 'stream.ts');
    });

    test('FLV → video/x-flv', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => utf8.encode('FLV\x01\x05\x00\x00\x00\x09'),
      );
      expect(t.mime, 'video/x-flv');
    });

    test('HTML → CastException（明确失败，不投）', () async {
      await expectLater(
        resolveCastMediaType(
          url: Uri.parse('http://x/media'),
          sniffHead: (u) async =>
              utf8.encode('<!DOCTYPE html><html><body>403</body></html>'),
        ),
        throwsA(isA<CastException>()),
      );
    });

    test('JSON → CastException', () async {
      await expectLater(
        resolveCastMediaType(
          url: Uri.parse('http://x/media'),
          sniffHead: (u) async => utf8.encode('{"error":"deny"}'),
        ),
        throwsA(isA<CastException>()),
      );
    });

    test('嗅探无特征（如纯文本）→ unknown 而非失败', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => utf8.encode('0123456789ABCDEF'),
      );
      expect(t.kind, CastMediaKind.unknown);
    });
  });

  group('编码嗅探 codecHint（R1，design §2.2 判定表）', () {
    test('ftyp HEVC 家族 brand（hev1/hvc1/dvh1/mhv1）→ hevc', () async {
      for (final brand in ['hev1', 'hvc1', 'dvh1', 'mhv1']) {
        final t = await resolveCastMediaType(
          url: Uri.parse('http://x/media'),
          sniffHead: (u) async => _ftypHead([brand]),
        );
        expect(t.codecHint, 'hevc', reason: brand);
        expect(t.mime, 'video/mp4', reason: brand);
      }
    });

    test('ftyp av01 brand → av1', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => _ftypHead(['av01']),
      );
      expect(t.codecHint, 'av1');
      expect(t.mime, 'video/mp4');
    });

    test('major brand 无编码时 compatible brands 命中也判', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => _ftypHead(['isom', 'mhv1']),
      );
      expect(t.codecHint, 'hevc', reason: '第二个 brand（compatible）命中');
    });

    test('isom/mp42 等无编码 brand → codecHint null（现状不回归）', () async {
      for (final brands in [
        ['isom'],
        ['mp42'],
        ['isom', 'mp41', 'avc1'],
      ]) {
        final t = await resolveCastMediaType(
          url: Uri.parse('http://x/media'),
          sniffHead: (u) async => _ftypHead(brands),
        );
        expect(t.codecHint, isNull, reason: brands.join('/'));
        expect(t.mime, 'video/mp4', reason: brands.join('/'));
      }
    });

    test('非 MP4 容器（TS/FLV/HLS 无 CODECS）→ codecHint null', () async {
      final ts = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async =>
            (List<int>.filled(256, 0xAB)..[0] = 0x47..[188] = 0x47),
      );
      expect(ts.codecHint, isNull, reason: 'TS 容器无法从 8KB 判编码，不做');
      final flv = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sniffHead: (u) async => utf8.encode('FLV\x01\x05\x00\x00\x00\x09'),
      );
      expect(flv.codecHint, isNull);
    });

    test('HLS 主清单 CODECS 各拼写 → hevc', () async {
      for (final codecs in [
        'hvc1.1.6.L93.B0,mp4a.40.2',
        'hev1.1.6.L93.B0',
        'dvh1.05.01,ec-3',
        'mp4a.40.2,mhv1.2',
      ]) {
        final head =
            utf8.encode('#EXTM3U\n#EXT-X-STREAM-INF:CODECS="$codecs"\n');
        final t = await resolveCastMediaType(
          url: Uri.parse('http://x/api/play'),
          sniffHead: (u) async => head,
        );
        expect(t.codecHint, 'hevc', reason: codecs);
        expect(t.mime, 'application/vnd.apple.mpegurl', reason: codecs);
      }
    });

    test('HLS 主清单 CODECS 含 av01 → av1', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        sniffHead: (u) async => utf8.encode(
            '#EXTM3U\n#EXT-X-STREAM-INF:CODECS="av01.0.04M.08,mp4a.40.2"\n'),
      );
      expect(t.codecHint, 'av1');
    });

    test('HLS 主清单无 CODECS → null', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        sniffHead: (u) async =>
            utf8.encode('#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=2000000\n'),
      );
      expect(t.codecHint, isNull);
    });

    test('媒体清单（无 STREAM-INF）不判 codec（有 hvc1 字样也不判）', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/api/play'),
        sniffHead: (u) async => utf8.encode(
            '#EXTM3U\n#EXTINF:4.0,\nhvc1seg1.ts\n#EXT-X-ENDLIST\n'),
      );
      expect(t.codecHint, isNull,
          reason: '分片级编码无法从媒体清单判，不猜');
    });

    test('codecHint 随 Sink 拼写选择与 live 重包保留', () async {
      final spelled = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        sinkMimes: ['http-get:*:video/mp4:*'],
        sniffHead: (u) async => _ftypHead(['hvc1']),
      );
      expect(spelled.codecHint, 'hevc');
      final live = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        live: true,
        sniffHead: (u) async => _ftypHead(['hvc1']),
      );
      expect(live.codecHint, 'hevc');
      expect(live.live, isTrue);
    });
  });

  group('mime 别名组与 Sink 拼写选择（review §8.7/§8.9）', () {
    test('TS 组：Sink 有 video/vnd.dlna.mpeg-tts → 照抄', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.ts'),
        sinkMimes: ['http-get:*:video/vnd.dlna.mpeg-tts:*'],
      );
      expect(t.mime, 'video/vnd.dlna.mpeg-tts');
      expect(t.fileName, 'stream.ts', reason: '拼写选择不改文件名');
    });

    test('HLS 组：Sink 有 application/x-mpegurl → 照抄', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.m3u8'),
        sinkMimes: ['http-get:*:application/x-mpegurl:*'],
      );
      expect(t.mime, 'application/x-mpegurl');
    });

    test('Matroska 组：Sink 有 video/x-mkv（Samsung 拼写）→ 照抄', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.mkv'),
        sinkMimes: ['http-get:*:video/x-mkv:*'],
      );
      expect(t.mime, 'video/x-mkv');
      expect(t.fileName, 'video.mkv');
    });

    test('Sink 自己用的就是规范拼写 → 保持规范', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.ts'),
        sinkMimes: ['http-get:*:video/mp2t:*'],
      );
      expect(t.mime, 'video/mp2t');
    });

    test('Sink 无同组条目 → 不过滤，用规范拼写（go2tv 原则）', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/a.m3u8'),
        sinkMimes: ['http-get:*:video/mp4:*'],
      );
      expect(t.mime, 'application/vnd.apple.mpegurl');
    });

    test('preferSinkSpelling 纯函数：大小写归一、通配跳过', () {
      expect(
        preferSinkSpelling('video/mp2t', ['HTTP-GET:*:VIDEO/VND.DLNA.MPEG-TTS:*']),
        'video/vnd.dlna.mpeg-tts',
      );
      expect(
        preferSinkSpelling('video/mp2t', ['http-get:*:*/*:*']),
        'video/mp2t',
      );
      expect(preferSinkSpelling('video/mp4', ['http-get:*:video/mp4:*']),
          'video/mp4');
    });
  });

  group('上游伪装 image/*（dart_cast media_proxy 实证）', () {
    test('hint image/png + URL .ts → 按 URL 改写为 video/mp2t', () async {
      var sniffed = false;
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/seg1.ts'),
        hintMime: 'image/png',
        sniffHead: (u) async {
          sniffed = true;
          return null;
        },
      );
      expect(sniffed, isFalse, reason: 'URL 已给出容器证据，无需嗅探');
      expect(t.mime, 'video/mp2t');
      expect(t.kind, CastMediaKind.video);
    });

    test('hint image/png + 无扩展名 → 嗅探 ftyp 改写为 video/mp4', () async {
      final bytes = <int>[0, 0, 0, 24, 0x66, 0x74, 0x79, 0x70, 0x69, 0x73];
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        hintMime: 'image/png',
        sniffHead: (u) async => bytes,
      );
      expect(t.mime, 'video/mp4');
    });

    test('hint image/png + 无扩展名 + 嗅探无证据 → 保留 image（可能是真图片）',
        () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/media'),
        hintMime: 'image/png',
        sniffHead: (u) async => utf8.encode('0123456789'),
      );
      expect(t.mime, 'image/png');
    });

    test('真图片（.jpg URL + image hint）→ 不嗅探', () async {
      var sniffed = false;
      final t = await resolveCastMediaType(
        url: Uri.parse('http://x/cover.jpg'),
        hintMime: 'image/jpeg',
        sniffHead: (u) async {
          sniffed = true;
          return null;
        },
      );
      expect(sniffed, isFalse);
      expect(t.mime, 'image/jpeg');
    });
  });

  group('defaultSniffHead（真实 HTTP 往返）', () {
    late HttpServer upstream;
    late String requestRange;

    setUp(() async {
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((req) async {
        requestRange = req.headers.value('range') ?? '';
        if (req.uri.path == '/ts') {
          final bytes = List<int>.filled(256, 0)..[0] = 0x47..[188] = 0x47;
          req.response.headers.set('Content-Type', 'image/png');
          req.response.add(bytes);
          await req.response.close();
          return;
        }
        req.response.headers.contentType = ContentType.text;
        req.response.write('<html>blocked</html>');
        await req.response.close();
      });
    });

    tearDown(() async {
      await upstream.close();
    });

    test('取前 8KB 原始字节并带 Range 头', () async {
      final head = await defaultSniffHead(
        Uri.parse('http://127.0.0.1:${upstream.port}/ts'),
        headers: {'Referer': 'http://origin/'},
      );
      expect(head, isNotNull);
      expect(head![0], 0x47);
      expect(head[188], 0x47);
      expect(requestRange, 'bytes=0-8191');
    });

    test('嗅探结果参与判定：伪装 image/png + TS 字节 → video/mp2t', () async {
      final t = await resolveCastMediaType(
        url: Uri.parse('http://127.0.0.1:${upstream.port}/ts'),
        hintMime: 'image/png',
        sniffHead: defaultSniffHead,
      );
      expect(t.mime, 'video/mp2t');
    });

    test('连接失败 → 嗅探返回 null（不抛，只是少一层证据）', () async {
      final head = await defaultSniffHead(
        Uri.parse('http://127.0.0.1:1/ts'), // 未监听端口：连接失败
        timeout: const Duration(milliseconds: 500),
      );
      expect(head, isNull);
    });
  });
}
