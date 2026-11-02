import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/book_text.dart';
import '../core/rss/rss_feed.dart';
import '../core/rss/rss_models.dart';
import '../core/rss/rss_store.dart';
import '../widgets/common.dart';

/// 订阅（RSS/Atom）阅读器：源列表 → 文章列表 → 正文。
///
/// 导入方式：把 legado `rssSource` JSON 放剪贴板 → 右上「导入订阅源」。
class RssScreen extends StatefulWidget {
  const RssScreen({super.key, this.store});

  final RssStore? store;

  @override
  State<RssScreen> createState() => _RssScreenState();
}

class _RssScreenState extends State<RssScreen> {
  RssStore? _store;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final store = widget.store ?? RssStore(prefs);
    await store.ensureLoaded();
    if (!mounted) return;
    setState(() => _store = store);
  }

  Future<void> _import() async {
    final store = _store;
    if (store == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('剪贴板里没有 JSON')));
      return;
    }
    final added = await store.importJson(text);
    if (!mounted) return;
    setState(() {});
    messenger.showSnackBar(SnackBar(
        content: Text(added == 0 ? '没有新增（重复或不是订阅源 JSON）' : '已导入 $added 个订阅源')));
  }

  @override
  Widget build(BuildContext context) {
    final store = _store;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('订阅'),
        actions: [
          IconButton(
            tooltip: '从剪贴板导入订阅源',
            icon: const Icon(Icons.playlist_add),
            onPressed: _import,
          ),
        ],
      ),
      body: store == null
          ? const Center(child: CircularProgressIndicator())
          : ListenableBuilder(
              listenable: store,
              builder: (context, _) {
                final sources = store.sources;
                if (sources.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        '还没有订阅源。\n在订阅源站点导出 JSON（legado rssSource 格式），'
                        '复制后点右上角导入。',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: theme.colorScheme.outline),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: sources.length,
                  separatorBuilder: (_, i) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final source = sources[i];
                    return ListTile(
                      leading: const Icon(Icons.rss_feed),
                      title: Text(source.name.isEmpty ? source.url : source.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        source.group.isEmpty ? source.url : source.group,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () async {
                          await store.remove(source.url);
                          if (mounted) setState(() {});
                        },
                      ),
                      onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => RssArticleListScreen(
                          source: source,
                          store: store,
                        ),
                      )),
                    );
                  },
                );
              },
            ),
    );
  }
}

/// 某个订阅源的文章列表。
class RssArticleListScreen extends StatefulWidget {
  const RssArticleListScreen({
    super.key,
    required this.source,
    required this.store,
  });

  final RssSource source;
  final RssStore store;

  @override
  State<RssArticleListScreen> createState() => _RssArticleListScreenState();
}

class _RssArticleListScreenState extends State<RssArticleListScreen> {
  List<RssArticle> _articles = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final articles = await fetchRssFeed(widget.source);
      if (!mounted) return;
      setState(() {
        _articles = articles;
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.source.name.isEmpty ? '订阅' : widget.source.name),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetryView(error: _error!, onRetry: _load)
              : _articles.isEmpty
                  ? const Center(child: Text('没有条目'))
                  : ListView.separated(
                      itemCount: _articles.length,
                      separatorBuilder: (_, i) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final article = _articles[i];
                        final read = widget.store.isRead(article.id);
                        return ListTile(
                          title: Text(
                            article.title.isEmpty ? article.link : article.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight:
                                  read ? FontWeight.normal : FontWeight.w600,
                              color: read
                                  ? theme.colorScheme.outline
                                  : theme.colorScheme.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            [
                              if (article.published.isNotEmpty) article.published,
                              if (article.summary.isNotEmpty) article.summary,
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () async {
                            final navigator = Navigator.of(context);
                            await widget.store.markRead(article.id);
                            if (!mounted) return;
                            await navigator.push(MaterialPageRoute(
                              builder: (_) => RssArticleScreen(article: article),
                            ));
                            if (mounted) setState(() {});
                          },
                        );
                      },
                    ),
    );
  }
}

/// 文章正文（HTML 转段落，复用阅读器的切段工具）。
class RssArticleScreen extends StatelessWidget {
  const RssArticleScreen({super.key, required this.article});

  final RssArticle article;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paragraphs = htmlToParagraphs(
      article.content.isEmpty ? article.summary : article.content,
    );
    return Scaffold(
      appBar: AppBar(title: Text(article.title, maxLines: 1)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          Text(article.title, style: theme.textTheme.titleLarge),
          if (article.published.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(article.published,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
          ],
          const SizedBox(height: 16),
          if (paragraphs.isEmpty)
            Text('（这条内容没有正文，可点下方链接打开原文）',
                style: theme.textTheme.bodyMedium)
          else
            for (final p in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(p, style: const TextStyle(height: 1.75)),
              ),
          if (article.link.isNotEmpty) ...[
            const SizedBox(height: 20),
            SelectableText('原文：${article.link}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.primary)),
          ],
        ],
      ),
    );
  }
}

