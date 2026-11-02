import 'package:aquan_duanju/core/books/formats/book_block.dart';
import 'package:aquan_duanju/core/reader/reader_typography.dart';
import 'package:aquan_duanju/core/reader/rich_paragraph.dart';
import 'package:aquan_duanju/widgets/rich_reader_view.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

ChapterBlocks _chapter(List<BookBlock> blocks) =>
    ChapterBlocks(title: '第一章', blocks: blocks);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('区块 → 富文本段落', () {
    test('注音/脚注/插图/分隔线/对齐全部保留', () {
      final chapter = richChapterFrom(_chapter([
        ParagraphBlock(
          const [
            TextInline('夏天的'),
            RubyInline('空', 'そら'),
            TextInline('很蓝'),
            NoteInline(label: '[1]', note: '注释正文'),
          ],
          align: BlockAlign.center,
          indent: true,
        ),
        const ImageBlock(href: 'img/p1.png', alt: '插图'),
        const ParagraphBlock([], divider: true),
        ParagraphBlock([TextInline('标题段')], headingLevel: 2),
      ]));

      // 4 段：注音段 / 插图 / 分隔线（空 spans 但 divider=true 要保留）/ 标题段
      expect(chapter.paragraphs, hasLength(4));
      expect(chapter.paragraphs[2].divider, isTrue);
      final first = chapter.paragraphs.first;
      expect(first.align, RichAlign.center);
      expect(first.indent, isTrue);
      expect(first.spans.whereType<RichSpan>().any((s) => s.isRuby), isTrue);
      expect(first.notes.single.note, '注释正文');
      expect(chapter.hasImages, isTrue);
      expect(chapter.paragraphs.last.isHeading, isTrue);

      // 纯文本：注音取基字、脚注取标记
      expect(chapter.plainText, contains('夏天的空很蓝[1]'));
      expect(chapter.plainText, isNot(contains('そら')));
    });

    test('纯文本段落 isPlain=true，带注音的段落 isPlain=false', () {
      final chapter = richChapterFrom(_chapter([
        ParagraphBlock.text('普通段落'),
        ParagraphBlock(const [RubyInline('漢', 'かん')]),
      ]));
      expect(chapter.paragraphs[0].isPlain, isTrue);
      expect(chapter.paragraphs[1].isPlain, isFalse);
    });

    test('paragraphOffsets 与 plainText 对齐', () {
      final chapter = richChapterFrom(_chapter([
        ParagraphBlock.text('abc'),
        ParagraphBlock.text('de'),
      ]));
      expect(chapter.paragraphOffsets(), [0, 4]);
    });
  });

  group('横排分页', () {
    const typography = ReaderTypography(fontSize: 20, lineHeight: 1.6);

    test('长普通段落会被切成多页，且不丢字', () {
      final text = '这是一个很长的段落。' * 200;
      final chapter = richChapterFrom(_chapter([ParagraphBlock.text(text)]));
      final paginator = RichPaginator(
        typography: typography,
        width: 320,
        height: 240,
      );
      final pages = paginator.paginate(chapter);
      expect(pages.length, greaterThan(1));

      final merged = pages
          .expand((p) => p.paragraphs)
          .map((p) => p.plainText)
          .join();
      expect(merged, text);
    });

    test('含注音的段落整段不拆（宁留白）', () {
      final chapter = richChapterFrom(_chapter([
        ParagraphBlock.text('起始段落'),
        ParagraphBlock(const [
          RubyInline('漢字', 'かんじ'),
        ]),
      ]));
      final paginator = RichPaginator(
        typography: typography,
        width: 320,
        height: 90,
      );
      final pages = paginator.paginate(chapter);
      final rubyParagraphs = pages
          .expand((p) => p.paragraphs)
          .where((p) => p.spans.any((s) => s.isRuby))
          .toList();
      expect(rubyParagraphs, hasLength(1));
      expect(rubyParagraphs.single.spans.single.ruby, 'かんじ');
    });

    test('空章节也返回一页（不崩）', () {
      final chapter = richChapterFrom(_chapter([const BlankBlock()]));
      final pages = RichPaginator(
        typography: typography,
        width: 320,
        height: 240,
      ).paginate(chapter);
      expect(pages, hasLength(1));
    });
  });

  group('竖排断页与禁则', () {
    VerticalTextLayout layout({int columns = 1, double width = 400}) =>
        VerticalTextLayout(
          typography: const ReaderTypography(fontSize: 20, lineHeight: 1.5),
          size: Size(width, 600),
          columnsPerPage: columns,
        );

    test('按时长切页，字符不丢', () {
      final text = 'あ' * 2000;
      final pages = layout().split(text);
      expect(pages.length, greaterThan(1));
      expect(pages.join(), text);
    });

    test('页首不出现闭标点（行首禁则）', () {
      // 构造：页容量边界恰好落在「。」上。
      final l = layout();
      final filler = 'あ' * (l.charsPerPage - 1);
      final pages = l.split('$filler。后续');
      expect(pages.first.endsWith('。'), isTrue,
          reason: '闭标点应被拉到上一页末尾，而不是出现在下一页开头');
      expect(pages[1].startsWith('。'), isFalse);
    });

    test('页尾不出现开标点（行末禁则）', () {
      final l = layout();
      final filler = 'あ' * (l.charsPerPage - 1);
      final pages = l.split('$filler「引用」');
      expect(pages.first.endsWith('「'), isFalse);
    });

    test('英文单词不跨页断开', () {
      final l = layout();
      final filler = 'あ' * (l.charsPerPage - 3);
      final pages = l.split('${filler}Flutter');
      final last = pages.first;
      expect(last.endsWith('F') || last.endsWith('Fl') || last.endsWith('Flu'),
          isFalse);
    });

    test('空文本返回单页', () {
      expect(layout().split(''), hasLength(1));
    });
  });
}
