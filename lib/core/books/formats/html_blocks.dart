/// HTML/XHTML → [BookBlock] 的**共享构建器**（EPUB / HTML / Markdown 三条解析链共用）。
///
/// 规则：
/// - 块级标签（p/div/li/blockquote/h1-6/td…）切段；行内样式转 [TextInline] 标志位；
/// - `<ruby>` → [RubyInline]（基字 + 注音）；`<br>` → [BreakInline]；
/// - `<img>` → [ImageBlock]（href 按文档目录补全为包内路径/相对路径）；
/// - `<hr>` / CSS `border-*` → [ParagraphBlock.divider]；
/// - 脚注：同文档内的 `aside` / `epub:type=footnote|endnote|rearnote` / `.footnote`
///   → [NoteInline]（点击弹窗）；
/// - CSS 只取白名单属性（text-align / text-indent / font-weight / font-style / border-*）。
library;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'book_block.dart';

/// 收集同文档内脚注：id → 纯文本。
Map<String, String> collectHtmlNotes(dom.Document doc) {
  final notes = <String, String>{};
  for (final el in doc.querySelectorAll(
      'aside, [epub\\:type], [type], [role], .footnote, .note, .endnote')) {
    final type = (el.attributes['epub:type'] ??
            el.attributes['type'] ??
            el.attributes['role'] ??
            '')
        .toLowerCase();
    final className = (el.attributes['class'] ?? '').toLowerCase();
    final looksLikeNote = type.contains('footnote') ||
        type.contains('endnote') ||
        type.contains('rearnote') ||
        type.contains('doc-footnote') ||
        className.contains('footnote') ||
        className.contains('endnote') ||
        className.contains('note');
    if (!looksLikeNote) continue;
    final id = el.id;
    final text = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (id.isEmpty || text.isEmpty) continue;
    notes[id] = text;
  }
  return notes;
}

/// 把 HTML 片段转成区块。
List<BookBlock> buildHtmlBlocks(
  dom.Element? root, {
  String basePath = '',
  Map<String, String> notes = const <String, String>{},
  String css = '',
}) {
  if (root == null) return const <BookBlock>[];
  return HtmlBlockBuilder(
    basePath: basePath,
    notes: notes,
    css: HtmlCssHints.parse(css),
  ).build(root);
}

/// 便捷：整篇 HTML 文本 → 区块（自动取 body）。
List<BookBlock> buildHtmlBlocksFromText(
  String html, {
  String basePath = '',
  Map<String, String> notes = const <String, String>{},
}) {
  final doc = html_parser.parse(html);
  return buildHtmlBlocks(
    doc.body,
    basePath: basePath,
    notes: {...collectHtmlNotes(doc), ...notes},
    css: _stylesOf(doc),
  );
}

/// 汇总文档内 `<style>` 文本（供 CSS 白名单解析）。
String htmlStylesOf(dom.Document doc) => _stylesOf(doc);

String _stylesOf(dom.Document doc) {
  final buffer = StringBuffer();
  for (final style in doc.querySelectorAll('style')) {
    buffer.writeln(style.text);
  }
  return buffer.toString();
}

class HtmlBlockBuilder {
  HtmlBlockBuilder({
    required this.basePath,
    required this.notes,
    required this.css,
  });

  final String basePath;
  final Map<String, String> notes;
  final HtmlCssHints css;

  final List<BookBlock> out = [];
  final List<BookInline> _run = [];

  int _heading = 0;
  BlockAlign _align = BlockAlign.start;
  bool _indent = false;
  bool _divider = false;

  List<BookBlock> build(dom.Element root) {
    for (final node in root.nodes) {
      _walk(node, bold: false, italic: false, superscript: false);
    }
    _flush();
    return out;
  }

