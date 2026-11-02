/// 本地书的**富文本区块模型**：解析器（txt/epub/html/md/zip）产出的统一中间表示，
/// 阅读器（T5 富文本）与纯文本适配（TXT 旧路径）都从这里取。
///
/// 设计约束：
/// - 不引用 Flutter（纯 Dart，可单测、可 isolate）；
/// - `ParagraphBlock.plainText` 是搜索/字符偏移/旧渲染的唯一事实来源；
/// - 新增块类型只增不改，旧解析器无需改动。
library;

/// 段落对齐（来自 EPUB CSS 的 text-align 子集）。
enum BlockAlign { start, center, end, justify }

/// 行内元素。
sealed class BookInline {
  const BookInline();

  /// 纯文本形态（ruby 取基字，脚注取标记，break 取空格）。
  String get plain;
}

/// 普通文本（可带粗体/斜体/上标/下划线）。
class TextInline extends BookInline {
  const TextInline(
    this.text, {
    this.bold = false,
    this.italic = false,
    this.superscript = false,
    this.underline = false,
  });

  final String text;
  final bool bold;
  final bool italic;
  final bool superscript;
  final bool underline;

  @override
  String get plain => text;

  @override
  String toString() => 'TextInline(${text.length})';
}

/// 注音（EPUB `<ruby>基字<rt>注音</rt></ruby>`）。
class RubyInline extends BookInline {
  const RubyInline(this.base, this.ruby);

  final String base;
  final String ruby;

  @override
  String get plain => base;
}

/// 脚注引用：正文显示 [label]（如 `[1]`），点击弹窗展示 [note]。
class NoteInline extends BookInline {
  const NoteInline({required this.label, required this.note});

  final String label;
  final String note;

  @override
  String get plain => label;
}

/// 强制换行（`<br>`）。
class BreakInline extends BookInline {
  const BreakInline();

  @override
  String get plain => '\n';
}

/// 块级元素。
sealed class BookBlock {
  const BookBlock();
}

/// 段落：一段连续文本（可含行内样式）。
class ParagraphBlock extends BookBlock {
  const ParagraphBlock(
    this.inlines, {
    this.align = BlockAlign.start,
    this.divider = false,
    this.headingLevel = 0,
    this.indent = false,
  });

  final List<BookInline> inlines;
  final BlockAlign align;

  /// 是否在段前画分隔线（EPUB 的 `border-top` / `<hr>`）。
  final bool divider;

  /// 1..6 = 标题层级；0 = 正文段落。
  final int headingLevel;

  /// 首行缩进（CSS `text-indent`）。
  final bool indent;

  bool get isHeading => headingLevel > 0;

  /// 纯文本（ruby 取基字、脚注取标记、break 转换行）。
  String get plainText => inlines.map((i) => i.plain).join();

  /// 段落里所有脚注（阅读器点击上标时按 label 查）。
  List<NoteInline> get notes => [
        for (final i in inlines)
          if (i is NoteInline) i,
      ];

  /// 纯文本段落（TXT / Markdown 等无样式来源）。
  factory ParagraphBlock.text(
    String text, {
    BlockAlign align = BlockAlign.start,
    bool divider = false,
    int headingLevel = 0,
    bool indent = false,
  }) =>
      ParagraphBlock(
        [TextInline(text)],
        align: align,
        divider: divider,
        headingLevel: headingLevel,
        indent: indent,
      );
}

/// 插图：`href` 是解析器可解析的资源键（EPUB 为包内路径，其它为相对路径）。
class ImageBlock extends BookBlock {
  const ImageBlock({required this.href, this.alt = ''});

  final String href;
  final String alt;
}

/// 空行（保留原书段落间距）。
class BlankBlock extends BookBlock {
  const BlankBlock();
}

/// 一章内容。
class ChapterBlocks {
  const ChapterBlocks({required this.title, required this.blocks});

  final String title;
  final List<BookBlock> blocks;

  /// 纯文本（段间以 `\n` 分隔，插图占位为空行）。
  String get plainText {
    final buffer = StringBuffer();
    for (final block in blocks) {
      switch (block) {
        case ParagraphBlock():
          final text = block.plainText.trimRight();
          if (text.isEmpty) continue;
          if (buffer.isNotEmpty) buffer.write('\n');
          buffer.write(text);
        case ImageBlock():
          if (buffer.isNotEmpty) buffer.write('\n');
        case BlankBlock():
          if (buffer.isNotEmpty) buffer.write('\n');
      }
    }
    return buffer.toString();
  }

  /// 是否含可渲染的非文本块（插图）。
  bool get hasImages => blocks.any((b) => b is ImageBlock);

  /// 段落下标 → 该段在 [plainText] 中的起始字符偏移（搜索/进度换算用）。
  List<int> paragraphOffsets() {
    final offsets = <int>[];
    var cursor = 0;
    for (final block in blocks) {
      if (block is ParagraphBlock) {
        offsets.add(cursor);
        cursor += block.plainText.length + 1;
      }
    }
    return offsets;
  }
}

/// 便捷：把纯文本行数组转成区块（TXT / MD 简单路径）。
List<BookBlock> blocksFromLines(
  Iterable<String> lines, {
  BlockAlign align = BlockAlign.start,
}) {
  final out = <BookBlock>[];
  for (final line in lines) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    out.add(ParagraphBlock([TextInline(trimmed)], align: align));
  }
  return out;
}
