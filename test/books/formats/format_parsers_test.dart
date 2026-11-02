import 'dart:convert';
import 'dart:typed_data';

import 'package:aquan_duanju/core/books/formats/book_block.dart';
import 'package:aquan_duanju/core/books/formats/book_format_parser.dart';
import 'package:aquan_duanju/core/books/formats/default_registry.dart';
import 'package:aquan_duanju/core/books/formats/epub_book_parser.dart';
import 'package:aquan_duanju/core/books/formats/html_book_parser.dart';
import 'package:aquan_duanju/core/books/formats/markdown_book_parser.dart';
import 'package:aquan_duanju/core/books/formats/txt_book_parser.dart';
import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';

BookFileRef _ref(String name, List<int> bytes) => BookFileRef(
      fileName: name,
      bytes: Uint8List.fromList(bytes),
      sizeBytes: bytes.length,
    );

List<int> _zip(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = entry.value;
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return ZipEncoder().encode(archive);
}

/// 一份最小但完整的 EPUB（EPUB3 nav + 注音 + 脚注 + 插图 + CSS）。
Map<String, List<int>> _epubFiles() {
  final container = '''<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>''';

  final opf = '''<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>魔法禁书目录 第一卷</dc:title>
    <dc:creator>镰池和马</dc:creator>
    <dc:description>科学与魔法交汇。</dc:description>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="image/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
  </manifest>
  <spine><itemref idref="c1"/><itemref idref="c2"/></spine>
</package>''';

  final nav = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
<nav epub:type="toc" xmlns:epub="http://www.idpf.org/2007/ops">
  <ol>
    <li><a href="text/ch1.xhtml">第一章 学园都市</a></li>
    <li><a href="text/ch2.xhtml">第二章 魔法</a></li>
  </ol>
</nav></body></html>''';

  final ch1 = '''<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head><style>
  .center { text-align: center; }
  .indent { text-indent: 2em; }
</style></head>
<body>
  <h1>第一章 学园都市</h1>
  <p class="indent">夏天的<ruby>空<rt>そら</rt></ruby>很蓝。</p>
  <p class="center">居中的题记</p>
  <p>上条当麻<sup><a epub:type="noteref" href="#n1">[1]</a></sup>推开门。</p>
  <img src="../image/pic1.png" alt="插图一"/>
  <hr/>
  <p>最后一段。</p>
  <aside epub:type="footnote" id="n1">[1] 上条当麻：本作主角。</aside>
</body></html>''';

  final ch2 = '<html><body><h1>第二章 魔法</h1><p>第二段正文。</p></body></html>';

  return {
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode(container),
    'OEBPS/content.opf': utf8.encode(opf),
    'OEBPS/nav.xhtml': utf8.encode(nav),
    'OEBPS/text/ch1.xhtml': utf8.encode(ch1),
    'OEBPS/text/ch2.xhtml': utf8.encode(ch2),
    'OEBPS/image/cover.jpg': [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3],
    'OEBPS/image/pic1.png': [0x89, 0x50, 0x4E, 0x47, 1, 2, 3],
  };
}

void main() {
  group('注册表', () {
    test('标准注册表覆盖五类格式', () {
      final registry = standardBookFormatRegistry();
      expect(registry.supportedExtensions,
          containsAll(['txt', 'epub', 'html', 'htm', 'xhtml', 'md', 'markdown', 'zip']));
      expect(registry.resolve('a.TXT').id, 'txt');
      expect(registry.resolve('a.epub').id, 'epub');
      expect(registry.resolve('a.md').id, 'markdown');
      expect(registry.resolve('a.zip').id, 'zip');
    });

    test('不支持的格式诚实抛 UnsupportedBookFormat', () {
      expect(
        () => standardBookFormatRegistry().resolve('a.mobi'),
        throwsA(isA<UnsupportedBookFormat>()
            .having((e) => e.extension, 'ext', 'mobi')
            .having((e) => e.toString(), 'message', contains('暂不支持'))),
      );
    });

    test('无扩展名也诚实报错', () {
      expect(
        () => standardBookFormatRegistry().resolve('README'),
        throwsA(isA<UnsupportedBookFormat>()),
      );
    });
  });

  group('TXT', () {
    const text = '第一章 起点\n正文一\n\n正文二\n第二章 发展\n正文三\n';

    test('UTF-8：按章节正则切分，正文进 ParagraphBlock', () async {
      final book = await const TxtBookParser().parse(_ref('我的书.txt', utf8.encode(text)));
      expect(book.title, '我的书');
      expect(book.chapters.map((c) => c.title), ['第一章 起点', '第二章 发展']);
      final first = book.chapters.first.blocks
          .whereType<ParagraphBlock>()
          .map((b) => b.plainText)
          .toList();
      expect(first, ['正文一', '正文二']);
      expect(book.chapterCount, 2);
      expect(book.formatId, 'txt');
    });

    test('GBK：自动嗅探解码，不出乱码', () async {
      final book = await const TxtBookParser().parse(_ref('gbk.txt', gbk.encode(text)));
      expect(book.chapters.first.title, '第一章 起点');
      expect(book.chapters.first.blocks.first, isA<ParagraphBlock>());
      expect((book.chapters.first.blocks.first as ParagraphBlock).plainText, '正文一');
    });

    test('无章节标题：整本单章', () async {
      final book = await const TxtBookParser()
          .parse(_ref('无章节.txt', utf8.encode('只有一段文字。\n还有一段。')));
      expect(book.chapters, hasLength(1));
      expect(book.chapters.single.title, '无章节');
    });

    test('超长物理行按 4000 截断（代理对边界安全）', () async {
      final long = '甲' * 5000;
      final book = await const TxtBookParser().parse(_ref('long.txt', utf8.encode(long)));
      final plain = book.chapters.single.blocks
          .whereType<ParagraphBlock>()
          .map((b) => b.plainText)
          .join();
      expect(plain.length, 4000);
    });

    test('纯文本可回读（plainText 与章节拼接一致）', () async {
      final book = await const TxtBookParser().parse(_ref('b.txt', utf8.encode(text)));
      expect(book.chapters.first.toBlocks().plainText, contains('正文一'));
    });
  });

  group('EPUB', () {
    late ParsedBook book;

    setUpAll(() async {
      book = await const EpubBookParser().parse(_ref('魔法.epub', _zip(_epubFiles())));
    });

    test('元数据：书名/作者/简介/封面', () {
      expect(book.title, '魔法禁书目录 第一卷');
      expect(book.author, '镰池和马');
      expect(book.intro, '科学与魔法交汇。');
      expect(book.coverBytes, isNotNull);
      expect(book.coverBytes!.first, 0xFF);
    });

    test('目录按 nav 取章节名，spine 顺序', () {
      expect(book.chapters.map((c) => c.title), ['第一章 学园都市', '第二章 魔法']);
    });

    test('注音 ruby → RubyInline（基字/注音分离）', () {
      final blocks = book.chapters.first.blocks.whereType<ParagraphBlock>().toList();
      final ruby = blocks
          .expand((b) => b.inlines)
          .whereType<RubyInline>()
          .toList();
      expect(ruby, hasLength(1));
      expect(ruby.single.base, '空');
      expect(ruby.single.ruby, 'そら');
      final rubyParagraph =
          blocks.firstWhere((b) => b.inlines.any((i) => i is RubyInline));
      expect(rubyParagraph.plainText, '夏天的空很蓝。');
    });

    test('脚注链接 → NoteInline（同文档 aside 解析出注释体）', () {
      final notes = book.chapters.first.blocks
          .whereType<ParagraphBlock>()
          .expand((b) => b.notes)
          .toList();
      expect(notes, hasLength(1));
      expect(notes.single.label, '[1]');
      expect(notes.single.note, contains('上条当麻'));
    });

    test('插图 → ImageBlock，href 解析为包内绝对路径', () {
      final images = book.chapters.first.blocks.whereType<ImageBlock>().toList();
      expect(images, hasLength(1));
      expect(images.single.href, 'OEBPS/image/pic1.png');
      expect(images.single.alt, '插图一');
    });

    test('CSS 白名单：text-align=center / text-indent 生效', () {
      final blocks = book.chapters.first.blocks
          .whereType<ParagraphBlock>()
          .where((b) => !b.isHeading)
          .toList();
      final centered = blocks.where((b) => b.align == BlockAlign.center).toList();
      expect(centered.map((b) => b.plainText), contains('居中的题记'));
      final indented = blocks.where((b) => b.indent).toList();
      expect(indented, isNotEmpty);
    });

    test('<hr> 变成带分隔线标记的空段', () {
      final dividers = book.chapters.first.blocks
          .whereType<ParagraphBlock>()
          .where((b) => b.divider)
          .toList();
      expect(dividers, isNotEmpty);
    });

    test('资源可解析（插图/封面字节）', () async {
      final bytes = await book.resources.resolve('OEBPS/image/pic1.png');
      expect(bytes, isNotNull);
      expect(book.resources.mimeOf('OEBPS/image/cover.jpg'), 'image/jpeg');
    });

    test('损坏 zip → BookFormatException（不崩溃）', () async {
      await expectLater(
        const EpubBookParser().parse(_ref('坏.epub', [1, 2, 3, 4])),
        throwsA(isA<BookFormatException>()),
      );
    });

    test('缺 container.xml → 明确报「不是有效的 EPUB」', () async {
      final bytes = _zip({'a.txt': utf8.encode('x')});
      await expectLater(
        const EpubBookParser().parse(_ref('x.epub', bytes)),
        throwsA(isA<BookFormatException>()
            .having((e) => e.message, 'msg', contains('container.xml'))),
      );
    });
  });

  group('HTML', () {
    test('≥2 个标题按章切分', () {
      final book = parseHtmlBookText(
        '<html><head><title>某书</title></head><body>'
        '<h1>第一章</h1><p>甲</p><h2>第二章</h2><p>乙</p>'
        '</body></html>',
        fallbackTitle: '兜底',
      );
      expect(book.title, '某书');
      expect(book.chapters.map((c) => c.title), ['第一章', '第二章']);
    });

    test('少于 2 个标题 → 整篇一章', () {
      final book = parseHtmlBookText(
        '<html><body><p>只有一段</p><p>第二段</p></body></html>',
        fallbackTitle: '整篇',
      );
      expect(book.chapters, hasLength(1));
      expect(book.chapters.single.title, '整篇');
      expect(book.chapters.single.blocks.whereType<ParagraphBlock>(), hasLength(2));
    });

    test('加粗/斜体保留为 TextInline 标志', () {
      final book = parseHtmlBookText(
        '<html><body><p>普通<strong>加粗</strong><em>斜体</em></p></body></html>',
        fallbackTitle: 'x',
      );
      final inlines = book.chapters.single.blocks
          .whereType<ParagraphBlock>()
          .expand((b) => b.inlines)
          .whereType<TextInline>()
          .toList();
      expect(inlines.any((i) => i.bold), isTrue);
      expect(inlines.any((i) => i.italic), isTrue);
    });

    test('空 body 诚实报错', () {
      expect(
        () => parseHtmlBookText('<html><body></body></html>', fallbackTitle: 'x'),
        throwsA(isA<BookFormatException>()),
      );
    });
  });

  group('Markdown', () {
    test('标题切章 + 行内强调', () {
      final book = parseMarkdownBookText(
        '# 第一章\n\n正文**加粗**。\n\n## 第二章\n\n结尾。\n',
        fallbackTitle: 'md',
      );
      expect(book.chapters.map((c) => c.title), ['第一章', '第二章']);
      expect(book.formatId, 'markdown');
      final bold = book.chapters.first.blocks
          .whereType<ParagraphBlock>()
          .expand((b) => b.inlines)
          .whereType<TextInline>()
          .any((i) => i.bold);
      expect(bold, isTrue);
    });

    test('BOM 与非法字节：不中断解析', () {
      final text = decodeMarkdownBytes([0xEF, 0xBB, 0xBF, ...utf8.encode('# 标题\n正文')]);
      expect(text.startsWith('# 标题'), isTrue);
      expect(decodeMarkdownBytes([0xFF, 0xFF]), isNotEmpty);
    });
  });

  group('ZIP', () {
    test('多文本条目：按名称排序、标题前缀文件名', () async {
      final bytes = _zip({
        'b.txt': utf8.encode('第二章 后\n内容乙'),
        'a.txt': utf8.encode('第一章 前\n内容甲'),
      });
      final book = await standardBookFormatRegistry()
          .resolve('合集.zip')
          .parse(_ref('合集.zip', bytes));
      expect(book.title, '合集');
      expect(book.chapters, hasLength(2));
      expect(book.chapters.first.title, contains('a · 第一章 前'));
      expect(book.chapters.last.title, contains('b · 第二章 后'));
    });

    test('单文本条目不加前缀', () async {
      final bytes = _zip({'only.txt': utf8.encode('第一章 唯一\n正文')});
      final book = await standardBookFormatRegistry()
          .resolve('单.zip')
          .parse(_ref('单.zip', bytes));
      expect(book.chapters.single.title, '第一章 唯一');
    });

    test('zip-slip 条目被忽略', () async {
      final bytes = _zip({
        '../evil.txt': utf8.encode('第一章 坏\n坏内容'),
        'ok.txt': utf8.encode('第一章 好\n好内容'),
      });
      final book = await standardBookFormatRegistry()
          .resolve('x.zip')
          .parse(_ref('x.zip', bytes));
      expect(book.chapters, hasLength(1));
      expect(book.chapters.single.title, contains('好'));
    });

    test('包内 epub 直接交给 EPUB 解析（保留目录/注音能力）', () async {
      final epub = _zip(_epubFiles());
      final bytes = _zip({'book.epub': epub});
      final book = await standardBookFormatRegistry()
          .resolve('打包.zip')
          .parse(_ref('打包.zip', bytes));
      expect(book.formatId, 'epub');
      expect(book.chapters.first.title, '第一章 学园都市');
    });

    test('没有可读文本条目 → 明确报错', () async {
      final bytes = _zip({'a.jpg': [1, 2, 3]});
      await expectLater(
        standardBookFormatRegistry().resolve('x.zip').parse(_ref('x.zip', bytes)),
        throwsA(isA<BookFormatException>()),
      );
    });

    test('损坏 zip → BookFormatException', () async {
      await expectLater(
        standardBookFormatRegistry().resolve('x.zip').parse(_ref('x.zip', [9, 9, 9])),
        throwsA(isA<BookFormatException>()),
      );
    });
  });

  group('ChapterBlocks', () {
    test('plainText 段间换行、插图占空行', () {
      final chapter = ChapterBlocks(title: 't', blocks: [
        ParagraphBlock.text('第一段'),
        const ImageBlock(href: 'a.png'),
        ParagraphBlock.text('第二段'),
      ]);
      expect(chapter.plainText, contains('第一段'));
      expect(chapter.plainText, contains('第二段'));
      expect(chapter.hasImages, isTrue);
    });

    test('paragraphOffsets 与正文偏移一致', () {
      final chapter = ChapterBlocks(title: 't', blocks: [
        ParagraphBlock.text('abc'),
        ParagraphBlock.text('de'),
      ]);
      expect(chapter.paragraphOffsets(), [0, 4]);
    });
  });
}
