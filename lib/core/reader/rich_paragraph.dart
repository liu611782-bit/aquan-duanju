/// 富文本段落模型（阅读器渲染层）：`formats/book_block.dart` 的区块 →
/// 可测量/可渲染的段落（含行内样式、注音、脚注、插图占位）。
///
/// 与 `ReaderPageLine`（纯文本分页）并存：TXT/在线源继续走纯文本，
/// 本地 EPUB 走富文本；两者都用**章内字符偏移**作进度锚点，所以进度/书签不用迁移。
library;

import '../books/formats/book_block.dart';

/// 行内片段。
class RichSpan {
  const RichSpan.text(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.superscript = false,
    this.underline = false,
  })  : note = null,
        ruby = null,
        imageHref = null;

  /// 注音：`text` 为基字，`ruby` 为注音。
  const RichSpan.ruby(this.text, String this.ruby)
      : bold = false,
        italic = false,
        superscript = false,
        underline = false,
        note = null,
        imageHref = null;

  /// 脚注：正文显示 `text`（如 `[1]`），点击弹窗显示 [note]。
  const RichSpan.note(this.text, String this.note)
      : bold = false,
        italic = false,
        superscript = true,
        underline = false,
        ruby = null,
        imageHref = null;

  /// 插图（`imageHref` 为包内路径，由 resolver 取字节）。
  const RichSpan.image(String this.imageHref)
      : text = '',
        bold = false,
        italic = false,
        superscript = false,
        underline = false,
        note = null,
        ruby = null;

  final String text;
  final bool bold;
  final bool italic;
  final bool superscript;
  final bool underline;
  final String? ruby;
  final String? note;
  final String? imageHref;

  bool get isImage => imageHref != null;
  bool get isNote => note != null;
  bool get isRuby => ruby != null;

  /// 纯文本形态（注音取基字、脚注取标记）。
  String get plain => text;
}

/// 对齐（与 [BlockAlign] 同值语义，避免渲染层依赖 formats 包）。
enum RichAlign { start, center, end, justify }

/// 一个可渲染段落。
class RichParagraph {
  const RichParagraph({
    required this.spans,
    this.align = RichAlign.start,
    this.divider = false,
    this.headingLevel = 0,
    this.indent = false,
  });

  final List<RichSpan> spans;
  final RichAlign align;

  /// 段前分隔线。
  final bool divider;

  /// 1..6 = 标题层级。
  final int headingLevel;

  /// 首行缩进两字。
  final bool indent;

  bool get isHeading => headingLevel > 0;

  /// 是否纯文本（无注音/脚注/插图，可直接按字符切页）。
  bool get isPlain => spans.every((s) => !s.isImage && !s.isRuby && !s.isNote);

  String get plainText => spans.map((s) => s.plain).join();

  /// 段内所有脚注（渲染时挂点击）。
  List<RichSpan> get notes => [
        for (final s in spans)
          if (s.isNote) s,
      ];
}

/// 一章的富文本内容。
class RichChapter {
  const RichChapter({
    required this.title,
    required this.paragraphs,
  });

  final String title;
  final List<RichParagraph> paragraphs;

  /// 纯文本（与 [ChapterBlocks.plainText] 同源语义：段间 `\n`）。
  String get plainText {
    final buffer = StringBuffer();
    for (final p in paragraphs) {
      final text = p.plainText.trimRight();
      if (text.isEmpty) {
        if (buffer.isNotEmpty) buffer.write('\n');
        continue;
      }
      if (buffer.isNotEmpty) buffer.write('\n');
      buffer.write(text);
    }
    return buffer.toString();
  }

  bool get hasImages => paragraphs.any((p) => p.spans.any((s) => s.isImage));

  /// 每个段落首字符在 [plainText] 中的偏移。
  List<int> paragraphOffsets() {
    final offsets = <int>[];
    var cursor = 0;
    for (final p in paragraphs) {
      offsets.add(cursor);
      cursor += p.plainText.length + 1;
    }
    return offsets;
  }
}

/// 区块 → 富文本段落。
RichChapter richChapterFrom(ChapterBlocks chapter) => RichChapter(
      title: chapter.title,
      paragraphs: [
        for (final block in chapter.blocks) ?_paragraphOf(block),
      ],
    );

RichParagraph? _paragraphOf(BookBlock block) {
  switch (block) {
    case ParagraphBlock():
      final spans = <RichSpan>[];
      for (final inline in block.inlines) {
        switch (inline) {
          case TextInline():
            spans.add(RichSpan.text(
              inline.text,
              bold: inline.bold,
              italic: inline.italic,
              superscript: inline.superscript,
              underline: inline.underline,
            ));
          case RubyInline():
            spans.add(RichSpan.ruby(inline.base, inline.ruby));
          case NoteInline():
            spans.add(RichSpan.note(inline.label, inline.note));
          case BreakInline():
            spans.add(const RichSpan.text('\n'));
        }
      }
      if (spans.isEmpty && !block.divider) return null;
      return RichParagraph(
        spans: spans,
        align: switch (block.align) {
          BlockAlign.start => RichAlign.start,
          BlockAlign.center => RichAlign.center,
          BlockAlign.end => RichAlign.end,
          BlockAlign.justify => RichAlign.justify,
        },
        divider: block.divider,
        headingLevel: block.headingLevel,
        indent: block.indent,
      );
    case ImageBlock():
      return RichParagraph(spans: [RichSpan.image(block.href)]);
    case BlankBlock():
      return null;
  }
}
