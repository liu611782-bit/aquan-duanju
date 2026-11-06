import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/cms_json_adapter.dart';
import 'package:aquan_duanju/core/sources/resolved_playback.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';

void main() {
  group('parsePlayLines', () {
    test('URL 里的 # fragment 不再被当成集分隔符截断', () {
      final lines = parsePlayLines(
        '线路1',
        r'第1集$https://cdn.example.com/a.m3u8#token=abc'
        r'#第2集$https://cdn.example.com/b.mp4',
      );
      expect(lines.length, 1);
      expect(lines.first.episodes.length, 2);
      expect(lines.first.episodes.first.url,
          'https://cdn.example.com/a.m3u8#token=abc');
      expect(lines.first.episodes.last.url, 'https://cdn.example.com/b.mp4');
    });

    test('没有 baseUrl 时相对播放地址保留，不再整条丢弃', () {
      final lines = parsePlayLines('线路1', r'第1集$/play/1.m3u8');
      expect(lines.single.episodes.single.url, '/play/1.m3u8');
    });

    test('超过 12 条线路时排序后仍只保留 12 条', () {
      final names = List.generate(14, (i) => '线路$i').join(r'$$$');
      final blocks = List.generate(
        14,
        (i) => '第1集\$https://cdn.example.com/$i.mp4',
      ).join(r'$$$');
      expect(parsePlayLines(names, blocks).length, 12);
    });

    test('转义斜杠与 &amp; 被清洗', () {
      final lines = parsePlayLines(
        '线路1',
        r'第1集$https:\/\/cdn.example.com\/a.m3u8?x=1&amp;y=2',
      );
      expect(lines.single.episodes.single.url,
          'https://cdn.example.com/a.m3u8?x=1&y=2');
    });
  });

  group('resolvePlayback', () {
    const ua = 'UA-TEST';

    test('相对地址用 baseUrl 补全', () {
      final pb = resolvePlayback(
        rawUrl: '/play/1.m3u8',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: ua,
        baseUrl: 'https://api.example.com/api.php/provide/vod',
      );
      expect(pb.url, 'https://api.example.com/play/1.m3u8');
      expect(pb.isPlayable, isTrue);
      expect(pb.isHls, isTrue);
    });

    test('归一 &amp;、转义斜杠与首尾空白', () {
      final pb = resolvePlayback(
        rawUrl: r' https://x/a.m3u8?a=1&amp;b=2 ',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: ua,
      );
      expect(pb.url, 'https://x/a.m3u8?a=1&b=2');
      expect(pb.isHls, isTrue);
    });

    test('无扩展名 HLS 也识别，诊断不泄露 query 值', () {
      final pb = resolvePlayback(
        rawUrl: 'https://x/api/play?type=m3u8&token=SECRET',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: ua,
      );
      expect(pb.isHls, isTrue);
      expect(pb.diagnostic, isNot(contains('SECRET')));
      expect(pb.diagnostic, contains('hls'));
    });

    test('去广告默认关闭时 HLS 也不走代理', () {
      final pb = resolvePlayback(
        rawUrl: 'https://x/a.m3u8',
        sourceHeaders: const {},
        adFilterEnabled: false,
        defaultUa: ua,
      );
      expect(pb.needsProxy, isFalse);
      expect(castHeadersOf(pb, defaultUa: ua), isEmpty);
    });

    test('小写 referer 也能进投屏防盗链头', () {
      final pb = resolvePlayback(
        rawUrl: 'https://x/a.mp4',
        sourceHeaders: const {'referer': 'https://r.example/'},
        adFilterEnabled: false,
        defaultUa: ua,
      );
      expect(headerOf(pb.headers, 'Referer'), 'https://r.example/');
      expect(castHeadersOf(pb, defaultUa: ua)['referer'],
          'https://r.example/');
    });
  });

  group('配置导入', () {
    test('extractParses 收 type=1/2，排除 type=0 嗅探', () {
      final items = SourceImporter.extractParses(<String, dynamic>{
        'parses': [
          <String, dynamic>{'name': 'a', 'url': 'https://p/a?url=', 'type': 1},
          <String, dynamic>{'name': 'b', 'url': 'https://p/b', 'type': 2},
          <String, dynamic>{'name': 'c', 'url': 'https://p/c', 'type': 0},
        ],
      });
      expect(items.map((p) => p.name), ['a', 'b']);
    });

    test('手贴配置里的 parses[] 不再丢失', () async {
      final rep = await SourceImporter.importFromText(jsonEncode(<String, dynamic>{
        'sites': <dynamic>[],
        'parses': [
          <String, dynamic>{
            'name': 'jx',
            'url': 'https://p.example.com/jx?url=',
            'type': 1,
          },
        ],
      }));
      expect(rep.parses.length, 1);
      expect(rep.isEmpty, isFalse);
    });

    test('k=v;k=v 风格 header 仍兼容', () async {
      final rep = await SourceImporter.importFromText(jsonEncode(<String, dynamic>{
        'sites': [
          <String, dynamic>{
            'key': 'demo2',
            'name': 'demo2',
            'api': 'https://api2.example.com',
            'type': 1,
            'header': 'Referer=https://r.example/?a=1&b=2;User-Agent=UA2',
          },
        ],
      }));
      expect(rep.added.single.headers['Referer'],
          'https://r.example/?a=1&b=2');
    });

    test('header 里 Referer 的 & 不再被截断', () async {
      final rep = await SourceImporter.importFromText(jsonEncode(<String, dynamic>{
        'sites': [
          <String, dynamic>{
            'key': 'demo',
            'name': 'demo',
            'api': 'https://api.example.com',
            'type': 1,
            'header':
                'Referer: https://r.example/?a=1&b=2;User-Agent: UA-CUSTOM',
          },
        ],
      }));
      expect(rep.added, isNotEmpty);
      expect(rep.added.single.headers['Referer'],
          'https://r.example/?a=1&b=2');
    });
  });
}
