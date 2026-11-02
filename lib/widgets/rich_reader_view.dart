/// 富文本阅读视图（本地 EPUB/HTML 用）：滚动列表 + 段落分页 + 竖排。
///
/// 设计取舍：
/// - 分页按**段落原子**切：普通段落可在行内断开，含注音/脚注/插图的段落整段不拆
///   （宁可有留白，也不把 ruby 或脚注标记劈成两半）；
/// - 竖排用自绘：CJK 逐字正立、右起竖行、拉丁字符转 90°、行首行末禁则；
/// - 进度/书签仍以**章内字符偏移**为准（`RichChapter.plainText`），与纯文本阅读器一致。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/reader/reader_typography.dart';
import '../core/reader/rich_paragraph.dart';

/// 图片字节取回（EPUB 包内资源）；返回 null 时渲染占位。
typedef RichImageLoader = Future<Uint8List?> Function(String href);

/// 脚注点击回调。
typedef RichNoteTap = void Function(String note);

TextStyle _baseStyle(ReaderTypography typography, Color color, double scale) {
  final size = typography.scaledFontSize(null) * scale;
  return TextStyle(
    color: color,
    fontSize: size,
    fontWeight: typography.fontWeightValue,
    fontStyle: typography.italic ? FontStyle.italic : FontStyle.normal,
    fontFamily: typography.fontFamily,
    letterSpacing: typography.letterSpacing * size,
    height: typography.lineHeight,
    leadingDistribution: TextLeadingDistribution.even,
  );
}

/// 单个段落（含注音/脚注/插图）。
class RichParagraphWidget extends StatefulWidget {
  const RichParagraphWidget({
    super.key,
    required this.paragraph,
    required this.typography,
    required this.color,
    this.onNoteTap,
    this.imageLoader,
    this.scale = 1,
  });

  final RichParagraph paragraph;
  final ReaderTypography typography;
  final Color color;
  final RichNoteTap? onNoteTap;
  final RichImageLoader? imageLoader;
  final double scale;

  @override
  State<RichParagraphWidget> createState() => _RichParagraphWidgetState();
}

class _RichParagraphWidgetState extends State<RichParagraphWidget> {
  final List<TapGestureRecognizerHolder> _recognizers = [];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final paragraph = widget.paragraph;
    final base = _baseStyle(widget.typography, widget.color, widget.scale);

    if (paragraph.spans.length == 1 && paragraph.spans.single.isImage) {
      return _buildImage(paragraph.spans.single.imageHref!, base);
    }

    for (final r in _recognizers) {
      r.recognizer.dispose();
    }
    _recognizers.clear();

    final spans = <InlineSpan>[];
    if (paragraph.isHeading) {
      spans.add(TextSpan(
        text: paragraph.plainText,
        style: base.copyWith(
          fontSize: base.fontSize! + 3,
          fontWeight: FontWeight.w700,
          height: 1.5,
        ),
      ));
    } else {
      for (final span in paragraph.spans) {
        if (span.isImage) {
          spans.add(const WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Icon(Icons.broken_image_outlined, size: 16),
          ));
          continue;
        }
        if (span.isRuby) {
          spans.add(WidgetSpan(
            alignment: PlaceholderAlignment.bottom,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(span.text, style: base),
                Text(
                  span.ruby!,
                  style: base.copyWith(
                    fontSize: (base.fontSize ?? 16) * 0.55,
                    height: 1.0,
                    color: widget.color.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ),
          ));
          continue;
        }
        if (span.isNote) {
          final holder = TapGestureRecognizerHolder();
          holder.recognizer.onTap = () => widget.onNoteTap?.call(span.note!);
          _recognizers.add(holder);
          spans.add(TextSpan(
            text: span.text,
            recognizer: holder.recognizer,
            style: base.copyWith(
              fontSize: (base.fontSize ?? 16) * 0.72,
              color: Theme.of(context).colorScheme.primary,
            ),
          ));
          continue;
        }
        spans.add(TextSpan(
          text: span.text,
          style: base.copyWith(
            fontWeight: span.bold ? FontWeight.w700 : null,
            fontStyle: span.italic ? FontStyle.italic : null,
          ),
        ));
      }
    }

    final text = Text.rich(
      TextSpan(children: spans),
      textAlign: switch (paragraph.align) {
        RichAlign.start => TextAlign.start,
        RichAlign.center => TextAlign.center,
        RichAlign.end => TextAlign.end,
        RichAlign.justify => TextAlign.justify,
      },
      textScaler: TextScaler.noScaling,
    );

