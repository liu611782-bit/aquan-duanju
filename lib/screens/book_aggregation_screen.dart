import 'package:flutter/material.dart';
import 'dart:convert';


import '../core/books/book_source_model.dart';
import '../core/books/book_source_service.dart';
import '../core/books/book_source_store.dart';
import '../core/books/so_novel_seed.dart';
import '../core/error_log.dart';
import '../core/sources/source_fetch.dart';
import '../models/book.dart';
import '../widgets/common.dart';
import 'book_source_market_screen.dart';
import 'reader_screen.dart';

/// 小说聚合：legado 书源聚合搜索 → 书详情/目录 → 接现有阅读器。
///
/// 书源获取三路：粘贴 JSON（最稳）、仓库 URL 拉取、列表启停删除。
/// 仓库不内置第三方地址（公开仓库易失效），由用户填自己信任的仓库。
class BookAggregationScreen extends StatefulWidget {
  const BookAggregationScreen({super.key});

  @override
  State<BookAggregationScreen> createState() => _BookAggregationScreenState();
}

class _BookAggregationScreenState extends State<BookAggregationScreen> {
  final _queryController = TextEditingController();
  final _service = BookSourceService();
  final _hits = <(BookSource, BookHit)>[];
  bool _searching = false;

  BookSourceStore get _store => AppScope.read(context).bookSources;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    final sources = _store.enabled;
    if (sources.isEmpty) {
      _snack('还没有可用书源，先在「书源管理」里导入');
      return;
    }
    setState(() {
      _searching = true;
      _hits.clear();
    });
    final results = await Future.wait([
      for (final s in sources)
        () async {
          try {
            return (s, await _service.search(s, query));
          } catch (e) {
            ErrorLog.instance.record('书源搜索', '${s.name}：$e');
            return (s, const <BookHit>[]);
          }
        }(),
    ]);
    if (!mounted) return;
    setState(() {
      for (final (source, hits) in results) {
        for (final hit in hits) {
          if (hit.isMeaningful) _hits.add((source, hit));
        }
      }
      _searching = false;
    });
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('小说聚合'),
        actions: [
          IconButton(
            tooltip: '书源仓库',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => const BookSourceMarketScreen())),
          ),
          IconButton(
            tooltip: '书源管理',
            icon: const Icon(Icons.tune),
            onPressed: _showManageSheet,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _queryController,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                isDense: true,
                hintText: '聚合搜索（已启用 ${_store.enabled.length} 个书源）',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  tooltip: '搜索',
                  icon: const Icon(Icons.arrow_forward),
                  onPressed: _search,
                ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: _searching
                ? const Center(child: CircularProgressIndicator())
                : _hits.isEmpty
                    ? _buildEmpty(theme)
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                        itemCount: _hits.length,
                        itemBuilder: (context, i) {
                          final (source, hit) = _hits[i];
                          return ListTile(
                            leading: SizedBox(
                              width: 44,
                              height: 60,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: hit.coverUrl.isEmpty
                                    ? Container(
                                        color: theme
                                            .colorScheme.surfaceContainerHighest,
                                        child: const Icon(Icons.menu_book))
                                    : Image.network(hit.coverUrl,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, _, _) => Container(
                                            color: theme.colorScheme
                                                .surfaceContainerHighest)),
                              ),
                            ),
                            title: Text(hit.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                '${hit.author.isEmpty ? '佚名' : hit.author}'
                                ' · ${source.name}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            onTap: () => _openBook(source, hit),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_stories,
              size: 56, color: theme.colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            _store.enabled.isEmpty ? '还没有书源' : '输入关键词开始聚合搜索',
            style: theme.textTheme.bodyMedium,
          ),
          if (_store.enabled.isEmpty) ...[
            const SizedBox(height: 8),
            Text('支持粘贴 legado / so-novel 书源 JSON（自动识别方言），或从书源仓库拉取',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _showManageSheet,
              icon: const Icon(Icons.tune),
              label: const Text('导入书源'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _openBook(BookSource source, BookHit hit) async {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _BookSourceBookPage(
        service: _service,
        source: source,
        hit: hit,
      ),
    ));
  }

  // ---------------- 书源管理 ----------------

  Future<void> _showManageSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => const _BookSourceManageSheet(),
    );
    if (mounted) setState(() {});
  }
}

/// 书源管理：列表启停/删除 + 粘贴导入 + 仓库 URL 拉取。
class _BookSourceManageSheet extends StatefulWidget {
  const _BookSourceManageSheet();

