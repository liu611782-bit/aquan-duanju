import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../core/sources/source_import.dart';
import '../core/sources/venera/venera_manga_source.dart';
import '../models/book.dart';
import '../models/manga.dart';
import '../widgets/common.dart';
import 'manga_reader_screen.dart';

/// Venera 漫画源浏览：探索页（分类）+ 搜索 + 详情 + 阅读器。
///
/// 源 JS 地址持久化在设置 `venera.sourceUrl`；预置 venera-configs 的
/// copy_manga（拷贝漫画，JSON API 免反爬）。
class VeneraMangaScreen extends StatefulWidget {
  const VeneraMangaScreen({super.key});

  @override
  State<VeneraMangaScreen> createState() => _VeneraMangaScreenState();
}

class _VeneraMangaScreenState extends State<VeneraMangaScreen> {
  static const _defaultUrl =
      'https://raw.githubusercontent.com/venera-app/venera-configs@master/copy_manga.js';

  VeneraMangaSource? _source;
  Object? _error;
  bool _loading = true;
  List<String> _exploreTitles = [];
  int _exploreIndex = 0;
  List<VeneraComic> _comics = const [];
  bool _comicsLoading = false;

  @override
  void initState() {
    super.initState();
    _loadSource();
  }

  Future<void> _loadSource() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final url = AppScope.read(context).settings.veneraSourceUrl.isNotEmpty
          ? AppScope.read(context).settings.veneraSourceUrl
          : _defaultUrl;
      final js = await _fetchJs(url);
      final source = VeneraMangaSource(js);
      await source.load();
      final titles = await source.exploreTitles();
      if (!mounted) return;
      setState(() {
        _source = source;
        _exploreTitles = titles;
        _loading = false;
      });
      if (titles.isNotEmpty) await _loadExplore(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  /// 源 JS：缓存目录优先（下载过即离线可用），否则网络下载。
  Future<String> _fetchJs(String url) async {
    final cache = File('${(await getCacheDir()).path}/venera_source.js');
    if (await cache.exists()) {
      final cached = await cache.readAsString();
      if (cached.isNotEmpty) return cached;
    }
    final js = await SourceImporter.fetchConfigText(url, enforceSsrf: false);
    await cache.writeAsString(js, flush: true);
    return js;
  }

  static Future<Directory> getCacheDir() async =>
      Directory.systemTemp; // 运行时由 path_provider 提供；测试可替换。

  Future<void> _loadExplore(int index) async {
    final source = _source;
    if (source == null) return;
    setState(() {
      _exploreIndex = index;
      _comicsLoading = true;
    });
    try {
      final comics = await source.exploreLoad(index).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _comics = comics;
        _comicsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _comics = const [];
        _comicsLoading = false;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _search(String keyword) async {
    final source = _source;
    if (source == null || keyword.trim().isEmpty) return;
    setState(() => _comicsLoading = true);
    try {
      final comics = await source
          .search(keyword.trim(), 1)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _comics = comics;
        _comicsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _comicsLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_source?.name ?? '漫画源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadSource,
            tooltip: '重载源',
          ),
        ],
      ),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _loadSource,
        child: _buildBody(theme),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索漫画',
              border: OutlineInputBorder(),
            ),
            textInputAction: TextInputAction.search,
            onSubmitted: _search,
          ),
        ),
        if (_exploreTitles.isNotEmpty)
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (var i = 0; i < _exploreTitles.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_exploreTitles[i]),
                      selected: i == _exploreIndex,
                      onSelected: (_) => _loadExplore(i),
                    ),
                  ),
              ],
            ),
          ),
        Expanded(
          child: _comicsLoading
              ? const Center(child: CircularProgressIndicator())
              : _comics.isEmpty
                  ? Center(
                      child: Text('这里空空如也',
                          style: TextStyle(color: theme.colorScheme.outline)))
                  : GridView.builder(
                      padding: const EdgeInsets.all(12),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 110,
                        childAspectRatio: 0.62,
                        crossAxisSpacing: 10,
                        mainAxisSpacing: 10,
                      ),
                      itemCount: _comics.length,
                      itemBuilder: (context, index) {
                        final comic = _comics[index];
                        return _ComicCard(
                          comic: comic,
                          onTap: () => _openDetail(comic),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  void _openDetail(VeneraComic comic) {
    final source = _source;
    if (source == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => VeneraMangaDetailScreen(source: source, comicId: comic.id),
    ));
  }
}

/// Venera 漫画详情：封面/简介/章节（按组分卷）→ 阅读器（页加载器注入）。
class VeneraMangaDetailScreen extends StatefulWidget {
  const VeneraMangaDetailScreen({
    super.key,
    required this.source,
    required this.comicId,
  });

  final VeneraMangaSource source;
  final String comicId;

  @override
  State<VeneraMangaDetailScreen> createState() =>
      _VeneraMangaDetailScreenState();
}

class _VeneraMangaDetailScreenState extends State<VeneraMangaDetailScreen> {
  VeneraComicDetail? _detail;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final detail =
          await widget.source.loadInfo(widget.comicId).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      setState(() {
        _detail = detail;
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

  String get _bookId => 'venera:${widget.source.key}:${widget.comicId}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('漫画详情')),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _load,
        child: _buildContent(theme),
      ),
    );
  }

  Widget _buildContent(ThemeData theme) {
    final detail = _detail!;
    final eps = detail.flatEpisodes;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        Text(detail.title,
            style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        if (detail.cover.isNotEmpty)
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(detail.cover,
                height: 180, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ),
        if (detail.description.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(detail.description,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.5)),
        ],
        const SizedBox(height: 16),
        for (final group in detail.chapters) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Text(group.title,
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          ),
          for (final ep in group.episodes)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(ep.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: const Icon(Icons.chevron_right, size: 18),
              onTap: () => _read(ep),
            ),
        ],
        if (eps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Text('该漫画暂无章节',
                style: TextStyle(color: theme.colorScheme.outline)),
          ),
      ],
    );
  }

  void _read(VeneraEpisode ep) {
    final detail = _detail;
    if (detail == null) return;
    final chapters = [
      for (final g in detail.chapters)
        for (final e in g.episodes)
          BookChapter(id: e.id, title: e.title, volume: g.title),
    ];
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MangaReaderScreen(
        bookId: _bookId,
        bookTitle: detail.title,
        chapters: chapters,
        initialIndex: chapters.indexWhere((c) => c.id == ep.id).clamp(0, chapters.length - 1),
        pageLoader: (chapter) async {
          final images =
              await widget.source.loadEpImages(widget.comicId, chapter.id);
          return MangaChapterPages(
            itemId: chapter.id,
            key: '',
            pages: [for (final u in images) MangaPage(url: u)],
          );
        },
      ),
    ));
  }
}

class _ComicCard extends StatelessWidget {
  const _ComicCard({required this.comic, required this.onTap});

  final VeneraComic comic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: comic.cover.isEmpty
                  ? Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)
                  : Image.network(comic.cover,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Container(color: Theme.of(context).colorScheme.surfaceContainerHighest)),
            ),
          ),
          const SizedBox(height: 4),
          Text(comic.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall),
        ],
      ),
    );
  }
}

/// 把源 JSON 解出来（设置存储用）。
Map<String, dynamic> decodeSourceJson(String raw) =>
    raw.isEmpty ? const {} : jsonDecode(raw) as Map<String, dynamic>;
