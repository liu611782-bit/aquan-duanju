import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/provider/wenku8_page.dart' show Wenku8Rank;
import 'package:aquan_duanju/core/books/provider/wenku8_provider.dart';
import 'package:flutter_test/flutter_test.dart';

const String _searchHtml = '''
<div id="content"><table>
<tr><td><a href="/book/1234.htm">魔法禁书目录</a></td><td>镰池和马</td>
    <td><a href="/novel/1234/5678.htm">第二十二章</a></td><td>2024-05-01</td></tr>
</table></div>''';

const String _detailHtml = '''
<div id="title">魔法禁书目录</div>
<div id="info"><div id="content">
  <img src="https://img.wenku8.com/image/1234/1234s.jpg">作者：镰池和马
</div></div>
<div id="intro">科学与魔法交汇。</div>
<div id="content"><table>
<tr class="vc"><td>第一卷</td></tr>
<tr class="cc"><td><a href="/novel/1234/1001.htm">序章</a></td></tr>
<tr class="cc"><td><a href="/novel/1234/1002.htm">第一章</a></td></tr>
</table></div>''';

const String _chapterHtml = '''
<div id="content"><div id="title">序章</div>
<div id="content">正文第一段：夏天总是闷热，蝉鸣从树荫里一层层压下来。<br><br>
正文第二段：他推开宿舍的门，看见一只黑白相间的猫正趴在窗台上。</div></div>''';

/// 记录请求并按路径返回夹具。
class _Routes {
  final List<Uri> requests = [];

  Future<String> call(Uri uri) async {
    requests.add(uri);
    final path = uri.path;
    if (path.contains('search.php')) return _searchHtml;
    if (path.startsWith('/book/')) return _detailHtml;
    if (path.startsWith('/novel/')) return _chapterHtml;
    if (path.startsWith('/index.php')) {
      return '<div id="nav"><a href="/modules/article/articlelist.php?class=3">魔法</a></div>';
    }
    if (path.contains('articlelist.php')) return _searchHtml;
    if (path.contains('toplist.php')) return _searchHtml;
    throw StateError('未预期的请求：$uri');
  }
}

