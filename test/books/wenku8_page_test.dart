import 'dart:typed_data';

import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/provider/wenku8_page.dart';
import 'package:aquan_duanju/core/book_markup.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

/// 站点结构夹具（GBK 老站的真实形状：`#content` 内表格 + `tr.vc/tr.cc`）。
const String _base = 'https://www.wenku8.net';

const String _searchHtml = '''
<html><head><meta charset="gbk"></head><body>
<div id="content">
<table class="grid" width="100%">
  <tr><td class="odd">书名</td><td class="odd">作者</td><td class="odd">最新章节</td></tr>
  <tr>
    <td class="odd"><a href="/book/1234.htm">魔法禁书目录</a></td>
    <td class="odd">镰池和马</td>
    <td class="odd"><a href="/novel/1234/5678.htm">第二十二章 远方的钟声</a></td>
    <td class="odd">2024-05-01</td>
  </tr>
  <tr>
    <td class="odd"><a href="/book/5678.htm">文学少女</a></td>
    <td class="odd">野村美月</td>
    <td class="odd"><a href="/novel/5678/9999.htm">终章</a></td>
    <td class="odd">2023-11-11</td>
  </tr>
</table>
</div>
</body></html>
''';

const String _detailHtml = '''
<html><head><title>魔法禁书目录_轻小说文库</title></head><body>
<div id="title">魔法禁书目录</div>
<div id="info">
  <div id="content">
    <img src="https://img.wenku8.com/image/1234/1234s.jpg" alt="封面">
    作者：镰池和马<br>
    状态：连载中
  </div>
</div>
<div id="intro">当科学与魔法交汇之时，故事开始了。</div>
<div id="content">
<table class="css" width="100%">
  <tr class="vc"><td colspan="2">第一卷 旧约</td></tr>
  <tr class="cc"><td class="ccss"><a href="/novel/1234/1001.htm">序章</a></td></tr>
  <tr class="cc"><td class="ccss"><a href="/novel/1234/1002.htm">第一章 学园都市</a></td></tr>
  <tr class="vc"><td colspan="2">第二卷 新约</td></tr>
  <tr class="cc"><td class="ccss"><a href="/novel/1234/2001.htm">第一章 新的开始</a></td></tr>
</table>
</div>
</body></html>
''';

const String _contentHtml = '''
<html><head><meta charset="gbk"></head><body>
<div id="content">
  <table><tr><td><a href="/">首页</a> | <a href="/book/1234.htm">目录</a></td></tr></table>
  <div id="title">第一章 学园都市</div>
  <div id="content">
    学园都市的夏天总是闷热。<br><br>
    上条当麻推开宿舍的门，&nbsp;看见一只猫。<br>
    <script>alert('ad')</script>
    <div id="ad_top">广告位</div>
    <a href="https://ad.example.com">赞助商</a>
    他叹了口气。
  </div>
</div>
</body></html>
''';

