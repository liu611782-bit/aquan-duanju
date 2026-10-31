import 'dart:io';

import 'package:flutter/material.dart';

import '../core/sources/source_import.dart';
import '../core/sources/venera/venera_js_runtime.dart';
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
  bool _hasAccount = false;
  bool _logged = false;
  Map<String, dynamic> _settingsSchema = const {};

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
      _hasAccount = await source.hasAccount();
      _logged = await source.isLogged();
      _settingsSchema = await source.settingsSchema();
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
          if (_hasAccount)
            IconButton(
              icon: Icon(_logged ? Icons.person : Icons.person_outline,
                  color:
                      _logged ? Theme.of(context).colorScheme.primary : null),
              onPressed: _showAccountAction,
              tooltip: _logged ? '账号（已登录）' : '登录',
            ),
          if (_settingsSchema.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.tune),
              onPressed: _showSettingsSheet,
              tooltip: '源设置',
            ),
          IconButton(
            icon: const Icon(Icons.swap_horizontal_circle_outlined),
            onPressed: _showSourceSwitcher,
            tooltip: '换源',
          ),
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

  /// 换源：输入任意 Venera 源 JS URL（venera-configs 全部源适用），
  /// 持久化到设置后重载。
  Future<void> _showSourceSwitcher() async {
    final controller = TextEditingController(
        text: AppScope.read(context).settings.veneraSourceUrl);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('换源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: '源 JS 地址',
                hintText: _defaultUrl,
              ),
            ),
            const SizedBox(height: 8),
            Text('venera-configs 仓库内任意源 .js 的 raw 地址均可',
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('切换')),
        ],
      ),
    );
    if (ok != true) return;
    final url = controller.text.trim();
    if (!mounted) return;
    AppScope.read(context).settings.veneraSourceUrl = url;
    _loadSource();
  }

  /// 源设置表单：按 settings 声明渲染（input/select/switch/callback），
  /// 保存经 saveSetting → VeneraStore 落盘；baseUrl 等 getter 实时读取。
  Future<void> _showSettingsSheet() async {
    final source = _source;
    if (source == null) return;
    final current = <String, dynamic>{};
    for (final key in _settingsSchema.keys) {
      current[key] = await source.loadSettingValue(key);
    }
    if (!mounted) return;
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom),
        child: _SourceSettingsForm(
          schema: _settingsSchema,
          current: current,
          source: source,
        ),
      ),
    );
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('源设置已保存')));
      await _loadExplore(_exploreIndex);
    }
  }

  /// 账号动作：已登录 → 确认登出；未登录 → 登录对话框。
  Future<void> _showAccountAction() async {
    final source = _source;
    if (source == null) return;
    if (_logged) {
      final logout = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('登出'),
          content: const Text('退出当前源账号？'),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('登出')),
          ],
        ),
      );
      if (logout != true) return;
      try {
        await source.logout();
        if (!mounted) return;
        setState(() => _logged = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('已登出')));
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('登出失败: $e')));
      }
      return;
    }
    final username = TextEditingController();
    final password = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('登录 ${source.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: username,
              decoration: const InputDecoration(labelText: '用户名'),
            ),
            TextField(
              controller: password,
              obscureText: true,
              decoration: const InputDecoration(labelText: '密码'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('登录')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await source.login(username.text.trim(), password.text);
      if (!mounted) return;
      final logged = await source.isLogged();
      if (!mounted) return;
      setState(() => _logged = logged);
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('登录成功')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('登录失败: $e')));
    }
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
  bool _followed = false;

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
      _syncFollowed();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  void _syncFollowed() {
    _followed = AppScope.read(context).follows.get(_bookId) != null;
  }

  Future<void> _toggleFollow() async {
    final detail = _detail;
    if (detail == null) return;
    final scope = AppScope.read(context);
    await scope.follows.toggle(
      seriesId: _bookId,
      title: detail.title,
      coverUrl: detail.cover,
      episodeCount: detail.flatEpisodes.length,
    );
    if (!mounted) return;
    setState(() => _followed = scope.follows.get(_bookId) != null);
  }

  String get _bookId => 'venera:${widget.source.key}:${widget.comicId}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('漫画详情'),
        actions: [
          if (_detail != null)
            IconButton(
              icon: Icon(_followed ? Icons.favorite : Icons.favorite_border,
                  color: _followed ? theme.colorScheme.primary : null),
              onPressed: _toggleFollow,
              tooltip: _followed ? '取消收藏' : '收藏',
            ),
        ],
      ),
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

/// 源设置表单：按声明渲染（input/select/switch/callback），确认时批量保存。
class _SourceSettingsForm extends StatefulWidget {
  const _SourceSettingsForm({
    required this.schema,
    required this.current,
    required this.source,
  });

  final Map<String, dynamic> schema;
  final Map<String, dynamic> current;
  final VeneraMangaSource source;

  @override
  State<_SourceSettingsForm> createState() => _SourceSettingsFormState();
}

class _SourceSettingsFormState extends State<_SourceSettingsForm> {
  final _controllers = <String, TextEditingController>{};
  final _changed = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    widget.schema.forEach((key, entry) {
      final type = entry['type']?.toString() ?? 'input';
      if (type == 'input') {
        _controllers[key] = TextEditingController(
            text: widget.current[key]?.toString() ?? '');
      }
    });
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(maxHeight: 560),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('源设置', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final entry in widget.schema.entries)
                  _fieldFor(entry.key, entry.value),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () async {
                  for (final e in _changed.entries) {
                    await widget.source.saveSettingValue(e.key, e.value);
                  }
                  if (context.mounted) Navigator.pop(context, true);
                },
                child: const Text('保存'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _fieldFor(String key, dynamic entry) {
    if (entry is! Map) return const SizedBox.shrink();
    final spec = Map<String, dynamic>.from(entry);
    final title = spec['title']?.toString() ?? key;
    final type = spec['type']?.toString() ?? 'input';
    switch (type) {
      case 'select':
        final options = (spec['options'] as List? ?? const [])
            .whereType<Map>()
            .map((o) => MapEntry(
                o['value']?.toString() ?? '', o['text']?.toString() ?? ''))
            .toList();
        final value = (_changed[key] ?? widget.current[key])?.toString() ??
            (spec['default']?.toString() ?? '');
        return ListTile(
          title: Text(title),
          subtitle: options.isEmpty
              ? null
              : Wrap(
                  spacing: 8,
                  children: [
                    for (final o in options)
                      ChoiceChip(
                        label: Text(o.value),
                        selected: value == o.key,
                        onSelected: (_) => setState(() => _changed[key] = o.key),
                      ),
                  ],
                ),
        );
      case 'switch':
        final value = (_changed[key] ?? widget.current[key]) == true ||
            (widget.current[key] == null && spec['default'] == true);
        return SwitchListTile(
          title: Text(title),
          value: value,
          onChanged: (v) => setState(() => _changed[key] = v),
        );
      case 'callback':
        return ListTile(
          title: Text(title),
          trailing: OutlinedButton(
            onPressed: () {
              final messenger = ScaffoldMessenger.of(context);
              VeneraJsRuntime.instance
                  .callMethod(widget.source.key, 'settings.$key.callback', [])
                  .catchError((Object e) {
                messenger.showSnackBar(SnackBar(content: Text('$e')));
              });
            },
            child: Text(spec['buttonText']?.toString() ?? '执行'),
          ),
        );
      default:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: TextField(
            controller: _controllers[key],
            decoration: InputDecoration(labelText: title),
            onChanged: (v) => _changed[key] = v,
          ),
        );
    }
  }
}
