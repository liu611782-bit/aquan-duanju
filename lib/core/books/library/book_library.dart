/// 本地书库：**导入即复制进应用目录**、sha256 去重、按需解析、旧数据迁移。
///
/// 目录结构（`<appSupport>/book_library/`）：
/// ```
/// <id>/book.<ext>     原始文件副本（删原文件不影响）
/// <id>/cover.jpg      封面（解析得到时写）
/// <id>/meta.json      索引元数据（与 prefs 索引同源，便于手工排查）
/// ```
/// `id = sha256(文件字节) 前 16 位` —— 同内容重复导入天然去重。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../formats/book_block.dart';
import '../formats/book_format_parser.dart';
import '../formats/default_registry.dart';

/// 本地书索引条目（持久化到 prefs `localBooks.v2` + `<id>/meta.json`）。
class LocalBookEntry {
  const LocalBookEntry({
    required this.id,
    required this.title,
    required this.relativePath,
    required this.format,
    required this.chapterTitles,
    required this.charCounts,
    this.author = '',
    this.intro = '',
    this.coverPath = '',
    this.sourcePath = '',
    this.sizeBytes = 0,
    this.importedAt = '',
  });

  factory LocalBookEntry.fromJson(Map<String, dynamic> j) => LocalBookEntry(
        id: j['id']?.toString() ?? '',
        title: j['title']?.toString() ?? '',
        relativePath: j['relativePath']?.toString() ??
            // v1 兼容字段名（旧数据迁移时读 path）。
            j['path']?.toString() ??
            '',
        format: j['format']?.toString() ?? 'txt',
        author: j['author']?.toString() ?? '',
        intro: j['intro']?.toString() ?? '',
        coverPath: j['coverPath']?.toString() ?? '',
        sourcePath: j['sourcePath']?.toString() ?? '',
        sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
        importedAt: j['importedAt']?.toString() ?? '',
        chapterTitles: [
          for (final t in (j['chapterTitles'] as List? ?? const []))
            t.toString(),
        ],
        charCounts: [
          for (final t in (j['charCounts'] as List? ?? const []))
            (t as num).toInt(),
        ],
      );

  final String id;
  final String title;
  final String author;
  final String intro;

  /// 书库内相对路径（`<id>/book.epub`）。
  final String relativePath;

  /// parser id：txt / epub / html / markdown / zip。
  final String format;

  final String coverPath;
  final String sourcePath;
  final int sizeBytes;
  final String importedAt;
  final List<String> chapterTitles;
  final List<int> charCounts;

  int get chapterCount => chapterTitles.length;

  int get totalChars => charCounts.fold(0, (a, b) => a + b);

  bool get hasCover => coverPath.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'intro': intro,
        'relativePath': relativePath,
        'format': format,
        'coverPath': coverPath,
        'sourcePath': sourcePath,
        'sizeBytes': sizeBytes,
        'importedAt': importedAt,
        'chapterTitles': chapterTitles,
        'charCounts': charCounts,
      };

  LocalBookEntry copyWith({String? coverPath, String? title, String? author}) =>
      LocalBookEntry(
        id: id,
        title: title ?? this.title,
        author: author ?? this.author,
        intro: intro,
        relativePath: relativePath,
        format: format,
        coverPath: coverPath ?? this.coverPath,
        sourcePath: sourcePath,
        sizeBytes: sizeBytes,
        importedAt: importedAt,
        chapterTitles: chapterTitles,
        charCounts: charCounts,
      );

  /// 虚拟 BookSource（本地书域）。
  dynamic get sourceUrl => 'localbook://$id';
}

/// 单本导入结果（失败也返回对象，UI 逐条展示原因）。
class LocalBookImportResult {
  const LocalBookImportResult({
    required this.sourcePath,
    this.entry,
    this.error = '',
    this.duplicated = false,
  });

  final String sourcePath;
  final LocalBookEntry? entry;
  final String error;

  /// 同内容已存在（去重命中），entry 是已有条目。
  final bool duplicated;

  bool get ok => entry != null;
}

/// 解析完成的本地书文档（带章节访问与资源读取）。
class LocalBookDocument {
  LocalBookDocument({
    required this.entry,
    required this.book,
    required this.root,
  });

  final LocalBookEntry entry;
  final ParsedBook book;
  final Directory root;

  int get chapterCount => book.chapters.length;

  ChapterBlocks chapterAt(int index) {
    if (index < 0 || index >= book.chapters.length) {
      throw RangeError.index(index, book.chapters, 'index');
    }
    return book.chapters[index].toBlocks();
  }

  ParsedChapter parsedAt(int index) => book.chapters[index];

  Future<List<int>?> resource(String href) => book.resources.resolve(href);

  File? get coverFile {
    if (!entry.hasCover) return null;
    final file = File('${root.path}/${entry.coverPath}');
    return file.existsSync() ? file : null;
  }