void main() {
  group('decodeMarkupBytes × Wenku8', () {
    test('GBK 页面按 meta 解码后解析器可用', () {
      final bytes = Uint8List.fromList(gbk.encode(_searchHtml));
      final html = decodeMarkupBytes(bytes).text;
      final hits = parseWenku8ListPage(html, baseUrl: _base);
      expect(hits, hasLength(2));
      expect(hits.first.name, '魔法禁书目录');
    });
  });

  group('parseWenku8ListPage', () {
    test('搜索/排行表格：书名/作者/最新章节/规范化书号', () {
      final hits = parseWenku8ListPage(_searchHtml, baseUrl: _base);
      expect(hits, hasLength(2));

      final first = hits.first;
      expect(first.name, '魔法禁书目录');
      expect(first.author, '镰池和马');
      expect(first.bookUrl, 'wenku8://book/1234');
      expect(first.lastChapter, '第二十二章 远方的钟声');
      expect(first.isMeaningful, isTrue);
    });

    test('表头行被跳过（无 /book/ 链接）', () {
      final hits = parseWenku8ListPage(_searchHtml, baseUrl: _base);
      expect(hits.map((h) => h.name), ['魔法禁书目录', '文学少女']);
    });

    test('同书多行去重', () {
      const html = '''
<div id="content"><table>
<tr><td><a href="/book/1.htm">甲</a></td><td>作者A</td></tr>
<tr><td><a href="/book/1.htm">甲（重复）</a></td><td>作者A</td></tr>
</table></div>''';
      final hits = parseWenku8ListPage(html, baseUrl: _base);
      expect(hits, hasLength(1));
      expect(hits.single.bookUrl, 'wenku8://book/1');
    });

    test('无表格结构的改版页：按书名链接兜底', () {
      const html = '''
<div id="content"><ul>
<li><a href="/book/42.htm">某科学的超电磁炮</a></li>
<li><a href="/book/43.htm">某魔法的禁书目录</a></li>
</ul></div>''';
      final hits = parseWenku8ListPage(html, baseUrl: _base);
      expect(hits, hasLength(2));
      expect(hits.first.bookUrl, 'wenku8://book/42');
    });

    test('空页面返回空表（不抛）', () {
      expect(parseWenku8ListPage('<html></html>', baseUrl: _base), isEmpty);
    });
  });

  group('parseWenku8Detail', () {
    test('书名/作者/简介/封面', () {
      final info = parseWenku8Detail(_detailHtml, baseUrl: _base);
      expect(info.name, '魔法禁书目录');
      expect(info.author, '镰池和马');
      expect(info.intro, '当科学与魔法交汇之时，故事开始了。');
      expect(info.coverUrl, 'https://img.wenku8.com/image/1234/1234s.jpg');
    });

    test('只有 <title> 时去掉站名后缀且保留书名内的连字符', () {
      const html =
          '<html><head><title>奇诺之旅-某段旅程_轻小说文库</title></head><body></body></html>';
      final info = parseWenku8Detail(html, baseUrl: _base);
      expect(info.name, '奇诺之旅-某段旅程');
      expect(info.author, isEmpty);
    });
  });

  group('parseWenku8Toc', () {
    test('分卷层级保序，卷项 isVolume=true 且 url 为空', () {
      final toc = parseWenku8Toc(_detailHtml, baseUrl: _base);
      expect(toc.map((t) => t.title), [
        '第一卷 旧约',
        '序章',
        '第一章 学园都市',
        '第二卷 新约',
        '第一章 新的开始',
      ]);
      expect(toc[0].isVolume, isTrue);
      expect(toc[0].url, isEmpty);
      expect(toc[1].isVolume, isFalse);
      expect(toc[1].url, 'wenku8://chapter/1234/1001');
    });

    test('章节 url 同 cid 去重', () {
      const html = '''
<div id="content"><table>
<tr class="cc"><td><a href="/novel/1/10.htm">第一章</a></td></tr>
<tr class="cc"><td><a href="/novel/1/10.htm">第一章（重复）</a></td></tr>
</table></div>''';
      final toc = parseWenku8Toc(html, baseUrl: _base);
      expect(toc, hasLength(1));
    });

    test('无 tr.vc/cc 时按链接兜底', () {
      const html = '''
<div id="content">
<a href="/novel/9/1.htm">第一章 起点</a>
<a href="/novel/9/2.htm">第二章 出发</a>
</div>''';
      final toc = parseWenku8Toc(html, baseUrl: _base);
      expect(toc, hasLength(2));
      expect(toc.last.url, 'wenku8://chapter/9/2');
    });
  });

  group('parseWenku8Content', () {
    test('取最长 #content，剥离脚本/广告/导航，保留段落换行', () {
      final text = parseWenku8Content(_contentHtml);
      expect(text, startsWith('第一章 学园都市'));
      expect(text, contains('学园都市的夏天总是闷热。'));
      expect(text, contains('看见一只猫。'));
      expect(text, contains('他叹了口气。'));
      expect(text, isNot(contains('广告位')));
      expect(text, isNot(contains('赞助商')));
      expect(text, isNot(contains('alert')));
      expect(text, isNot(contains('首页')));
    });

    test('正文为空 → Wenku8PageException（诚实报结构变化）', () {
      const html = '<html><body><div id="content"><script>a</script></div></body></html>';
      expect(
        () => parseWenku8Content(html),
        throwsA(isA<Wenku8PageException>()
            .having((e) => e.stage, 'stage', '正文页')),
      );
    });
  });

  group('parseWenku8Classes', () {
    test('从导航链接解析真实分类，去重保序', () {
      const html = '''
<div id="nav">
  <a href="/modules/article/articlelist.php?class=1">校园</a>
  <a href="/modules/article/articlelist.php?class=2">恋爱</a>
  <a href="/modules/article/articlelist.php?class=1">校园(重复)</a>
  <a href="/modules/article/articlelist.php">全部</a>
</div>''';
      final classes = parseWenku8Classes(html);
      expect(classes.map((c) => c.id), ['1', '2']);
      expect(classes.first.name, '校园');
    });

    test('解析不到分类返回空表（UI 隐藏入口，不伪造）', () {
      expect(parseWenku8Classes('<html></html>'), isEmpty);
    });
  });

  group('引用解析', () {
    test('书名/章节三种写法都能认', () {
      expect(Wenku8BookRef.tryParse('wenku8://book/123')!.aid, '123');
      expect(Wenku8BookRef.tryParse('https://www.wenku8.net/book/123.htm')!.aid, '123');
      expect(Wenku8BookRef.tryParse('https://www.wenku8.net/index.php'), isNull);

      final ch = Wenku8ChapterRef.tryParse('wenku8://chapter/123/456')!;
      expect(ch.pagePath, '/novel/123/456.htm');
      expect(
        Wenku8ChapterRef.tryParse('https://www.wenku8.net/novel/1/2.htm')!.cid,
        '2',
      );
      expect(Wenku8ChapterRef.tryParse('wenku8://book/1'), isNull);
    });
  });

  test('BookTocItem 卷/章契约与阅读器目录一致', () {
    final toc = parseWenku8Toc(_detailHtml, baseUrl: _base);
    final chapters = toc.where((t) => !t.isVolume).toList();
    expect(chapters.every((c) => c.url.startsWith('wenku8://chapter/')), isTrue);
    expect(chapters.first, isA<BookTocItem>());
  });
}
