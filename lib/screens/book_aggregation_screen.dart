import 'package:flutter/material.dart';
import 'dart:convert';


import '../core/books/book_source_checker.dart';
import '../core/books/book_source_model.dart';
import '../core/books/book_source_service.dart';
import '../core/books/book_source_store.dart';
import '../core/books/so_novel_seed.dart';
import '../core/error_log.dart';
import '../core/sources/source_fetch.dart';
import '../widgets/common.dart';
import '../widgets/cookie_dialog.dart';
import '../widgets/skeleton.dart';
import 'book_source_book_page.dart';
import 'book_source_market_screen.dart';
import 'rss_screen.dart';
import 'wenku8_browse_screen.dart';

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
      _lastFailure = '';
    });
    final failures = <String>[];
    final results = await Future.wait([
      for (final s in sources)
        () async {
          try {
            return (s, await _service.search(s, query));
          } catch (e) {
            ErrorLog.instance.record('书源搜索', '${s.name}：$e');
            failures.add('${s.name}：$e');
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
      // 只在「一条结果都没搜到」时把失败原因摆到页面上，避免刷屏。
      if (_hits.isEmpty && failures.isNotEmpty) {
        _lastFailure = failures.take(3).join('\n');
      }
    });
  }

  /// 上一次搜索全灭时的原因摘要（页面顶部提示）。
  String _lastFailure = '';

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
            tooltip: '订阅（RSS/Atom）',
            icon: const Icon(Icons.rss_feed),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const RssScreen()),
            ),
          ),
          IconButton(
            tooltip: '轻小说文库（内置书城）',
            icon: const Icon(Icons.local_library_outlined),
            onPressed: _openWenku8,
          ),
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
                ? const Center(child: SkeletonView(layout: SkeletonLayout.list))
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
          if (_lastFailure.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              constraints: const BoxConstraints(maxWidth: 520),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('所有源都没有结果，失败原因：',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.error,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(height: 6),
                  Text(
                    _lastFailure,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '常见原因：源站已失效 / 被墙 / 需要登录或 Cloudflare 校验。\n'
                    '处理：打开「书源管理 → 清理失效源」一键删除不可用的源；'
                    '内置的「轻之文库」免登录可用（删掉后不会自动恢复）。',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          ],
          if (_store.enabled.isEmpty) ...[
            const SizedBox(height: 8),
            Text('支持粘贴 legado（含 js 规则）/ so-novel 书源 JSON（自动识别方言），或从书源仓库拉取',
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
      builder: (_) => BookSourceBookPage(
        service: _service,
        source: source,
        hit: hit,
      ),
    ));
  }

  /// 内置 Wenku8 书城（分类 / 排行）。
  Future<void> _openWenku8() async {
    final builtin = _store.sources
        .where((s) => s.format == BookSourceFormat.wenku8)
        .toList();
    if (builtin.isEmpty) {
      _snack('内置 Wenku8 源未就绪，请稍后重试');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Wenku8BrowseScreen(
        service: _service,
        source: builtin.first,
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

  /// 解析并导入书源 JSON（单个/数组；legado / so-novel 自动识别；调用方保证传入的是正文而非网址）。
  Future<void> _importJson(String raw, String origin) async {
    setState(() => _importing = true);
    try {
      final decoded = jsonDecode(raw);
      final sources = BookSource.listFromJson(decoded);
      // js 规则源不再过滤：js 引擎按需执行，跑不通的源由体检/搜索诚实报错。
      final added = await _store.importAll(sources);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('$origin：导入 $added 个书源')));
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

  /// 编辑 Cookie：Cloudflare 站点（如 Wenku8）需要浏览器通过校验后的
  /// `cf_clearance`，登录态站点需要会话 Cookie。
  Future<void> _editCookie(BookSource source) async {
    final result = await showBookSourceAuthDialog(
      context,
      title: source.name.isEmpty ? source.url : source.name,
      cookie: source.cookie,
      userAgent: source.userAgent,
    );
    if (result == null) return;
    await _store.update(
        source.copyWithAuth(cookie: result.cookie, userAgent: result.userAgent));
    if (!mounted) return;
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.cookie.isEmpty ? '已清空 Cookie' : '已保存 Cookie')));
  }

  bool _cleaning = false;
  int _cleanTotal = 0;
  int _cleanProgress = 0;

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  /// 逐源实测并删除不可用的源（含内置源；删掉的内置源不再自动注入）。
  ///
  /// 探测只做「搜索」一步（不拉正文），单源 20s 超时，避免清理一次要几分钟。
  Future<void> _cleanBroken() async {
    final store = _store;
    final targets = store.sources.where((s) => s.enabled).toList();
    if (targets.isEmpty) {
      _snack('没有启用的书源');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清理失效源'),
        content: Text(
          '将逐个实测 ${targets.length} 个启用源（只测搜索，单源最多 20 秒），'
          '把不可用的源直接删除（含内置源）。\n\n'
          '源站被墙/需要登录的源也会被判定为失效——删掉后需要时可以从「书源仓库」重新导入。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('开始检测'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() {
      _cleaning = true;
      _cleanTotal = targets.length;
      _cleanProgress = 0;
    });

    final checker = BookSourceChecker();
    final broken = <String>[];
    for (final source in targets) {
      try {
        final check = await checker
            .check(source, kDefaultProbeQuery, fetchContent: false)
            .timeout(const Duration(seconds: 20));
        if (!check.ok) broken.add(source.url);
      } catch (e) {
        broken.add(source.url);
        ErrorLog.instance.record('清理失效源', '${source.name}：$e');
      }
      if (!mounted) break;
      setState(() => _cleanProgress++);
    }

    final removed = await store.removeAll(broken);
    if (!mounted) return;
    setState(() => _cleaning = false);
    _snack(removed == 0
        ? '全部可用，未删除任何源'
        : '已删除 $removed 个失效源，剩余 ${store.sources.length} 个');
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
                if (_cleaning)
                  Row(
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 6),
                      Text('检测 $_cleanProgress/$_cleanTotal',
                          style: theme.textTheme.bodySmall),
                    ],
                  )
                else
                  TextButton.icon(
                    onPressed: store.sources.isEmpty ? null : _cleanBroken,
                    icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                    label: const Text('清理失效源'),
                  ),
                const SizedBox(width: 6),
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
                                  switch (s.format) {
                                    BookSourceFormat.soNovel => 'so-novel',
                                    BookSourceFormat.wenku8 => '内置站点',
                                    BookSourceFormat.local => '本地书',
                                    BookSourceFormat.legado => '',
                                  },
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
                                if (store.isBuiltin(s.url))
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4),
                                    child: Tooltip(
                                      message: '内置源（可停用/删除，删后不再自动出现）',
                                      child: Icon(Icons.bookmark_outline,
                                          size: 15,
                                          color: theme.colorScheme.primary),
                                    ),
                                  ),
                                Switch(
                                  value: s.enabled,
                                  onChanged: (v) async {
                                    await store.setEnabled(s.url, v);
                                    if (mounted) setState(() {});
                                  },
                                ),
                                IconButton(
                                  tooltip: 'Cookie / UA（Cloudflare · 登录态）',
                                  icon: Icon(
                                    s.cookie.isEmpty
                                        ? Icons.cookie_outlined
                                        : Icons.cookie,
                                    size: 20,
                                  ),
                                  onPressed: () => _editCookie(s),
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

// 书籍详情页已抽到 book_source_book_page.dart（Wenku8 浏览页复用同一实现）。