  File get bookFile => File('${root.path}/${entry.relativePath}');
}

/// 书库门面。
class BookLibrary {
  BookLibrary({
    required this.root,
    BookFormatParserRegistry? registry,
    this.prefs,
  }) : registry = registry ?? standardBookFormatRegistry();

  /// 默认书库：`<appSupport>/book_library`。
  static Future<BookLibrary> openDefault({
    BookFormatParserRegistry? registry,
    SharedPreferences? prefs,
  }) async {
    final support = await getApplicationSupportDirectory();
    return BookLibrary(
      root: Directory('${support.path}/book_library'),
      registry: registry,
      prefs: prefs,
    );
  }

  /// 书库根目录（`<appSupport>/book_library`）。
  final Directory root;
  final BookFormatParserRegistry registry;

  SharedPreferences? prefs;

  static const String prefsKey = 'localBooks.v2';
  static const String legacyPrefsKey = 'localBooks';

  final Map<String, LocalBookEntry> _entries = <String, LocalBookEntry>{};
  bool _loaded = false;

  /// 最近的 3 本文档（章节全量常驻内存，限制驻留本数）。
  final Map<String, LocalBookDocument> _documents = <String, LocalBookDocument>{};
  static const int _documentCacheLimit = 3;

  Map<String, LocalBookEntry> get entries => Map.unmodifiable(_entries);

