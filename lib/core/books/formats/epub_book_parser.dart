/// EPUB 解析（纯 Dart：`archive` + `xml` + `html`）。
///
/// 支持：`container.xml` → OPF → `manifest`/`spine`；目录优先 `nav`（EPUB3），
/// 退化 `navMap`（NCX）；`ruby/rt` 注音；脚注链接（同文档内 `aside`/`epub:type`）；
/// 章内插图；CSS 白名单。区块构建与 CSS 规则见 `html_blocks.dart`（与 HTML/MD 共用）。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import 'book_format_parser.dart';
import 'format_limits.dart';
import 'html_blocks.dart';

class EpubBookParser extends BookFormatParser {
  const EpubBookParser();

  @override
  String get id => 'epub';

  @override
  Set<String> get extensions => const {'epub'};

  @override
  String get displayName => 'EPUB';

  @override
  Future<ParsedBook> parse(BookFileRef ref) async {
    final bytes = await ref.readBytes();
    if (bytes.length > kArchiveByteLimit) {
      throw const BookFormatException('EPUB 超过 512MB，已拒绝导入');
    }
    return parseEpubBytes(bytes, fallbackTitle: baseNameOfFile(ref.fileName));
  }
}

/// 直接从字节解析（导入与测试共用）。
ParsedBook parseEpubBytes(
  Uint8List bytes, {
  required String fallbackTitle,
}) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (e) {
    throw BookFormatException('EPUB 压缩包损坏：$e');
  }
  final entries = _EntryIndex(archive);
  final containerXml = entries.readText('META-INF/container.xml');
  if (containerXml == null) {
    throw const BookFormatException('不是有效的 EPUB：缺少 META-INF/container.xml');
  }
  final opfPath = _rootfilePath(containerXml);
  if (opfPath == null) {
    throw const BookFormatException('EPUB container 缺少 rootfile');
  }
  final opfText = entries.readText(opfPath);
  if (opfText == null) {
    throw BookFormatException('EPUB 缺少 OPF：$opfPath');
  }

  final opfDir = dirOfPath(opfPath);
  final opf = _OpfDocument.parse(opfText);

  // 目录：nav 优先，其次 NCX。
  final tocTitles = <String, String>{};
  final navHref = opf.navHref;
  if (navHref != null) {
    final navPath = joinArchivePath(opfDir, navHref);
    final navText = entries.readText(navPath);
    if (navText != null) tocTitles.addAll(_titlesFromNav(navText, navPath));
  }
  if (tocTitles.isEmpty && opf.ncxHref != null) {
    final ncxPath = joinArchivePath(opfDir, opf.ncxHref!);
    final ncxText = entries.readText(ncxPath);
    if (ncxText != null) tocTitles.addAll(_titlesFromNcx(ncxText, ncxPath));
  }

  final chapters = <ParsedChapter>[];
  var docIndex = 0;
  for (final idref in opf.spine) {
    final item = opf.manifest[idref];
    if (item == null) continue;
    final path = joinArchivePath(opfDir, item.href);
    final html = entries.readText(path);
    if (html == null) continue;
    docIndex++;

    final parsedDoc = html_parser.parse(html);
    final notes = collectHtmlNotes(parsedDoc);
    final blocks = buildHtmlBlocks(
      parsedDoc.body,
      basePath: path,
      notes: notes,
      css: htmlStylesOf(parsedDoc),
    );
    if (blocks.isEmpty) continue;

    final tocTitle = tocTitles[stripFragment(path)]?.trim() ?? '';
    final headingTitle = _firstHeading(parsedDoc);
    final title = tocTitle.isNotEmpty
        ? tocTitle
        : (headingTitle.isNotEmpty ? headingTitle : '第 $docIndex 节');

    chapters.add(ParsedChapter(title: title, blocks: blocks, href: path));
    if (chapters.length >= kMaxChapters) break;
  }

  if (chapters.isEmpty) {
    throw const BookFormatException('EPUB 没有可读章节（spine 为空或内容解析失败）');
  }

  final title = opf.title.trim().isNotEmpty
      ? opf.title.trim()
      : (tocTitles.values.isEmpty ? fallbackTitle : tocTitles.values.first);

  return ParsedBook(
    title: title,
    author: opf.creator,
    intro: opf.description,
    formatId: 'epub',
    chapters: chapters,
    coverBytes: opf.coverHref == null
        ? null
        : entries.readBytes(joinArchivePath(opfDir, opf.coverHref!)),
    resources: _EpubResources(entries),
  );
}

