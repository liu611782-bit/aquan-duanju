import 'package:flutter/material.dart';

import '../core/books/book_source_model.dart';
import '../core/books/book_source_service.dart';
import '../core/books/provider/wenku8_page.dart';
import '../core/books/provider/wenku8_provider.dart';
import '../widgets/common.dart';
import '../widgets/cookie_dialog.dart';
import 'book_source_book_page.dart';

/// 内置 Wenku8 书城：**排行 / 分类** 两个维度浏览，点书进详情。
///
/// 分类表来自站点导航实时解析（不预置猜测的 class id）；解析不到就隐藏分类页签，
/// 只保留排行——诚实降级，不展示假分类。
class Wenku8BrowseScreen extends StatefulWidget {
  const Wenku8BrowseScreen({
    super.key,
    required this.service,
    required this.source,
    this.provider,
  });

  final BookSourceService service;
  final BookSource source;

  /// 可注入的 provider（测试/镜像源用；null = 生产默认）。
  final Wenku8Provider? provider;

  @override
  State<Wenku8BrowseScreen> createState() => _Wenku8BrowseScreenState();
}

class _Wenku8BrowseScreenState extends State<Wenku8BrowseScreen>
    with SingleTickerProviderStateMixin {
  late final Wenku8Provider _provider = widget.provider ?? Wenku8Provider();
  late final TabController _tabs;

  final _rankHits = <BookHit>[];
  final _classHits = <BookHit>[];
  final _classes = <Wenku8Class>[];

  Wenku8Rank _rank = Wenku8Rank.visit;
  Wenku8Class? _class;
  int _rankPage = 1;
  int _classPage = 1;
  bool _loadingRank = true;
  bool _loadingClass = false;
  bool _classReady = false;
  Object? _rankError;
  Object? _classError;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _loadRank(reset: true);
    _loadClasses();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadRank({required bool reset}) async {
    setState(() {
      _loadingRank = true;
      _rankError = null;
      if (reset) _rankPage = 1;
    });
    try {
      final hits = await _provider.browseRank(
        _rank,
        page: _rankPage,
        source: widget.source,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _rankHits.clear();
        _rankHits.addAll(hits.where((h) => h.isMeaningful));
        _loadingRank = false;
        if (hits.isEmpty) _rankError = StateError('没有更多了');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rankError = e;
        _loadingRank = false;
      });
    }
  }

  /// 就地填 Cookie：403 时不用去别的页面找设置。
  Future<void> _editCookie() async {
    final store = AppScope.read(context).bookSources;
    final current = store.byUrl(widget.source.url) ?? widget.source;
    final auth = await showBookSourceAuthDialog(
      context,
      title: current.name.isEmpty ? current.url : current.name,
      cookie: current.cookie,
      userAgent: current.userAgent,
    );
    if (auth == null) return;
    await store.update(
        current.copyWithAuth(cookie: auth.cookie, userAgent: auth.userAgent));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(auth.cookie.isEmpty ? '已清空 Cookie' : '已保存，正在重试…')));
    await _loadRank(reset: true);
    await _loadClasses();
  }

  Future<void> _loadClasses() async {
    try {
      final classes = await _provider.classes(source: widget.source);
      if (!mounted) return;
      setState(() {
        _classes
          ..clear()
          ..addAll(classes);
        _classReady = true;
        _class = classes.isEmpty ? null : classes.first;
      });
      if (_class != null) await _loadClass(reset: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _classReady = true;
        _classError = e;
      });
    }
  }

  Future<void> _loadClass({required bool reset}) async {
    final target = _class;
    if (target == null) return;
    setState(() {
      _loadingClass = true;
      _classError = null;
      if (reset) _classPage = 1;
    });
    try {
      final hits = await _provider.browseClass(
        target.id,
        page: _classPage,
        source: widget.source,
      );
      if (!mounted) return;
      setState(() {
        if (reset) _classHits.clear();
        _classHits.addAll(hits.where((h) => h.isMeaningful));
        _loadingClass = false;
        if (hits.isEmpty) _classError = StateError('没有更多了');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _classError = e;
        _loadingClass = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('轻小说文库'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '排行'), Tab(text: '分类')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [_buildRank(), _buildClass()],
      ),
    );
  }

  // ------------------------------------------------------------------ 排行

  Widget _buildRank() {
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              for (final rank in Wenku8Rank.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(rank.label),
                    selected: _rank == rank,
                    onSelected: (_) {
                      if (_rank == rank) return;
                      setState(() => _rank = rank);
                      _loadRank(reset: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _buildList(
            hits: _rankHits,
            loading: _loadingRank,
            error: _rankError,
            onRetry: () => _loadRank(reset: true),
            onMore: () {
              _rankPage++;
              _loadRank(reset: false);
            },
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 分类

  Widget _buildClass() {
    if (!_classReady) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_classes.isEmpty) {
      final error = _classError;
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                error is StateError || error == null
                    ? '未能从站点解析出分类列表（站点可能改版）。\n可先用「排行」浏览。'
                    : '拉取分类失败：\n$error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: _editCookie,
                    icon: const Icon(Icons.cookie_outlined, size: 18),
                    label: const Text('填入 Cookie'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _loadClasses,
                    icon: const Icon(Icons.refresh),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(
            children: [
              for (final c in _classes)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(c.name),
                    selected: _class?.id == c.id,
                    onSelected: (_) {
                      if (_class?.id == c.id) return;
                      setState(() => _class = c);
                      _loadClass(reset: true);
                    },
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: _buildList(
            hits: _classHits,
            loading: _loadingClass,
            error: _classError,
            onRetry: () => _loadClass(reset: true),
            onMore: () {
              _classPage++;
              _loadClass(reset: false);
            },
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------------ 列表

  Widget _buildList({
    required List<BookHit> hits,
    required bool loading,
    required Object? error,
    required VoidCallback onRetry,
    required VoidCallback onMore,
  }) {
    final theme = Theme.of(context);
    if (loading && hits.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (hits.isEmpty) {
      if (error != null && error is! StateError) {
        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ErrorRetryView(error: error, onRetry: onRetry),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _editCookie,
                  icon: const Icon(Icons.cookie_outlined, size: 18),
                  label: const Text('填入浏览器 Cookie（绕过 Cloudflare 403）'),
                ),
              ],
            ),
          ),
        );
      }
      return Center(
        child: Text('没有结果', style: theme.textTheme.bodyMedium),
      );
    }
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        if (n.metrics.pixels >= n.metrics.maxScrollExtent - 240 &&
            !loading &&
            (error == null || error is StateError)) {
          // 触底加载下一页（用户手动触发，失败只提示不阻塞）。
          onMore();
        }
        return false;
      },
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: hits.length + (loading ? 1 : 0),
        itemBuilder: (context, i) {
          if (i >= hits.length) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          final hit = hits[i];
          return ListTile(
            leading: SizedBox(
              width: 44,
              height: 60,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: hit.coverUrl.isEmpty
                    ? Container(
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.menu_book),
                      )
                    : Image.network(hit.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.surfaceContainerHighest)),
              ),
            ),
            title: Text(hit.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              [
                hit.author.isEmpty ? '佚名' : hit.author,
                if (hit.lastChapter.isNotEmpty) hit.lastChapter,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => BookSourceBookPage(
                service: widget.service,
                source: widget.source,
                hit: hit,
              ),
            )),
          );
        },
      ),
    );
  }
}