  @override
  State<_BookSourceManageSheet> createState() => _BookSourceManageSheetState();
}

class _BookSourceManageSheetState extends State<_BookSourceManageSheet> {
  bool _importing = false;

  BookSourceStore get _store => AppScope.read(context).bookSources;

  Future<void> _importRaw(String raw, String origin) async {
    final trimmed = raw.trim();
    // 粘进来的是网址而非 JSON 正文：自动转「仓库拉取」抓取，避免 jsonDecode 崩并回显整串。
    if (_looksLikeUrl(trimmed)) {
      await _importRepo(trimmed, origin);
      return;
    }
    await _importJson(trimmed, origin);
  }

  /// 单行 http(s) 且不以 `[`/`{` 开头 → 当作导入网址处理。
  static bool _looksLikeUrl(String s) {
    if (s.isEmpty || s.contains('\n')) return false;
    if (s.startsWith('[') || s.startsWith('{')) return false;
    return s.startsWith('http://') || s.startsWith('https://');
  }

  /// 解析并导入 legado 书源 JSON（单个/数组）；调用方保证传入的是正文而非网址。
  Future<void> _importJson(String raw, String origin) async {
    setState(() => _importing = true);
    try {
      final decoded = jsonDecode(raw);
      final sources = BookSource.listFromJson(decoded);
      final usable = sources.where((s) => !s.requiresJs).toList();
      final jsRejected = sources.length - usable.length;
      final added = await _store.importAll(usable);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '$origin：导入 $added 个书源${jsRejected > 0 ? '，跳过 $jsRejected 个含脚本规则的' : ''}')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              '导入失败：内容不是有效的书源 JSON（若地址是网页，请用「仓库拉取」或粘贴书源 JSON）')));
    }
  }

  Future<void> _pasteImport() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('粘贴书源 JSON'),
        content: SizedBox(
          width: 480,
          child: TextField(
            controller: controller,
            maxLines: 10,
            decoration: const InputDecoration(
              hintText: '粘贴 legado / so-novel 书源 JSON（单个对象或数组，自动识别）',
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok == true && controller.text.trim().isNotEmpty) {
      await _importRaw(controller.text, '粘贴导入');
    }
  }

  Future<void> _repoImport() async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('从书源仓库拉取'),
        content: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: '仓库 URL',
                  hintText: '指向 legado 书源 JSON 数组的 http(s) 地址',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '填写你信任的书源仓库地址（公开仓库易失效，建议自行验证后收藏）',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('拉取')),
        ],
      ),
    );
    final url = controller.text.trim();
    if (ok != true || url.isEmpty) return;
    await _importRepo(url, '仓库拉取');
  }

  /// 拉取仓库 URL → 解析 → 导入（内置与自定义共用）。
  Future<void> _importRepo(String url, String origin) async {
    setState(() => _importing = true);
    try {
      final result = await fetchProbe(url,
          connectTimeout: const Duration(seconds: 8),
          readTimeout: const Duration(seconds: 10),
          maxBytes: 8 * 1024 * 1024);
      if (!result.ok || result.bytes == null) {
        throw Exception(result.error.isEmpty ? '拉取失败' : result.error);
      }
      await _importJson(utf8.decode(result.bytes!, allowMalformed: true),
          origin);
    } catch (e) {
      if (!mounted) return;
      setState(() => _importing = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$origin失败：$e')));
    }
  }

  /// 内置 so-novel 种子一键导入（香书小说/书海阁，so-novel 仓库逐字摘录）。
  Future<void> _importBuiltinSoNovel() async {
    setState(() => _importing = true);
    try {
      final added = await _store.importAll(builtinSoNovelSources);
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'so-novel 精选源：新增 $added 个（内置 ${builtinSoNovelSources.length} 个，重导自动去重覆盖）')));
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = _store;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('书源管理', style: theme.textTheme.titleMedium),
                const Spacer(),
                Text('${store.enabled.length} 启用 / ${store.sources.length} 总数',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline)),
              ],
            ),
            const Divider(height: 20),
            Flexible(
              child: store.sources.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text('还没有书源，先导入',
                            style: TextStyle(color: theme.colorScheme.outline)),
                      ),
                    )
                  : ListView(
                      shrinkWrap: true,
                      children: [
                        for (final s in store.sources)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(s.name.isEmpty ? s.url : s.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                                [
                                  if (s.format == BookSourceFormat.soNovel)
                                    'so-novel',
                                  if (s.group.isNotEmpty) s.group,
                                  s.url,
                                ]
                                    .where((t) => t.isNotEmpty)
                                    .join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Switch(
                                  value: s.enabled,
                                  onChanged: (v) async {
                                    await store.setEnabled(s.url, v);
                                    if (mounted) setState(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: '删除',
                                  icon: const Icon(Icons.delete_outline,
                                      size: 20),
                                  onPressed: () async {
                                    await store.remove(s.url);
                                    if (mounted) setState(() {});
                                  },
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            const Divider(height: 20),
            // 内置书源仓库（国内可达镜像，实测直连 200；导入自动去重）。
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importing
                        ? null
                        : () => _importRepo(
                            'https://fastly.jsdelivr.net/gh/XIU2/Yuedu@master/shuyuan',
                            'XIU2 精品书源'),
                    icon: const Icon(Icons.inventory_2_outlined, size: 18),
                    label: const Text('内置：XIU2 精品书源'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _importing ? null : _importBuiltinSoNovel,
                    icon: const Icon(Icons.auto_stories_outlined, size: 18),
                    label: const Text('内置：so-novel 精选源'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed:
                        _importing ? null : () => _pasteImport(),
                    icon: const Icon(Icons.content_paste, size: 18),
                    label: const Text('粘贴导入'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _importing ? null : () => _repoImport(),
                    icon: _importing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_download_outlined, size: 18),
                    label: const Text('仓库拉取'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 外部书源的书详情：封面/简介/目录 → 点章进阅读器（textLoader 注入）。
class _BookSourceBookPage extends StatefulWidget {
  const _BookSourceBookPage({
    required this.service,
    required this.source,
    required this.hit,
  });

  final BookSourceService service;
  final BookSource source;
  final BookHit hit;

  @override
  State<_BookSourceBookPage> createState() => _BookSourceBookPageState();
}

class _BookSourceBookPageState extends State<_BookSourceBookPage> {
  BookDetailData? _info;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final info = await widget.service
          .detail(widget.source, widget.hit.bookUrl)
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;
      setState(() {
        _info = info;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  String get _readerBookId =>
      'booksrc:${widget.source.url}:${widget.hit.bookUrl}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chapters = _info?.chapters ?? const <BookTocItem>[];
    return Scaffold(
      appBar: AppBar(title: Text(widget.hit.name.isEmpty
          ? '书籍详情' : widget.hit.name)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetryView(error: _error!, onRetry: _load)
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: SizedBox(
                            width: 104,
                            height: 140,
                            child: (widget.hit.coverUrl.isNotEmpty)
                                ? Image.network(widget.hit.coverUrl,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                        color: theme.colorScheme
                                            .surfaceContainerHighest))
                                : Container(
                                    color: theme
                                        .colorScheme.surfaceContainerHighest,
                                    child: const Icon(Icons.menu_book)),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_info?.name.isEmpty == false
                                  ? _info!.name
                                  : widget.hit.name,
                                  style: theme.textTheme.titleLarge),
                              const SizedBox(height: 4),
                              Text(widget.hit.author,
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(
                                          color: theme.colorScheme.outline)),
                              if ((_info?.intro ?? widget.hit.intro)
                                  .isNotEmpty) ...[
                                const SizedBox(height: 8),
                                Text(_info?.intro ?? widget.hit.intro,
                                    style: theme.textTheme.bodyMedium
                                        ?.copyWith(height: 1.4)),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text('目录（${chapters.length} 章）',
                        style: theme.textTheme.titleMedium),
                    for (final c in chapters)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(c.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: c.url.isEmpty
                            ? null
                            : () {
                                final bookChapters = [
                                  for (final t in chapters)
                                    BookChapter(
                                        id: t.url, title: t.title),
                                ];
                                Navigator.of(context).push(MaterialPageRoute(
                                  builder: (_) => ReaderScreen(
                                    bookId: _readerBookId,
                                    bookTitle: _info?.name.isEmpty == false
                                        ? _info!.name
                                        : widget.hit.name,
                                    chapters: bookChapters,
                                    initialIndex: bookChapters
                                        .indexWhere((b) => b.id == c.url)
                                        .clamp(0, bookChapters.length - 1),
                                    textLoader: (chapter) => widget.service
                                        .content(widget.source, chapter.id),
                                  ),
                                ));
                              },
                      ),
                  ],
                ),
    );
  }
}
