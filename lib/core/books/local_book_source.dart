/// 本地书**虚拟书源门面**：把书库（`BookLibrary`）适配成阅读器/书架认识的数据面。
///
/// - `bookUrl` = `localbook:<id>`；`chapter.url` = `localchapter:<id>:<index>`（与旧实现一致，
///   阅读进度、书签、缓存的既有键不需要迁移）；
/// - 正文走 [LocalBookRuntime]，按需从书库取章节（带文档 LRU 缓存）；
/// - 之前「每次调用重新读盘 + 全文重解析」的缺陷在书库层修掉。
library;

import 'package:flutter/foundation.dart';

import 'formats/book_block.dart';
import 'library/book_library.dart';

export 'library/book_library.dart'
    show BookLibrary, LocalBookEntry, LocalBookImportResult, LocalBookDocument;

/// 提取本地书 id；非本地书返回 null。
String? localBookIdOf(String url) {
  if (!url.startsWith(LocalBookStore.schemePrefix)) return null;
  return url.substring(LocalBookStore.schemePrefix.length);
}

/// 提取 (bookId, chapterIndex)；非本地章节返回 null。
(String, int)? localChapterOf(String url) {
  if (!url.startsWith(LocalBookStore.chapterPrefix)) return null;
  final rest = url.substring(LocalBookStore.chapterPrefix.length);
  final i = rest.lastIndexOf(':');
  if (i <= 0) return null;
  final index = int.tryParse(rest.substring(i + 1));
  if (index == null) return null;
  return (rest.substring(0, i), index);
}

/// 本地书注册表（ChangeNotifier 供书架订阅）。真正的存储/解析在 [BookLibrary]。
class LocalBookStore extends ChangeNotifier {
  LocalBookStore(this.library);

  static const String schemePrefix = 'localbook:';
  static const String chapterPrefix = 'localchapter:';

  final BookLibrary library;

  bool _loaded = false;

  Map<String, LocalBookEntry> get entries => library.entries;

  /// 支持的扩展名（文件选择器/拖拽过滤用）。
  Set<String> get supportedExtensions => library.registry.supportedExtensions;

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await library.ensureLoaded();
    _loaded = true;
    notifyListeners();
  }

  /// 批量导入（逐条结果；失败带原因）。
  Future<List<LocalBookImportResult>> importPaths(List<String> paths) async {
    await ensureLoaded();
    final results = <LocalBookImportResult>[];
    for (final path in paths) {
      results.add(await library.importPath(path));
    }
    notifyListeners();
    return results;
  }

  /// 目录扫描导入。
  Future<List<LocalBookImportResult>> importFolder(
    String dirPath, {
    bool recursive = true,
  }) async {
    await ensureLoaded();
    final results =
        await library.importFolder(dirPath, recursive: recursive);
    notifyListeners();
    return results;
  }

  Future<bool> remove(String id) async {
    final removed = await library.remove(id);
    if (removed) notifyListeners();
    return removed;
  }

  /// 打开文档（阅读器/详情用；null = 条目不存在）。
  Future<LocalBookDocument?> open(String id) => library.open(id);

  /// 本地书章节列表（`BookChapter` 兼容的 id/title 对）。
  List<({String id, String title})> chaptersOf(LocalBookEntry entry) => [
        for (var i = 0; i < entry.chapterTitles.length; i++)
          (
            id: '$chapterPrefix${entry.id}:$i',
            title: entry.chapterTitles[i],
          ),
      ];

  /// 书封面的绝对路径（无封面返回空）。
  String coverPathOf(LocalBookEntry entry) {
    if (!entry.hasCover) return '';
    return '${library.root.path}/${entry.coverPath}';
  }
}

/// 本地书运行时：章节正文 / 区块 / 插图。
class LocalBookRuntime {
  LocalBookRuntime(this.store);

  final LocalBookStore store;

  Future<LocalBookDocument> _doc(String chapterUrl) async {
    final ref = localChapterOf(chapterUrl);
    if (ref == null) throw StateError('不是本地章节: $chapterUrl');
    final doc = await store.open(ref.$1);
    if (doc == null) throw StateError('本地书不存在: ${ref.$1}');
    return doc;
  }

  /// 正文纯文本（阅读器 textLoader 契约）。
  Future<String> content(String chapterUrl) async {
    final ref = localChapterOf(chapterUrl)!;
    final doc = await _doc(chapterUrl);
    final blocks = doc.chapterAt(ref.$2);
    final text = blocks.plainText;
    return text.isEmpty ? blocks.title : '${blocks.title}\n\n$text';
  }

  /// 结构化区块（富文本阅读器用）。
  Future<ChapterBlocks> blocks(String chapterUrl) async {
    final ref = localChapterOf(chapterUrl)!;
    final doc = await _doc(chapterUrl);
    return doc.chapterAt(ref.$2);
  }

  /// 插图字节（EPUB 包内资源）。
  Future<Uint8List?> resource(String chapterUrl, String href) async {
    final doc = await _doc(chapterUrl);
    final bytes = await doc.resource(href);
    return bytes == null ? null : Uint8List.fromList(bytes);
  }
}