    Widget content = paragraph.indent
        ? Padding(
            padding: EdgeInsets.only(left: (base.fontSize ?? 16) * 2),
            child: text,
          )
        : text;

    if (paragraph.divider) {
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Divider(
            height: widget.typography.paragraphSpacing + 12,
            thickness: 1,
            color: widget.color.withValues(alpha: 0.28),
          ),
          content,
        ],
      );
    }
    return content;
  }

  Widget _buildImage(String href, TextStyle base) {
    final loader = widget.imageLoader;
    if (loader == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: FutureBuilder<Uint8List?>(
        future: loader(href),
        builder: (context, snapshot) {
          final bytes = snapshot.data;
          if (bytes == null || bytes.isEmpty) {
            return snapshot.connectionState == ConnectionState.done
                ? Text('[图片] ${_baseName(href)}',
                    style: base.copyWith(
                        fontSize: (base.fontSize ?? 16) * 0.8,
                        color: widget.color.withValues(alpha: 0.5)))
                : const SizedBox(height: 80);
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(bytes, fit: BoxFit.contain),
          );
        },
      ),
    );
  }
}

/// 识别器持有者（State 里统一 dispose）。
class TapGestureRecognizerHolder {
  final TapGestureRecognizer recognizer = TapGestureRecognizer();
}