// ---------------------------------------------------------------------------
// container / OPF
// ---------------------------------------------------------------------------

String? _rootfilePath(String containerXml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(containerXml);
  } catch (e) {
    throw BookFormatException('EPUB container.xml 解析失败：$e');
  }
  for (final el in doc.descendants.whereType<XmlElement>()) {
    if (el.name.local != 'rootfile') continue;
    final path = el.getAttribute('full-path');
    if (path != null && path.trim().isNotEmpty) {
      return normalizeArchivePath(path.trim());
    }
  }
  return null;
}

class _ManifestItem {
  const _ManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    required this.properties,
  });

  final String id;
  final String href;
  final String mediaType;
  final String properties;

  bool get isNav => properties.split(RegExp(r'\s+')).contains('nav');

  bool get isCoverImage =>
      properties.split(RegExp(r'\s+')).contains('cover-image');
}

class _OpfDocument {
  _OpfDocument({
    required this.title,
    required this.creator,
    required this.description,
    required this.manifest,
    required this.spine,
    required this.navHref,
    required this.ncxHref,
    required this.coverHref,
  });

  final String title;
  final String creator;
  final String description;
  final Map<String, _ManifestItem> manifest;
  final List<String> spine;
  final String? navHref;
  final String? ncxHref;
  final String? coverHref;

  static _OpfDocument parse(String text) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(text);
    } catch (e) {
      throw BookFormatException('EPUB OPF 解析失败：$e');
    }
    final elements = doc.descendants.whereType<XmlElement>().toList();

    String meta(String local) {
      for (final el in elements) {
        if (el.name.local == local) return el.innerText.trim();
      }
      return '';
    }

    final manifest = <String, _ManifestItem>{};
    for (final el in elements) {
      if (el.name.local != 'item') continue;
      final id = el.getAttribute('id') ?? '';
      final href = el.getAttribute('href') ?? '';
      if (id.isEmpty || href.isEmpty) continue;
      manifest[id] = _ManifestItem(
        id: id,
        href: href,
        mediaType: el.getAttribute('media-type') ?? '',
        properties: el.getAttribute('properties') ?? '',
      );
    }

    final spine = <String>[];
    String? ncxId;
    for (final el in elements) {
      if (el.name.local == 'spine') ncxId ??= el.getAttribute('toc');
      if (el.name.local == 'itemref') {
        final idref = el.getAttribute('idref');
        if (idref != null && idref.isNotEmpty) spine.add(idref);
      }
    }

    String? navHref;
    String? coverId;
    for (final item in manifest.values) {
      if (item.isNav) navHref ??= item.href;
      if (item.isCoverImage) coverId ??= item.id;
    }
    for (final el in elements) {
      if (el.name.local != 'meta') continue;
      if ((el.getAttribute('name') ?? '') != 'cover') continue;
      final content = el.getAttribute('content');
      if (content != null && content.isNotEmpty) coverId ??= content;
    }
    coverId ??= _guessCoverId(manifest);

    return _OpfDocument(
      title: meta('title'),
      creator: meta('creator'),
      description: meta('description'),
      manifest: manifest,
      spine: spine,
      navHref: navHref,
      ncxHref: ncxId == null ? null : manifest[ncxId]?.href,
      coverHref: coverId == null ? null : manifest[coverId]?.href,
    );
  }

  static String? _guessCoverId(Map<String, _ManifestItem> manifest) {
    for (final item in manifest.values) {
      if (!item.mediaType.startsWith('image/')) continue;
      if (item.href.toLowerCase().contains('cover')) return item.id;
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// 目录（nav / ncx）
// ---------------------------------------------------------------------------

Map<String, String> _titlesFromNav(String html, String docPath) {
  final out = <String, String>{};
  final doc = html_parser.parse(html);
  dom.Element? toc;
  for (final nav in doc.querySelectorAll('nav')) {
    final type = nav.attributes['epub:type'] ?? nav.attributes['type'] ?? '';
    if (type.contains('toc')) {
      toc = nav;
      break;
    }
  }
  final scope = toc ?? doc.body;
  if (scope == null) return out;
  for (final a in scope.querySelectorAll('a')) {
    final href = a.attributes['href'] ?? '';
    final title = a.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (href.isEmpty || title.isEmpty) continue;
    final key = stripFragment(joinArchivePath(dirOfPath(docPath), href));
    out.putIfAbsent(key, () => title);
  }
  return out;
}

Map<String, String> _titlesFromNcx(String xml, String docPath) {
  final out = <String, String>{};
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } catch (_) {
    return out;
  }
  for (final point in doc.descendants.whereType<XmlElement>()) {
    if (point.name.local != 'navPoint') continue;
    String label = '';
    String src = '';
    for (final child in point.descendants.whereType<XmlElement>()) {
      if (child.name.local == 'text' && label.isEmpty) {
        label = child.innerText.trim();
      }
      if (child.name.local == 'content' && src.isEmpty) {
        src = child.getAttribute('src') ?? '';
      }
    }
    if (label.isEmpty || src.isEmpty) continue;
    final key = stripFragment(joinArchivePath(dirOfPath(docPath), src));
    out.putIfAbsent(key, () => label);
  }
  return out;
}

String _firstHeading(dom.Document doc) {
  for (final tag in ['h1', 'h2', 'h3']) {
    final el = doc.querySelector(tag);
    if (el == null) continue;
    final text = el.text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isNotEmpty) return text;
  }
  final title = doc.querySelector('title');
  if (title != null) {
    return title.text.replaceFirst(RegExp(r'\s*[-_].*$'), '').trim();
  }
  return '';
}