  void _walk(
    dom.Node node, {
    required bool bold,
    required bool italic,
    required bool superscript,
  }) {
    if (node is dom.Text) {
      final text = node.text.replaceAll('\u00A0', ' ');
      if (text.trim().isEmpty) {
        if (_run.isNotEmpty && text.isNotEmpty) {
          _addText(' ', bold, italic, superscript);
        }
        return;
      }
      _addText(collapseWhitespace(text), bold, italic, superscript);
      return;
    }
    if (node is! dom.Element) return;

    final tag = node.localName ?? '';
    switch (tag) {
      case 'script':
      case 'style':
      case 'head':
      case 'noscript':
      case 'svg':
        return;
      case 'br':
        _run.add(const BreakInline());
        return;
      case 'img':
        _flush();
        final src = node.attributes['src'] ?? '';
        if (src.isNotEmpty) {
          out.add(ImageBlock(
            href: _resolveAsset(src),
            alt: node.attributes['alt'] ?? '',
          ));
        }
        return;
      case 'hr':
        _flush();
        _divider = true;
        return;
      case 'ruby':
        _addRuby(node);
        return;
      case 'rt':
      case 'rp':
        return;
      case 'sup':
        _walkChildren(node, bold, italic, true);
        return;
      case 'b':
      case 'strong':
        _walkChildren(node, true, italic, superscript);
        return;
      case 'i':
      case 'em':
        _walkChildren(node, bold, true, superscript);
        return;
      case 'a':
        _handleAnchor(node, bold, italic, superscript);
        return;
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        _flush();
        _heading = int.parse(tag.substring(1));
        _applyHints(node);
        _walkChildren(node, bold, italic, superscript);
        _flush();
        _heading = 0;
        return;
      case 'p':
      case 'div':
      case 'section':
      case 'article':
      case 'blockquote':
      case 'li':
      case 'dd':
      case 'dt':
      case 'pre':
      case 'figcaption':
      case 'td':
      case 'th':
        _flush();
        _applyHints(node);
        _walkChildren(node, bold, italic, superscript);
        _flush();
        return;
      default:
        _walkChildren(node, bold, italic, superscript);
    }
  }

  void _walkChildren(dom.Element el, bool bold, bool italic, bool superscript) {
    for (final child in el.nodes) {
      _walk(child, bold: bold, italic: italic, superscript: superscript);
    }
  }

  void _handleAnchor(
    dom.Element el,
    bool bold,
    bool italic,
    bool superscript,
  ) {
    final href = el.attributes['href'] ?? '';
    final type = (el.attributes['epub:type'] ?? el.attributes['type'] ?? '')
        .toLowerCase();
    final label = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final isNoteRef = type.contains('noteref') ||
        type.contains('doc-noteref') ||
        (el.attributes['role'] ?? '').contains('doc-noteref');

    if (href.startsWith('#') || isNoteRef) {
      final id = href.startsWith('#') ? href.substring(1) : el.id;
      final note = notes[id] ?? '';
      if (note.isNotEmpty) {
        _run.add(NoteInline(
          label: label.isEmpty ? '[注]' : label,
          note: note,
        ));
        return;
      }
    }
    _walkChildren(el, bold, italic, superscript);
  }

  void _addRuby(dom.Element el) {
    final base = StringBuffer();
    var ruby = '';
    for (final child in el.nodes) {
      if (child is dom.Element) {
        if (child.localName == 'rt') {
          ruby = child.text.trim();
          continue;
        }
        if (child.localName == 'rp') continue;
        base.write(child.text);
      } else if (child is dom.Text) {
        base.write(child.text);
      }
    }
    final text = collapseWhitespace(base.toString());
    if (text.trim().isEmpty) return;
    if (ruby.isEmpty) {
      _addText(text, false, false, false);
      return;
    }
    _run.add(RubyInline(text, ruby));
  }

  void _addText(String text, bool bold, bool italic, bool superscript) {
    if (text.isEmpty) return;
    _run.add(TextInline(
      text,
      bold: bold,
      italic: italic,
      superscript: superscript,
    ));
  }

  void _applyHints(dom.Element el) {
    final hint = css.hintFor(el);
    _align = hint.align ?? BlockAlign.start;
    _indent = hint.indent;
    _divider = _divider || hint.divider;
  }

  void _flush() {
    if (_run.isEmpty) {
      return;
    }
    final inlines = List<BookInline>.from(_run);
    _run.clear();
    final text = inlines.map((i) => i.plain).join();
    if (text.trim().isEmpty && !inlines.any((i) => i is BreakInline)) {
      _resetParagraphState();
      return;
    }
    out.add(ParagraphBlock(
      inlines,
      align: _align,
      headingLevel: _heading,
      indent: _indent,
      divider: _divider && _heading == 0,
    ));
    _resetParagraphState();
  }

  void _resetParagraphState() {
    _align = BlockAlign.start;
    _indent = false;
    _divider = false;
  }

  String _resolveAsset(String href) {
    if (href.isEmpty) return href;
    final uri = Uri.tryParse(href);
    if (uri != null && uri.hasScheme) return href;
    return joinArchivePath(dirOfPath(basePath), href);
  }
}

/// CSS 白名单提示。
class CssParagraphHint {
  const CssParagraphHint({
    this.align,
    this.indent = false,
    this.divider = false,
  });

  final BlockAlign? align;
  final bool indent;
  final bool divider;
}