void main() {
  const source = BookSource(
    url: kWenku8DefaultBase,
    name: '轻小说文库（Wenku8）',
    format: BookSourceFormat.wenku8,
  );

  group('Wenku8Provider 内置源', () {
    test('format/builtin/builtinSources', () {
      final p = Wenku8Provider(fetch: (_) async => '');
      expect(p.format, BookSourceFormat.wenku8);
      expect(p.builtin, isTrue);
      expect(p.builtinSources, hasLength(1));
      expect(p.builtinSources.single.url, 'https://www.wenku8.net');
      expect(p.builtinSources.single.format, BookSourceFormat.wenku8);
      // 站点需登录：内置源默认停用，避免污染聚合搜索。
      expect(p.builtinSources.single.enabled, isFalse);
    });
  });

  group('Wenku8Provider 四连', () {
    test('搜索：关键词按 GBK 百分号编码，翻页参数透传', () async {
      final routes = _Routes();
      final p = Wenku8Provider(fetch: routes.call);
      final hits = await p.search(source, '魔法', page: 2);

      expect(hits, hasLength(1));
      expect(hits.single.bookUrl, 'wenku8://book/1234');
      final uri = routes.requests.single;
      expect(uri.path, '/modules/article/search.php');
      // GBK: 魔=C4A7 法=B7A8
      expect(uri.query, contains('searchkey=%C4%A7%B7%A8'));
      expect(uri.query, contains('page=2'));
      expect(uri.query, contains('searchtype=articlename'));
    });

    test('详情：书名/作者/简介/封面 + 分卷目录', () async {
      final p = Wenku8Provider(fetch: _Routes().call);
      final detail = await p.detail(source, 'wenku8://book/1234');

      expect(detail.name, '魔法禁书目录');
      expect(detail.author, '镰池和马');
      expect(detail.intro, '科学与魔法交汇。');
      expect(detail.coverUrl, contains('/image/1234/1234s.jpg'));
      expect(detail.chapters.map((c) => c.title), ['第一卷', '序章', '第一章']);
      expect(detail.chapters.first.isVolume, isTrue);
      expect(detail.chapters[1].url, 'wenku8://chapter/1234/1001');
    });

    test('正文：章节地址映射到 /novel/<aid>/<cid>.htm', () async {
      final routes = _Routes();
      final p = Wenku8Provider(fetch: routes.call);
      final text = await p.content(source, 'wenku8://chapter/1234/1001');

      expect(routes.requests.single.path, '/novel/1234/1001.htm');
      expect(text, contains('正文第一段'));
      expect(text, contains('正文第二段'));
      expect(text, startsWith('序章'));
    });

    test('非 Wenku8 地址直接拒绝（不构造非法请求）', () async {
      final p = Wenku8Provider(fetch: (_) async => '');
      await expectLater(
        p.detail(source, 'https://other.example/book/1.htm'),
        throwsA(isA<Exception>()),
      );
      await expectLater(
        p.content(source, 'wenku8://book/1234'),
        throwsA(isA<Exception>()),
      );
    });

    test('镜像域名：源 url 决定请求基址', () async {
      final routes = _Routes();
      final p = Wenku8Provider(fetch: routes.call);
      const mirror = BookSource(
        url: 'https://wenku8.example.org',
        name: '镜像',
        format: BookSourceFormat.wenku8,
      );
      await p.search(mirror, 'x');
      expect(routes.requests.single.toString(),
          startsWith('https://wenku8.example.org/modules/article/search.php'));
    });
  });

  group('Wenku8Provider 浏览与校验', () {
    test('分类从站点导航解析（不预置猜测 id）', () async {
      final p = Wenku8Provider(fetch: _Routes().call);
      final classes = await p.classes(source: source);
      expect(classes.single.id, '3');
      expect(classes.single.name, '魔法');
    });

    test('分类/排行列表走各自的站点入口', () async {
      final routes = _Routes();
      final p = Wenku8Provider(fetch: routes.call);

      await p.browseClass('5', page: 2);
      expect(routes.requests.last.path, '/modules/article/articlelist.php');
      expect(routes.requests.last.query, contains('class=5'));
      expect(routes.requests.last.query, contains('page=2'));

      await p.browseRank(Wenku8Rank.vote);
      expect(routes.requests.last.path, '/modules/article/toplist.php');
      expect(routes.requests.last.query, contains('sort=allvote'));
    });

    test('probe：搜索→详情→正文全通过', () async {
      final p = Wenku8Provider(fetch: _Routes().call);
      final check = await p.probe(source, query: '魔法');
      expect(check.ok, isTrue);
      expect(check.sampleChapterCount, 2);
      expect(check.sampleContentLength, greaterThan(30));
      expect(check.sampleHit?.name, '魔法禁书目录');
    });

    test('probe：搜索无结果 → search 阶段失败并给可读原因', () async {
      final p = Wenku8Provider(fetch: (_) async => '<html></html>');
      final check = await p.probe(source, query: 'zzz');
      expect(check.ok, isFalse);
      expect(check.stage, BookCheckStage.search);
      expect(check.reason, contains('搜索无结果'));
    });

    test('probe：正文页结构变化 → content 阶段失败（不误标 bookInfo）', () async {
      final p = Wenku8Provider(fetch: (uri) async {
        if (uri.path.contains('search.php')) return _searchHtml;
        if (uri.path.startsWith('/book/')) return _detailHtml;
        return '<html><body><div id="content"></div></body></html>';
      });
      final check = await p.probe(source, query: '魔法');
      expect(check.ok, isFalse);
      expect(check.stage, BookCheckStage.content);
      expect(check.reason, contains('站点结构变化'));
    });
  });

  test('Wenku8Rank 覆盖三种排序', () {
    expect(Wenku8Rank.values.map((r) => r.sort),
        ['allvisit', 'allvote', 'allflower']);
    expect(Wenku8Rank.values.map((r) => r.label),
        ['总点击', '总推荐', '总收藏']);
  });
}