// ---------------------------------------------------------------------------
// 资源与包内路径
// ---------------------------------------------------------------------------

class _EpubResources implements BookResourceResolver {
  _EpubResources(this._entries);

  final _EntryIndex _entries;
  final Map<String, Uint8List> _cache = {};
  int _cachedBytes = 0;

  static const int _cacheLimit = 32 * 1024 * 1024;

  @override
  Future<Uint8List?> resolve(String href) async {
    final cached = _cache[href];
    if (cached != null) return cached;
    final bytes = _entries.readBytes(href);
    if (bytes == null) return null;
    if (_cachedBytes + bytes.length <= _cacheLimit) {
      _cache[href] = bytes;
      _cachedBytes += bytes.length;
    }
    return bytes;
  }

  @override
  String mimeOf(String href) => mimeOfPath(href);
}

class _EntryIndex {
  _EntryIndex(Archive archive) {
    var total = 0;
    for (final file in archive.files) {
      if (!file.isFile) continue;
      // zip-slip：原始名带 `..` 或绝对路径的条目丢弃。
      final rawName = file.name.replaceAll('\\', '/');
      if (rawName.startsWith('/') || rawName.split('/').contains('..')) {
        continue;
      }
      final name = normalizeArchivePath(file.name);
      if (name.isEmpty) continue;
      total += file.size;
      if (total > kUnzipTotalByteLimit) {
        throw const BookFormatException('EPUB 解压后超过 1GB，已拒绝（疑似压缩炸弹）');
      }
      _byPath[name] = file;
      _byLower[name.toLowerCase()] = file;
    }
  }

  final Map<String, ArchiveFile> _byPath = {};
  final Map<String, ArchiveFile> _byLower = {};

  ArchiveFile? _file(String path) =>
      _byPath[path] ?? _byLower[path.toLowerCase()];

  Uint8List? readBytes(String path) {
    final file = _file(normalizeArchivePath(path));
    if (file == null) return null;
    try {
      return file.content;
    } catch (_) {
      return null;
    }
  }

  String? readText(String path) {
    final bytes = readBytes(path);
    if (bytes == null) return null;
    if (bytes.length > kMarkupByteLimit) return null;
    var text = _decodeUtf8(bytes);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }
}

String _decodeUtf8(Uint8List bytes) {
  try {
    return const Utf8Decoder().convert(bytes);
  } on FormatException {
    return const Utf8Decoder(allowMalformed: true).convert(bytes);
  }
}