  Future<SharedPreferences> get _prefsAsync async =>
      prefs ??= await SharedPreferences.getInstance();

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    if (!root.existsSync()) await root.create(recursive: true);
    final prefs = await _prefsAsync;
    _entries.clear();
    final raw = prefs.getString(prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is! Map<String, dynamic>) continue;
            final entry = LocalBookEntry.fromJson(item);
            if (entry.id.isEmpty) continue;
            _entries[entry.id] = entry;
          }
        }
      } catch (_) {
        // 坏索引按空表处理，稍后由磁盘 meta.json 兜底重建。
      }
    }
    if (_entries.isEmpty) {
      await _rebuildFromDisk();
    }
    // 先置位再迁移：迁移内部会调 importPath → ensureLoaded，否则无限递归。
    _loaded = true;
    await _migrateLegacy(prefs);
  }

  /// 磁盘上的 `meta.json` 重建索引（索引文件坏/被删时自愈）。
  Future<void> _rebuildFromDisk() async {
    if (!root.existsSync()) return;
    for (final dir in root.listSync().whereType<Directory>()) {
      final meta = File('${dir.path}/meta.json');
      if (!meta.existsSync()) continue;
      try {
        final json = jsonDecode(await meta.readAsString());
        if (json is! Map<String, dynamic>) continue;
        final entry = LocalBookEntry.fromJson(json);
        if (entry.id.isEmpty) continue;
        _entries[entry.id] = entry;
      } catch (_) {
        // 单条坏数据跳过。
      }
    }
  }

  /// v1（`prefs.localBooks`，指向外部文件）→ 复制入库。
  Future<void> _migrateLegacy(SharedPreferences prefs) async {
    final raw = prefs.getString(legacyPrefsKey);
    if (raw == null || raw.isEmpty) return;
    final List<dynamic> list;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      list = decoded;
    } catch (_) {
      return;
    }
    var migrated = false;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final path = item['path']?.toString() ?? '';
      if (path.isEmpty) continue;
      // 已迁移过（同 id 已存在）就跳过。
      final existingId = item['id']?.toString() ?? '';
      if (existingId.isNotEmpty && _entries.containsKey(existingId)) continue;
      final result = await importPath(path);
      if (result.ok) migrated = true;
    }
    if (migrated) await _persist();
  }

  /// 导入单个文件（复制入库 + 解析建索引）。
  Future<LocalBookImportResult> importPath(String sourcePath) async {
    await ensureLoaded();
    final source = File(sourcePath);
    if (!source.existsSync()) {
      return LocalBookImportResult(sourcePath: sourcePath, error: '文件不存在');
    }
    final fileName = sourcePath.replaceAll('\\', '/').split('/').last;
    BookFormatParser parser;
    try {
      parser = registry.resolve(fileName);
    } on UnsupportedBookFormat catch (e) {
      return LocalBookImportResult(sourcePath: sourcePath, error: '$e');
    }

    final bytes = await source.readAsBytes();
    final id = sha256.convert(bytes).toString().substring(0, 16);
    final existing = _entries[id];
    if (existing != null) {
      return LocalBookImportResult(
        sourcePath: sourcePath,
        entry: existing,
        duplicated: true,
      );
    }

    final ext = _extensionOf(fileName);
    final dir = Directory('${root.path}/$id');
    if (!dir.existsSync()) await dir.create(recursive: true);
    final relativePath = '$id/book.$ext';
    final target = File('${root.path}/$relativePath');
    await target.writeAsBytes(bytes, flush: true);

    final ParsedBook parsed;
    try {
      parsed = await parser.parse(BookFileRef(
        fileName: fileName,
        path: target.path,
        sizeBytes: bytes.length,
      ));
    } catch (e) {
      // 解析失败不留垃圾目录。
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
      return LocalBookImportResult(
        sourcePath: sourcePath,
        error: e is BookFormatException ? e.message : '解析失败：$e',
      );
    }

    var coverPath = '';
    final cover = parsed.coverBytes;
    if (cover != null && cover.isNotEmpty) {
      coverPath = '$id/cover.jpg';
      await File('${root.path}/$coverPath').writeAsBytes(cover, flush: true);
    }

    final entry = LocalBookEntry(
      id: id,
      title: parsed.title.trim().isEmpty
          ? baseNameOfFile(fileName)
          : parsed.title.trim(),
      author: parsed.author,
      intro: parsed.intro,
      relativePath: relativePath,
      format: parsed.formatId,
      coverPath: coverPath,
      sourcePath: sourcePath,
      sizeBytes: bytes.length,
      importedAt: DateTime.now().toIso8601String(),
      chapterTitles: [for (final c in parsed.chapters) c.title],
      charCounts: [
        for (final c in parsed.chapters)
          c.blocks.fold<int>(0, (sum, b) {
            if (b is ParagraphBlock) return sum + b.plainText.length;
            return sum;
          }),
      ],
    );

    _entries[id] = entry;
    _documents[id] = LocalBookDocument(entry: entry, book: parsed, root: root);
    _trimDocumentCache();
    await _persist();
    await _writeMeta(entry);
    return LocalBookImportResult(sourcePath: sourcePath, entry: entry);
  }

  /// 批量导入目录（默认递归；跳过隐藏目录）。
  Future<List<LocalBookImportResult>> importFolder(
    String dirPath, {
    bool recursive = true,
  }) async {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) {
      return [
        LocalBookImportResult(sourcePath: dirPath, error: '目录不存在'),
      ];
    }
    final files = <File>[];
    await for (final entity in dir.list(recursive: recursive, followLinks: false)) {
      if (entity is! File) continue;
      if (entity.path.split(RegExp(r'[/\\]')).any((p) => p.startsWith('.'))) {
        continue;
      }
      final name = entity.path.replaceAll('\\', '/').split('/').last;
      if (registry.byExtension(_extensionOf(name)) == null) continue;
      files.add(entity);
    }
    files.sort((a, b) => a.path.compareTo(b.path));
    final results = <LocalBookImportResult>[];
    for (final file in files) {
      results.add(await importPath(file.path));
    }
    return results;
  }

  /// 打开文档（LRU 3 本；删除的条目返回 null）。
  Future<LocalBookDocument?> open(String id) async {
    await ensureLoaded();
    final cached = _documents[id];
    if (cached != null) return cached;
    final entry = _entries[id];
    if (entry == null) return null;
    final file = File('${root.path}/${entry.relativePath}');
    if (!file.existsSync()) {
      throw StateError('书文件已丢失：${entry.relativePath}');
    }
    final parser = registry.byExtension(entry.format);
    if (parser == null) {
      throw StateError('格式 ${entry.format} 的解析器已不可用');
    }
    final parsed = await parser.parse(BookFileRef(
      fileName: file.path.replaceAll('\\', '/').split('/').last,
      path: file.path,
      sizeBytes: entry.sizeBytes,
    ));
    final doc = LocalBookDocument(entry: entry, book: parsed, root: root);
    _documents[id] = doc;
    _trimDocumentCache();
    return doc;
  }

  Future<bool> remove(String id) async {
    await ensureLoaded();
    final entry = _entries.remove(id);
    _documents.remove(id);
    if (entry == null) return false;
    await _persist();
    try {
      await Directory('${root.path}/$id').delete(recursive: true);
    } catch (_) {
      // 文件删除失败不回滚索引：下次启动 meta 重建也不会复活（目录已不在）。
    }
    return true;
  }

  void _trimDocumentCache() {
    while (_documents.length > _documentCacheLimit) {
      _documents.remove(_documents.keys.first);
    }
  }

  Future<void> _persist() async {
    final prefs = await _prefsAsync;
    await prefs.setString(
      prefsKey,
      jsonEncode([for (final e in _entries.values) e.toJson()]),
    );
  }

  Future<void> _writeMeta(LocalBookEntry entry) async {
    try {
      await File('${root.path}/${entry.id}/meta.json')
          .writeAsString(jsonEncode(entry.toJson()), flush: true);
    } catch (_) {
      // meta 只是排查用副本，写失败不影响阅读。
    }
  }
}

String _extensionOf(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot == fileName.length - 1) return '';
  return fileName.substring(dot + 1).toLowerCase();
}