class HtmlCssHints {
  const HtmlCssHints(this._rules);

  static const HtmlCssHints empty = HtmlCssHints({});

  /// selector（`.cls` / `tag`）→ 提示。
  final Map<String, CssParagraphHint> _rules;

  static HtmlCssHints parse(String css) {
    if (css.trim().isEmpty) return empty;
    return HtmlCssHints(_parseRules(css));
  }

  static Map<String, CssParagraphHint> _parseRules(String css) {
    final rules = <String, CssParagraphHint>{};
    final blockPattern = RegExp(r'([^{}]+)\{([^{}]*)\}');
    for (final match in blockPattern.allMatches(css)) {
      final selectors = match.group(1) ?? '';
      final body = match.group(2) ?? '';
      final hint = _hintFromBody(body);
      if (hint == null) continue;
      for (final raw in selectors.split(',')) {
        final selector = raw.trim();
        if (selector.isEmpty || selector.contains(' ')) continue;
        if (selector.contains('>') ||
            selector.contains(':') ||
            selector.contains('[')) {
          continue;
        }
        rules[selector] = hint;
      }
    }
    return rules;
  }

  static CssParagraphHint? _hintFromBody(String body) {
    BlockAlign? align;
    var indent = false;
    var divider = false;
    var touched = false;

    for (final decl in body.split(';')) {
      final colon = decl.indexOf(':');
      if (colon <= 0) continue;
      final prop = decl.substring(0, colon).trim().toLowerCase();
      final value = decl.substring(colon + 1).trim().toLowerCase();
      if (value.isEmpty) continue;
      switch (prop) {
        case 'text-align':
          align = switch (value) {
            'center' => BlockAlign.center,
            'right' || 'end' => BlockAlign.end,
            'justify' => BlockAlign.justify,
            _ => BlockAlign.start,
          };
          touched = true;
        case 'text-indent':
          final amount = double.tryParse(
                RegExp(r'-?[\d.]+').firstMatch(value)?.group(0) ?? '',
              ) ??
              0;
          indent = amount > 0;
          touched = true;
        case 'border-top':
        case 'border-bottom':
          divider = value.contains('solid') ||
              value.contains('dashed') ||
              value.contains('dotted');
          touched = true;
      }
    }
    if (!touched) return null;
    return CssParagraphHint(align: align, indent: indent, divider: divider);
  }

  CssParagraphHint hintFor(dom.Element el) {
    if (_rules.isEmpty) {
      return const CssParagraphHint();
    }
    final tag = el.localName ?? '';
    final classes = (el.attributes['class'] ?? '')
        .split(RegExp(r'\s+'))
        .where((c) => c.isNotEmpty);

    BlockAlign? align;
    var indent = false;
    var divider = false;
    for (final cls in classes) {
      final hint = _rules['.$cls'];
      if (hint == null) continue;
      align ??= hint.align;
      indent = indent || hint.indent;
      divider = divider || hint.divider;
    }
    final tagHint = _rules[tag];
    if (tagHint != null) {
      align ??= tagHint.align;
      indent = indent || tagHint.indent;
      divider = divider || tagHint.divider;
    }
    return CssParagraphHint(align: align, indent: indent, divider: divider);
  }
}

// ---------------------------------------------------------------------------
// 路径 / 文本小工具（EPUB/ZIP 包内路径）
// ---------------------------------------------------------------------------

String collapseWhitespace(String text) =>
    text.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');

/// 规范化包内路径：去掉 `.`、折叠 `..`、统一 `/`。
String normalizeArchivePath(String path) {
  final parts = <String>[];
  for (final raw in path.replaceAll('\\', '/').split('/')) {
    if (raw.isEmpty || raw == '.') continue;
    if (raw == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(raw);
  }
  return parts.join('/');
}

String dirOfPath(String path) {
  final index = path.lastIndexOf('/');
  return index < 0 ? '' : path.substring(0, index);
}

String stripFragment(String path) {
  final hash = path.indexOf('#');
  final query = path.indexOf('?');
  var end = path.length;
  if (hash >= 0) end = hash;
  if (query >= 0 && query < end) end = query;
  return path.substring(0, end);
}

/// 把相对 href 解析成包内绝对路径。
String joinArchivePath(String dir, String href) {
  final clean = stripFragment(href);
  if (clean.isEmpty) return stripFragment(href);
  if (dir.isEmpty) return normalizeArchivePath(clean);
  return normalizeArchivePath('$dir/$clean');
}

String mimeOfPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  if (lower.endsWith('.bmp')) return 'image/bmp';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  return '';
}
