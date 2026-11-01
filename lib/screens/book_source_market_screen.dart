import 'dart:async';

import 'package:flutter/material.dart';

import '../core/books/book_source_market.dart';
import '../core/books/book_source_model.dart';
import '../core/books/book_source_seed.dart';
import '../core/books/book_source_store.dart';
import '../widgets/common.dart';

/// 书源仓库：扫描内置种子 → 逐源三连校验（搜书/详情/目录）→ 勾选导入。
///
/// 对齐影视 `source_market` 的体验，但书源种子是扁平 feed（无多仓树），故精简为
/// 「种子状态 + 逐源结果 + 勾选/一键导入可用」。可达性预检即扫描本身（抓不到=失败）。
class BookSourceMarketScreen extends StatefulWidget {
  const BookSourceMarketScreen({super.key});

  @override
  State<BookSourceMarketScreen> createState() => _BookSourceMarketScreenState();
}

class _BookSourceMarketScreenState extends State<BookSourceMarketScreen> {
  // 校验用的测试关键词：选一本几乎所有小说站都收的热门书名。
  static const _query = '斗破';

  final _market = BookSourceMarket();
  final _results = <BookSourceCheck>[];
  final _seedStatus = <String, String>{};
  final _selected = <String>{}; // 勾选的书源 url
  BookMarketStats _stats = const BookMarketStats();
  StreamSubscription<BookMarketEvent>? _sub;
  bool _scanning = false;
  bool _importing = false;
  bool _cancel = false;

  BookSourceStore get _store => AppScope.read(context).bookSources;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
  }

  @override
  void dispose() {
    _cancel = true;
    _sub?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _scanning = true;
      _cancel = false;
      _results.clear();
      _selected.clear();
      _seedStatus.clear();
      _stats = const BookMarketStats();
    });
    _sub?.cancel();
    final concurrency = AppScope.read(context).settings.scanConcurrency;
    _sub = _market
        .scan(
            seeds: builtinBookSeeds,
            query: _query,
            cancel: () => _cancel,
            concurrency: concurrency)
        .listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case BookSeedStarted(:final seed):
            _seedStatus[seed.id] = '扫描中…';
          case BookSeedFailed(:final seed, :final error):
            _seedStatus[seed.id] = '失败：$error';
          case BookSeedParsed(:final seed, :final sourceCount):
            _seedStatus[seed.id] = '$sourceCount 源';
          case BookSourceChecked(:final check):
            _results.add(check);
            if (check.ok) _selected.add(check.source.url); // 默认可用即勾上
          case BookScanDone(:final stats):
            _stats = stats;
            _scanning = false;
        }
      });
    }, onError: (Object _) {
      if (mounted) setState(() => _scanning = false);
    });
  }

  void _stop() {
    _cancel = true;
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _import() async {
    final chosen =
        _results.where((c) => _selected.contains(c.source.url)).toList();
    if (chosen.isEmpty) {
      _snack('没有勾选任何书源');
      return;
    }
    setState(() => _importing = true);
    final added = await _store
        .importAll([for (final c in chosen) c.source.copyWithEnabled(c.ok)]);
    if (!mounted) return;
    setState(() => _importing = false);
    Navigator.pop(context);
    _snack('导入 $added 个书源（可用即启用，失败源已导入但停用）');
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _seedChip(BookSeed seed) {
    final st = _seedStatus[seed.id] ?? '待扫描';
    return Chip(
      label: Text('${seed.name}：$st'),
      visualDensity: VisualDensity.compact,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源仓库'),
        actions: [
          if (_scanning)
            TextButton(onPressed: _stop, child: const Text('停止'))
          else
            TextButton(
                onPressed: _importing ? null : _start, child: const Text('开始扫描')),
          TextButton(
            onPressed: (_importing || _selected.isEmpty) ? null : _import,
            child: Text('导入(${_selected.length})'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: Text(
              '种子 ${_stats.seeds}/${builtinBookSeeds.length} · '
              '书源 ${_stats.sources} · 可用 ${_stats.ok}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          if (_seedStatus.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final seed in builtinBookSeeds) _seedChip(seed),
                ],
              ),
            ),
          const Divider(height: 16),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: _scanning
                        ? const CircularProgressIndicator()
                        : Text('点「开始扫描」从内置 ${builtinBookSeeds.length} 个种子抓取可用书源',
                            style: theme.textTheme.bodyMedium))
                : ListView.builder(
                    itemCount: _results.length,
                    itemBuilder: (context, i) {
                      final c = _results[i];
                      final name = c.source.name.isEmpty ? c.source.url : c.source.name;
                      return CheckboxListTile(
                        dense: true,
                        value: _selected.contains(c.source.url),
                        onChanged: (v) => setState(() {
                          if (v == true) {
                            _selected.add(c.source.url);
                          } else {
                            _selected.remove(c.source.url);
                          }
                        }),
                        title: Text(name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          c.ok
                              ? '可用 · ${c.sampleChapterCount} 章'
                              : '${c.stage.name}：${c.reason}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: c.ok
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.error),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
