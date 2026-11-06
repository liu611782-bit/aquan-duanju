import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';

void main() {
  // 本地 HttpServer 夹具走 127.0.0.1，SSRF 守卫在测试内关闭。
  setUp(() => SourceImporter.ssrfGuardEnabled = false);
  tearDown(() => SourceImporter.ssrfGuardEnabled = true);

  group('extractSites：TVBox sites', () {
    test('type=1/缺省/type=0/爬虫族/csp_AppYs/header/相对地址', () {
      const cfg = '''
{
  "sites": [
    {"key":"dyttzy","name":"电影天堂","type":1,"api":"http://c/a/api.php/provide/vod",
     "header":{"User-Agent":"okhttp/3.15"}},
    {"key":"noType","name":"缺省类型","api":"/api.php/provide/vod"},
    {"key":"xml1","name":"XML源","type":0,"api":"http://c/b/api.php/provide/vod"},
    {"key":"csp_XPath","name":"爬虫","type":3,"api":"csp_XPath","jar":"./spider.jar"},
    {"key":"js1","name":"JS爬虫","api":"./lib/js1.js"},
    {"key":"py1","name":"PY爬虫","type":3,"api":"./lib/py.py"},
    {"key":"appys","name":"AppYs","api":"csp_AppYs","ext":"http://appys.host/api.php/app"},
    {"key":"appysRel","name":"AppYs相对","api":"csp_AppYs","ext":"./base"}
  ]
}
''';
      final sites = SourceImporter.extractSites(
          jsonDecode(cfg) as Map,
          sourceUrl: 'http://config.host/dir/cfg.json');

      expect(sites.length, 8);
      expect(sites[0].kind, SourceKind.cmsJson);
      expect(sites[0].headers['User-Agent'], 'okhttp/3.15');
      expect(sites[0].usable, isTrue);

      // 相对 api 按配置来源还原。
      expect(sites[1].api, 'http://config.host/api.php/provide/vod');

      expect(sites[2].kind, SourceKind.cmsXml);

      // 爬虫族（type=3 / csp_）：需要 JVM 爬虫引擎，登记为 spider 且不可用。
      expect(sites[3].kind, SourceKind.spider);
      expect(sites[3].spiderKey, 'csp_XPath');
      expect(sites[3].usable, isFalse);
      expect(sites[3].unsupportedReason, contains('爬虫'));

      // .js 源由 QuickJS 运行时执行：解析成绝对地址后**可用**，不再标记「需要爬虫引擎」。
      expect(sites[4].kind, SourceKind.spiderJs);
      expect(sites[4].api, 'http://config.host/dir/lib/js1.js');
      expect(sites[4].usable, isTrue);
      expect(sites[4].unsupportedReason, isEmpty);

      // .py 仍不支持。
      expect(sites[5].unsupportedReason, contains('Python'));

      // csp_AppYs：ext 是站点 base；相对 ext 按配置文件目录还原。
      expect(sites[6].api, 'http://appys.host/api.php/app/vod');
      expect(sites[7].api, 'http://config.host/dir/base/api.php/app/vod');
    });

    test('.js 源相对地址无法解析为绝对地址时给出原因', () {
      const cfg = '{"sites":[{"key":"js1","name":"JS","api":"./lib/js1.js"}]}';
      final sites = SourceImporter.extractSites(jsonDecode(cfg) as Map);
      expect(sites.single.kind, SourceKind.spiderJs);
      expect(sites.single.unsupportedReason, contains('绝对地址'));
      expect(sites.single.usable, isFalse);
    });

    test('ext 对象形态归一为 JSON 文本', () {
      const cfg =
          '{"sites":[{"key":"k","name":"K","type":1,"api":"http://c/api",'
          '"ext":{"filter":[{"key":"type","name":"类型"}]},"header":"{\\"Referer\\":\\"http://r\\"}"}]}';
      final sites =
          SourceImporter.extractSites(jsonDecode(cfg) as Map);
      expect(sites.single.ext, contains('"filter"'));
      expect(sites.single.headers['Referer'], 'http://r');
    });
  });

  group('extractSites：MoonTV api_site', () {
    test('api_site 映射', () {
      const cfg =
          '{"api_site":{"dyttzy":{"api":"http://c/provide/vod","name":"电影天堂",'
          '"detail":"http://c"}}}';
      final sites = SourceImporter.extractSites(jsonDecode(cfg) as Map);
      expect(sites.single.name, '电影天堂');
      expect(sites.single.api, 'http://c/provide/vod');
    });
  });

  group('extractParses', () {
    test('收 type=1/2 且 url 为 http，排除 type=0 嗅探', () {
      const cfg = '''
{"parses":[
  {"name":"Json并发","type":2,"url":"http://p1/?url="},
  {"name":"Json轮询","type":1,"url":"http://p2/?url="},
  {"name":"Web嗅探","type":0,"url":"http://p3/?url="},
  {"name":"坏的","type":1,"url":"javascript:1"}
]}''';
      final parses = SourceImporter.extractParses(jsonDecode(cfg) as Map);
      expect(parses.length, 2);
      expect(parses.first.url, 'http://p1/?url=');
      expect(parses.last.url, 'http://p2/?url=');
    });
  });

  group('importFromText / importFromUrl', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final path = req.uri.path;
        req.response.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        if (path == '/cfg.json') {
          req.response.write(jsonEncode({
            'sites': [
              {'key': 'a', 'name': '源A', 'type': 1, 'api': '$base/a/vod'}
            ]
          }));
        } else if (path == '/depot.json') {
          req.response.write(jsonEncode({
            'urls': [
              {'sourceName': '子仓', 'sourceUrl': '$base/cfg.json'}
            ]
          }));
        } else if (path == '/loop-a.json') {
          req.response.write(jsonEncode({
            'urls': [
              {'sourceName': 'B', 'sourceUrl': '$base/loop-b.json'}
            ]
          }));
        } else if (path == '/loop-b.json') {
          req.response.write(jsonEncode({
            'urls': [
              {'sourceName': 'A', 'sourceUrl': '$base/loop-a.json'}
            ]
          }));
        } else if (path == '/big.json') {
          req.response.contentLength = 2 << 20;
          req.response.add(List.filled(2 << 20, 0x20));
        } else if (path == '/lines.txt') {
          req.response.write('源甲|$base/j/vod\n源乙|$base/y/vod\n#注释行\n');
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });

    tearDown(() async => server.close(force: true));

    test('TVBox JSON 导入', () async {
      final rep = await SourceImporter.importFromText(
          '{"sites":[{"key":"a","name":"源A","type":1,"api":"$base/a/vod"}]}');
      expect(rep.added.single.name, '源A');
      expect(rep.added.single.api, '$base/a/vod');
    });

    test('多仓递归展开一层 + 循环引用终止', () async {
      final rep = await SourceImporter.importFromUrl('$base/depot.json');
      expect(rep.added.where((c) => c.name == '源A'), isNotEmpty);
      final loop = await SourceImporter.importFromUrl('$base/loop-a.json');
      // 循环引用靠 visited 集合终止：不发散即可。
      expect(loop, isNotNull);
    });

    test('1MB 上限拒绝', () async {
      final rep = await SourceImporter.importFromUrl('$base/big.json');
      expect(rep.failed, isNotEmpty);
    });

    test('文本行导入（名称|地址 + 注释跳过）', () async {
      final rep = await SourceImporter.importFromUrl('$base/lines.txt');
      expect(rep.added.length, 2);
      expect(rep.added.first.name, '源甲');
    });

    test('非法内容整体失败', () async {
      final rep = await SourceImporter.importFromText('随便什么都没有的东西');
      expect(rep.added, isEmpty);
      expect(rep.failed, isNotEmpty);
    });
  });

  group('SSRF 校验', () {
    test('拒绝 loopback / 链路本地 / 非 http', () {
      SourceImporter.ssrfGuardEnabled = true;
      for (final bad in [
        'http://127.0.0.1:8080/a',
        'http://localhost/a',
        'http://[::1]/a',
        'http://169.254.1.1/a',
        'ftp://x/a',
        'not a url',
      ]) {
        expect(
          () => SourceImporter.validateImportUrl(bad),
          throwsA(isA<SourceException>().having(
              (e) => e.code, 'code', SourceExceptionCode.importSsrf)),
          reason: bad,
        );
      }
    });

    test('放行公网地址', () {
      SourceImporter.ssrfGuardEnabled = true;
      expect(
        () => SourceImporter.validateImportUrl('http://example.com/api'),
        returnsNormally,
      );
    });
  });
}