String _baseName(String path) {
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// 页数回报延到帧后（build 期间不允许父层 setState）。
void _reportPageCount(int count, ValueChanged<int>? callback) {
  if (callback == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => callback(count));
}

/// 滚动模式：整章富文本。
class RichChapterView extends StatelessWidget {
  const RichChapterView({
    super.key,
    required this.chapter,
    required this.typography,
    required this.color,
    this.onNoteTap,
    this.imageLoader,
    this.padding = EdgeInsets.zero,
    this.controller,
    this.onParagraphVisible,
  });

  final RichChapter chapter;
  final ReaderTypography typography;
  final Color color;
  final RichNoteTap? onNoteTap;
  final RichImageLoader? imageLoader;
  final EdgeInsets padding;
  final ScrollController? controller;
  final void Function(int paragraphIndex)? onParagraphVisible;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      controller: controller,
      padding: padding,
      itemCount: chapter.paragraphs.length,
      itemBuilder: (context, i) {
        final p = chapter.paragraphs[i];
        return Padding(
          padding: EdgeInsets.only(
            top: p.isHeading ? 8 : 0,
            bottom: typography.paragraphSpacing,
          ),
          child: RichParagraphWidget(
            paragraph: p,
            typography: typography,
            color: color,
            onNoteTap: onNoteTap,
            imageLoader: imageLoader,
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 分页
// ---------------------------------------------------------------------------

/// 一页（若干段落，普通段落可能被切成前后两半）。
class RichPageData {
  const RichPageData(this.paragraphs);

  final List<RichParagraph> paragraphs;

  String get plainText =>
      paragraphs.map((p) => p.plainText).join('\n');
}

/// 段落分页器：按实际测量高度装页。
class RichPaginator {
  RichPaginator({
    required this.typography,
    required this.width,
    required this.height,
    this.scale = 1,
  });

  final ReaderTypography typography;
  final double width;
  final double height;
  final double scale;

  double get _spacing => typography.paragraphSpacing;

  List<RichPageData> paginate(RichChapter chapter) {
    final pages = <RichPageData>[];
    var current = <RichParagraph>[];
    var used = 0.0;

    void flush() {
      if (current.isEmpty) return;
      pages.add(RichPageData(List.unmodifiable(current)));
      current = <RichParagraph>[];
      used = 0;
    }

    for (final paragraph in chapter.paragraphs) {
      final fullHeight = _measure(paragraph);
      if (fullHeight <= 0) continue;

      final remaining = height - used;
      if (fullHeight <= remaining) {
        current.add(paragraph);
        used += fullHeight + _spacing;
        continue;
      }

      // 富文本段落整段不拆：装不下就换页（超过整页高度时独占一页）。
      if (!paragraph.isPlain) {
        flush();
        current.add(paragraph);
        used = math.min(fullHeight, height) + _spacing;
        if (fullHeight >= height) flush();
        continue;
      }

      // 普通段落：能塞多少塞多少，余量续到下一页。
      var rest = paragraph;
      while (true) {
        final available = height - used;
        if (available < _minLineHeight) {
          flush();
        }
        final fit = _prefixFitting(rest, height - used);
        if (fit <= 0) {
          flush();
          final retry = _prefixFitting(rest, height);
          if (retry <= 0) break; // 单字符都放不下：丢弃防死循环
          final (head, tail) = _split(rest, retry);
          current.add(head);
          used += _measure(head) + _spacing;
          flush();
          rest = tail;
          if (rest.plainText.trim().isEmpty) break;
          continue;
        }
        final (head, tail) = _split(rest, fit);
        current.add(head);
        used += _measure(head) + _spacing;
        if (tail.plainText.trim().isEmpty) break;
        flush();
        rest = tail;
      }
    }
    flush();
    if (pages.isEmpty) pages.add(const RichPageData([]));
    return pages;
  }

  double get _minLineHeight => typography.scaledFontSize(null) * 1.2 * scale;

  double _measure(RichParagraph paragraph) {
    if (paragraph.spans.length == 1 && paragraph.spans.single.isImage) {
      // 插图高度未知：按 4:3 估，渲染时自身高度可能更大（滚动模式无碍）。
      return width * 0.75;
    }
    final painter = TextPainter(
      text: _spanOf(paragraph),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: _availableWidth(paragraph));
    return painter.height;
  }

  double _availableWidth(RichParagraph paragraph) {
    final indent = paragraph.indent
        ? typography.scaledFontSize(null) * 2 * scale
        : 0;
    return math.max(1, width - indent);
  }

  TextSpan _spanOf(RichParagraph paragraph) {
    final base = _baseStyle(typography, const Color(0xFF000000), scale);
    return TextSpan(
      children: [
        for (final span in paragraph.spans)
          TextSpan(
            text: span.isRuby ? '${span.text}（${span.ruby}）' : span.text,
            style: paragraph.isHeading
                ? base.copyWith(fontSize: base.fontSize! + 3)
                : base,
          ),
      ],
    );
  }

  /// 最多能放下多少个字符（普通段落）。
  int _prefixFitting(RichParagraph paragraph, double available) {
    final text = paragraph.plainText;
    if (text.isEmpty) return 0;
    var low = 0;
    var high = text.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (_measureText(paragraph, text.substring(0, mid)) <= available) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low;
  }

  double _measureText(RichParagraph paragraph, String text) {
    if (text.isEmpty) return 0;
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: _baseStyle(typography, const Color(0xFF000000), scale),
      ),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout(maxWidth: _availableWidth(paragraph));
    return painter.height;
  }

  (RichParagraph, RichParagraph) _split(RichParagraph paragraph, int at) {
    final plain = paragraph.plainText;
    final head = plain.substring(0, at);
    final tail = plain.substring(at);
    return (
      RichParagraph(
        spans: [RichSpan.text(head)],
        align: paragraph.align,
        headingLevel: paragraph.headingLevel,
        indent: false,
      ),
      RichParagraph(
        spans: [RichSpan.text(tail)],
        align: paragraph.align,
        headingLevel: paragraph.headingLevel,
        indent: false,
      ),
    );
  }
}

/// 分页阅读视图（横排 / 竖排、单页 / 对页）。
class RichPagedView extends StatelessWidget {
  const RichPagedView({
    super.key,
    required this.chapter,
    required this.typography,
    required this.color,
    required this.backgroundColor,
    required this.pageIndex,
    required this.onPageChanged,
    this.onPageCount,
    this.onNoteTap,
    this.imageLoader,
    this.vertical = false,
    this.doublePage = false,
    this.padding = EdgeInsets.zero,
  });

  final RichChapter chapter;
  final ReaderTypography typography;
  final Color color;
  final Color backgroundColor;
  final int pageIndex;
  final ValueChanged<int> onPageChanged;

  /// 分页完成/页数变化（父层据此算进度）。
  final ValueChanged<int>? onPageCount;
  final RichNoteTap? onNoteTap;
  final RichImageLoader? imageLoader;
  final bool vertical;
  final bool doublePage;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    if (vertical) {
      return _VerticalPagedView(
        chapter: chapter,
        typography: typography,
        color: color,
        pageIndex: pageIndex,
        onPageChanged: onPageChanged,
        onPageCount: onPageCount,
        padding: padding,
        columns: doublePage ? 2 : 1,
      );
    }
    return LayoutBuilder(builder: (context, constraints) {
      final availableWidth =
          math.max(1.0, constraints.maxWidth - padding.horizontal);
      final availableHeight =
          math.max(1.0, constraints.maxHeight - padding.vertical);
      final columns = doublePage && availableWidth > 620 ? 2 : 1;
      final gap = columns == 2 ? 28.0 : 0.0;
      final columnWidth = (availableWidth - gap * (columns - 1)) / columns;
      final paginator = RichPaginator(
        typography: typography,
        width: columnWidth,
        height: availableHeight,
      );
      final columnsData = paginator.paginate(chapter);
      final pages = <List<RichPageData>>[];
      if (columns == 1) {
        for (final c in columnsData) {
          pages.add([c]);
        }
      } else {
        for (var i = 0; i < columnsData.length; i += 2) {
          pages.add([
            columnsData[i],
            if (i + 1 < columnsData.length) columnsData[i + 1],
          ]);
        }
      }
      final current =
          pageIndex.clamp(0, math.max(0, pages.length - 1)).toInt();
      _reportPageCount(pages.length, onPageCount);
      return Padding(
        padding: padding,
        child: PageView.builder(
          reverse: false,
          controller: PageController(initialPage: current),
          onPageChanged: onPageChanged,
          itemCount: pages.length,
          itemBuilder: (context, i) => Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var c = 0; c < columns; c++) ...[
                if (c > 0) SizedBox(width: gap),
                SizedBox(
                  width: columnWidth,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (c < pages[i].length)
                        for (final p in pages[i][c].paragraphs)
                          Padding(
                            padding: EdgeInsets.only(
                              bottom: typography.paragraphSpacing,
                            ),
                            child: RichParagraphWidget(
                              paragraph: p,
                              typography: typography,
                              color: color,
                              onNoteTap: onNoteTap,
                              imageLoader: imageLoader,
                            ),
                          ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    });
  }
}

// ---------------------------------------------------------------------------
// 竖排
// ---------------------------------------------------------------------------

/// 行首禁则（不能出现在行首）。
const String _kNoLineStart = '、。，．！？：；）」』】》〉…‥ー～·」』】';
/// 行末禁则（不能出现在行末）。
const String _kNoLineEnd = '（「『【《〈“‘';

class _VerticalPagedView extends StatefulWidget {
  const _VerticalPagedView({
    required this.chapter,
    required this.typography,
    required this.color,
    required this.pageIndex,
    required this.onPageChanged,
    required this.padding,
    required this.columns,
    this.onPageCount,
  });

  final RichChapter chapter;
  final ReaderTypography typography;
  final Color color;
  final int pageIndex;
  final ValueChanged<int> onPageChanged;
  final EdgeInsets padding;
  final int columns;
  final ValueChanged<int>? onPageCount;

  @override
  State<_VerticalPagedView> createState() => _VerticalPagedViewState();
}

class _VerticalPagedViewState extends State<_VerticalPagedView> {
  PageController? _controller;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: widget.pageIndex);
  }

  @override
  void didUpdateWidget(covariant _VerticalPagedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pageIndex != widget.pageIndex &&
        _controller?.hasClients == true) {
      _controller?.jumpToPage(widget.pageIndex);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.chapter.plainText;
    return LayoutBuilder(builder: (context, constraints) {
      final size = Size(
        math.max(1, constraints.maxWidth - widget.padding.horizontal),
        math.max(1, constraints.maxHeight - widget.padding.vertical),
      );
      final layout = VerticalTextLayout(
        typography: widget.typography,
        size: size,
        columnsPerPage: widget.columns,
      );
      final pages = layout.split(text);
      _reportPageCount(pages.length, widget.onPageCount);
      final current = widget.pageIndex
          .clamp(0, math.max(0, pages.length - 1))
          .toInt();
      if (_controller == null || _controller!.initialPage != current) {
        _controller?.dispose();
        _controller = PageController(initialPage: current);
      }
      return Padding(
        padding: widget.padding,
        child: PageView.builder(
          controller: _controller,
          onPageChanged: widget.onPageChanged,
          itemCount: pages.length,
          itemBuilder: (context, i) => CustomPaint(
            painter: VerticalTextPainter(
              text: pages[i],
              typography: widget.typography,
              color: widget.color,
              columnsPerPage: widget.columns,
            ),
            size: size,
          ),
        ),
      );
    });
  }
}

/// 竖排几何与断页（右起竖行，逐字正立）。
class VerticalTextLayout {
  VerticalTextLayout({
    required this.typography,
    required this.size,
    required this.columnsPerPage,
  });

  final ReaderTypography typography;
  final Size size;
  final int columnsPerPage;

  double get fontSize => typography.scaledFontSize(null);
  double get lineAdvance => fontSize * typography.lineHeight;
  double get columnAdvance => fontSize * 2.0;

  int get rowsPerColumn => math.max(1, (size.height / lineAdvance).floor());
  int get columnCount =>
      math.max(1, (size.width / columnAdvance).floor()).clamp(1, 99).toInt();
  int get charsPerPage => rowsPerColumn * columnCount * columnsPerPage;

  /// 按禁则切页。
  List<String> split(String text) {
    if (text.isEmpty) return const [''];
    final pages = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = math.min(text.length, start + charsPerPage);
      if (end < text.length) {
        // 行首禁则：页首不能是闭标点 → 往前收；行末禁则：页尾不能是开标点 → 往前收。
        while (end > start + 1 && _kNoLineStart.contains(text[end])) {
          end--;
        }
        while (end > start + 1 && _kNoLineEnd.contains(text[end - 1])) {
          end--;
        }
        // 英文单词不从中间断开。
        while (end > start + 1 &&
            _isWordChar(text.codeUnitAt(end - 1)) &&
            _isWordChar(text.codeUnitAt(end))) {
          end--;
        }
      }
      pages.add(text.substring(start, end));
      start = end;
    }
    return pages;
  }

  static bool _isWordChar(int code) =>
      (code >= 0x30 && code <= 0x39) ||
      (code >= 0x41 && code <= 0x5a) ||
      (code >= 0x61 && code <= 0x7a);
}

/// 竖排绘制：右起竖行，CJK 正立，拉丁转 90°。
class VerticalTextPainter extends CustomPainter {
  VerticalTextPainter({
    required this.text,
    required this.typography,
    required this.color,
    required this.columnsPerPage,
  });

  final String text;
  final ReaderTypography typography;
  final Color color;
  final int columnsPerPage;

  @override
  void paint(Canvas canvas, Size size) {
    final layout = VerticalTextLayout(
      typography: typography,
      size: size,
      columnsPerPage: columnsPerPage,
    );
    final fontSize = layout.fontSize;
    final lineAdvance = layout.lineAdvance;
    final columnAdvance = layout.columnAdvance;
    final rows = layout.rowsPerColumn;
    final style = TextStyle(
      color: color,
      fontSize: fontSize,
      fontFamily: typography.fontFamily,
      fontWeight: typography.fontWeightValue,
      height: 1.0,
    );

    var index = 0;
    for (var page = 0; page < columnsPerPage; page++) {
      for (var col = 0; col < layout.columnCount; col++) {
        for (var row = 0; row < rows; row++) {
          if (index >= text.length) return;
          final char = text[index];
          index++;
          if (char == '\n' || char == ' ') continue;
          final left = size.width -
              (page * layout.columnCount + col + 1) * columnAdvance +
              fontSize * 0.25;
          final top = row * lineAdvance;
          _paintChar(canvas, char, Offset(left, top), style, fontSize);
        }
      }
    }
  }

  void _paintChar(
    Canvas canvas,
    String char,
    Offset topLeft,
    TextStyle style,
    double fontSize,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: char, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.noScaling,
    )..layout();
    final code = char.codeUnitAt(0);
    final isLatin = code < 0x2E80;
    if (isLatin) {
      // 拉丁/数字：绕字符中心转 90°（自上而下阅读）。
      canvas.save();
      canvas.translate(
        topLeft.dx + fontSize * 0.5,
        topLeft.dy + fontSize * 0.5,
      );
      canvas.rotate(math.pi / 2);
      painter.paint(
        canvas,
        Offset(-painter.width / 2, -painter.height / 2),
      );
      canvas.restore();
      return;
    }
    painter.paint(canvas, topLeft);
  }

  @override
  bool shouldRepaint(covariant VerticalTextPainter oldDelegate) =>
      oldDelegate.text != text ||
      oldDelegate.color != color ||
      oldDelegate.typography != typography ||
      oldDelegate.columnsPerPage != columnsPerPage;
}
