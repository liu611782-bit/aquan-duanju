import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_runtime.dart';
import 'package:aquan_duanju/core/books/book_source_service.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/books/so_novel_runtime.dart';
import 'package:aquan_duanju/core/books/so_novel_seed.dart';
import 'package:aquan_duanju/core/books/so_novel_source.dart';

/// 可插拔多格式引擎分派层：方言指纹、存储往返、BookSourceService 双方言分派。
void main() {
  setUp(() => HttpOverrides.global = null);

  group('BookSource 方言指纹与往返', () {
    test('so-novel JSON → soNovel 格式，含 @js: 仍放行（requiresJs=false）', () {
      final src = BookSource.fromJson(const {
        'url': 'http://a.com/',
        'name': '甲',
        'search': {
          'url': 'http://a.com/s',
          'result': '#x',
          'bookName': r"#n@js:r=r.replace('x','y')",
        },
        'toc': {'item': '#t a'},
        'chapter': {'content': '#c'},
      });
      expect(src.format, BookSourceFormat.soNovel);
      expect(src.requiresJs, isFalse);
      expect(src.rawRuleJson, contains('@js:'));
      expect(src.enabled, isTrue);
    });

    test('legado JSON 含 @js: → requiresJs 拒绝（行为不变）', () {
      final src = BookSource.fromJson(const {
        'bookSourceUrl': 'http://b.com/',
        'bookSourceName': '乙',
        'searchUrl': 'http://b.com/s?key={{key}}',
        'ruleSearch': {'bookList': 'class.x', 'name': 'tag.a@js:r'},
      });
      expect(src.format, BookSourceFormat.legado);
      expect(src.requiresJs, isTrue);
    });

    test('listFromJson：单个 so-novel 对象可导入（原只认数组）', () {
      final sources = BookSource.listFromJson(const {
        'url': 'http://c.com/',
        'name': '丙',
        'toc': {'item': '#t a'},
        'chapter': {'content': '#c'},
      });
      expect(sources, hasLength(1));
      expect(sources.single.format, BookSourceFormat.soNovel);
    });

    test('toJson/fromJson 往返保留方言与启用态（disabled 落回）', () {
      final src = BookSource.fromJson(const {
        'url': 'http://d.com/',
        'name': '丁',
        'search': {'url': 'http://d.com/s', 'result': '#x', 'bookName': '#n'},
        'toc': {'item': '#t a'},
        'chapter': {'content': '#c'},
      });
      final round = BookSource.fromJson(
          jsonDecode(jsonEncode(src.copyWithEnabled(false).toJson()))
              as Map<String, dynamic>);
      expect(round.format, BookSourceFormat.soNovel);
      expect(round.enabled, isFalse);
      // 规则体保留 + 启用态落回 disabled 字段（重启后停用不复活）。
      expect(round.rawRuleJson, contains('"search"'));
      expect(round.rawRuleJson, contains('"disabled":true'));
    });
  });

  group('BookSourceStore 方言启停', () {
    test('setEnabled 不剥方言，持久化往返后 format/rawRuleJson 保留', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = BookSourceStore(prefs);
      final so = BookSource.fromJson(const {
        'url': 'http://e.com/',
        'name': '戊',
        'search': {'url': 'http://e.com/s', 'result': '#x', 'bookName': '#n'},
        'toc': {'item': '#t a'},
        'chapter': {'content': '#c', 'filterTxt': r'\(本章完\)'},
      });
      await store.importAll([so]);
      await store.setEnabled(so.url, false);

      final reloaded = BookSourceStore(prefs);
      await reloaded.ensureLoaded();
      final got = reloaded.byUrl(so.url);
      expect(got, isNotNull);
      expect(got!.enabled, isFalse);
      expect(got.format, BookSourceFormat.soNovel);
      expect(got.rawRuleJson, contains('filterTxt'));
    });
  });

  group('BookSourceService 双方言分派', () {
    late HttpServer server;
    late String base;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = 'http://127.0.0.1:${server.port}';
      server.listen((req) async {
        final p = req.uri.path;
        Future<void> reply(String body, {String type = 'text/html'}) async {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.parse('$type; charset=utf-8')
            ..write(body);
          await req.response.close();
        }

        if (p == '/waps.php') {
          // so-novel 搜索页（POST）；bookName 带 @js: 清洗「【转】」前缀。
          await reply('<div id="checkform"><table><tbody><tr>'
              '<td class="even"><a href="/book/1.html">【转】斗罗</a></td>'
              '<td>x</td><td>作者甲</td></tr></tbody></table></div>');
        } else if (p == '/book/1.html') {
          await reply('<html><head>'
              '<meta property="og:novel:book_name" content="斗罗">'
              '<meta property="og:novel:author" content="作者甲">'
              '</head><body><div id="info">详情</div></body></html>');
        } else if (p == '/toc.html') {
          await reply('<div id="list"><dl>'
              '<dd><a href="/ch/1.html">第一章</a></dd>'
              '<dd><a href="/ch/2.html">第二章</a></dd></dl></div>');
        } else if (p == '/ch/1.html') {
          await reply('<div id="content">第一段<br>第二段<br>第三段</div>');
        } else if (p == '/lgsearch') {
          await reply(
              jsonEncode({'data': [
                {'name': '斗罗(legado)', 'bookUrl': '$base/lgbook/1', 'author': '作者乙'}
              ]}),
              type: 'application/json');
        } else if (p == '/lgbook/1') {
          await reply(
              jsonEncode({'name': '斗罗(legado)', 'author': '作者乙', 'tocUrl': '$base/lgtoc/1'}),
              type: 'application/json');
        } else if (p == '/lgtoc/1') {
          await reply(jsonEncode({
            'chapters': [
              {'title': '第一章', 'url': '$base/lgch/1'}
            ]
          }), type: 'application/json');
        } else if (p == '/lgch/1') {
          await reply(jsonEncode({'content': 'legado 正文内容'}),
              type: 'application/json');
        } else {
          await reply('nf');
        }
      });
    });

    tearDown(() async => server.close(force: true));

    BookSource soSource() => BookSource.fromJson({
          'url': base,
          'name': '夹具so',
          'search': {
            'url': '$base/waps.php',
            'method': 'post',
            'data': '{searchkey: %s}',
            'result': '#checkform > table > tbody > tr',
            'bookName': r"td.even > a@js:r=r.replace('【转】','')",
            'author': 'td:nth-of-type(3)',
          },
          'book': <String, dynamic>{},
          'toc': {'url': '$base/toc.html', 'item': '#list dd a'},
          'chapter': {
            'content': '#content',
            'paragraphTagClosed': false,
            'paragraphTag': '<br>+',
          },
        });

    BookSource lgSource() => BookSource(
          url: base,
          name: '夹具legado',
          searchUrl: '$base/lgsearch?key={{key}}',
          ruleSearch: const BookRuleGroup(
              bookList: r'$.data[*]',
              name: r'$.name',
              bookUrl: r'$.bookUrl',
              author: r'$.author'),
          ruleBookInfo: const BookRuleGroup(
              name: r'$.name', author: r'$.author', tocUrl: r'$.tocUrl'),
          ruleToc: const BookTocRule(
              chapterList: r'$.chapters[*]',
              chapterName: r'$.title',
              chapterUrl: r'$.url'),
          ruleContent: const BookContentRule(content: r'$.content'),
        );

    BookSourceService service() => BookSourceService(
          legado: BookSourceRuntime(enforceSsrf: false),
          soNovel: SoNovelRuntime(
            enforceSsrf: false,
            // 桩：模拟 func(r) 的清洗语义；命中即证明 @js: 步骤经分派层被执行。
            runJs: (code, input) => input.replaceAll('【转】', ''),
          ),
        );

    test('聚合搜索双方言归一 BookHit；so-novel bookName @js: 清洗生效', () async {
      final svc = service();
      final soHits = await svc.search(soSource(), '斗罗');
      expect(soHits, hasLength(1));
      expect(soHits.first.name, '斗罗'); // 【转】前缀被 @js: 步骤清掉
      expect(soHits.first.bookUrl, '$base/book/1.html'); // href 内容类型不受 js 步骤污染
      final lgHits = await svc.search(lgSource(), '斗罗');
      expect(lgHits, hasLength(1));
      expect(lgHits.first.name, '斗罗(legado)');
    });

    test('详情/目录/正文分派：so-novel 走专用运行时', () async {
      final svc = service();
      final so = soSource();
      final hits = await svc.search(so, '斗罗');
      final detail = await svc.detail(so, hits.first.bookUrl);
      expect(detail.name, '斗罗');
      expect(detail.author, '作者甲');
      expect(detail.chapters, hasLength(2));
      expect(detail.chapters.first.url, '$base/ch/1.html');
      final text = await svc.content(so, detail.chapters.first.url);
      expect(text, '第一段\n第二段\n第三段');
    });

    test('详情/目录/正文分派：legado 走既有运行时', () async {
      final svc = service();
      final lg = lgSource();
      final hits = await svc.search(lg, '斗罗');
      final detail = await svc.detail(lg, hits.first.bookUrl);
      expect(detail.name, '斗罗(legado)');
      expect(detail.chapters, hasLength(1));
      final text = await svc.content(lg, detail.chapters.first.url);
      expect(text, 'legado 正文内容');
    });
  });

  group('so-novel 内置种子', () {
    test('两枚 MVP 源逐字可用：方言识别 + 规则字段保真', () {
      expect(builtinSoNovelSources, hasLength(2));
      expect(builtinSoNovelSources.every(
          (s) => s.format == BookSourceFormat.soNovel), isTrue);
      SoRule ruleOf(BookSource s) =>
          SoRule.fromJson(jsonDecode(s.rawRuleJson) as Map<String, dynamic>);
      final xiangshu =
          builtinSoNovelSources.firstWhere((s) => s.name == '香书小说');
      expect(xiangshu.url, 'http://www.ibiqugu.net/');
      expect(ruleOf(xiangshu).search!.method, 'post');
      expect(ruleOf(xiangshu).chapter.filterTxt, contains(r'\(本章完\)'));
      final shuhaige =
          builtinSoNovelSources.firstWhere((s) => s.name == '书海阁小说网');
      expect(shuhaige.url, 'https://www.shuhaige.net/');
      expect(ruleOf(shuhaige).toc.item, contains('~'));
    });
  });
}
