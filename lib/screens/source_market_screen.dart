import 'dart:async';
import 'dart:convert';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/sources/market_import.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_export.dart';
import '../core/sources/source_fetch.dart';
import '../core/sources/source_market.dart';
import '../core/sources/source_seed.dart';
import '../store/stores.dart';
import '../widgets/common.dart';

/// 源市场：从内置种子与用户清单里自动抓取可用影视源（带 TTFB/总耗时测速），
/// 勾选或一键 Top N 入库。
class SourceMarketScreen extends StatefulWidget {
  const SourceMarketScreen({super.key});

  @override
  State<SourceMarketScreen> createState() => _SourceMarketScreenState();
}

/// 结果筛选。
enum _ResultFilter {
  all('全部'),
  available('可用'),
  failed('失败'),
  cleartext('明文HTTP');

  const _ResultFilter(this.label);

  final String label;
}

/// 结果排序。
enum _ResultSort {
  latency('延迟'),
  sites('站点数'),
  name('名称');

  const _ResultSort(this.label);

  final String label;
}

/// 树里的一行。
class _Row {
  const _Row(this.node, this.depth);

  final MarketNode node;
  final int depth;
}

class _SourceMarketScreenState extends State<SourceMarketScreen> {
  final _scanner = MarketScanner();
  final _roots = <MarketNode>[];
  final _expanded = <String>{};
  final _selected = <String>{};
  final _seedStatus = <String, String>{};

  MarketStats _stats = const MarketStats.empty();
  bool _scanning = false;
  bool _importing = false;
  int _samples = 1;
  _ResultFilter _filter = _ResultFilter.all;
  _ResultSort _sort = _ResultSort.latency;
  StreamSubscription<MarketScanEvent>? _sub;
  CancelToken? _cancel;

  @override
  void dispose() {
    _cancel?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  // ---------------- 扫描 ----------------

  Future<void> _startScan(AppScope scope) async {
    final seeds = scope.seeds.enabled;
    if (seeds.isEmpty) {
      _snack('没有启用的种子，请先在「种子管理」里开启');
      return;
    }
    _cancel?.cancel();
    final cancel = _cancel = CancelToken();
    setState(() {
      _scanning = true;
      _roots.clear();
      _selected.clear();
      _seedStatus.clear();
      _expanded.clear();
      _stats = const MarketStats.empty();
    });
    await _sub?.cancel();
    _sub = _scanner
        .scanSeeds(
          seeds,
          cancel: cancel,
          samples: _samples,
          concurrency: scope.settings.scanConcurrency,
        )
        .listen((event) {
      if (!mounted) return;
      setState(() {
        switch (event) {
          case MarketSeedStarted():
            _seedStatus[event.seed.id] = '扫描中…';
          case MarketSeedDone():
            _seedStatus[event.seed.id] = event.error.isNotEmpty
                ? '失败：${event.error}'
                : '${event.nodeCount} 个配置';
          case MarketNodeScanned():
            _roots.add(event.node);
          // 旧版事件（`scan()` 入口）在这里不参与新界面渲染。
          case MarketSiteStarted():
          case MarketSiteDone():
          case MarketProbeProgress():
            break;
          case MarketScanDone():
            _roots
              ..clear()
              ..addAll(event.nodes);
            _stats = event.stats;
            _scanning = false;
            for (final root in event.nodes) {
              _expanded.add(root.id);
              for (final leaf in root.leaves()) {
                _selected.add(leaf.id);
              }
            }
            if (event.parses.isNotEmpty) {
              // ignore: discarded_futures
              scope.marketSites.setParses(event.parses);
            }
            if (event.lives.isNotEmpty) {
              // ignore: discarded_futures
              scope.lives.addCandidates(event.lives);
            }
        }
      });
    }, onDone: () {
      if (mounted) setState(() => _scanning = false);
    });
  }

  // ---------------- 导入 ----------------

  Future<void> _importSelected(AppScope scope) async {
    final nodes = _selectedNodes();
    if (nodes.isEmpty) {
      _snack('先勾选要入库的源');
      return;
    }
    await _import(scope, () => MarketImporter.importNodes(scope.sources, nodes));
  }

  Future<void> _importTop(AppScope scope, int count) async {
    await _import(
      scope,
      () => MarketImporter.importTopN(scope.sources, _roots, count),
    );
  }

  Future<void> _importAll(AppScope scope) async {
    await _import(
      scope,
      () => MarketImporter.importAll(scope.sources, _roots),
    );
  }

  Future<void> _import(
    AppScope scope,
    Future<ImportOutcome> Function() action,
  ) async {
    setState(() => _importing = true);
    try {
      final outcome = await action();
      if (!mounted) return;
      _snack(outcome.message);
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  List<MarketNode> _selectedNodes() {
    final out = <MarketNode>[];
    void walk(MarketNode node) {
      if (node.isMulti) {
        for (final child in node.children) {
          walk(child);
        }
        return;
      }
      if (_selected.contains(node.id) && node.available) out.add(node);
    }

    for (final root in _roots) {
      walk(root);
    }
    return out;
  }

  // ---------------- 导出 ----------------

  Future<void> _export(AppScope scope, SourceExportFormat format) async {
    final content = exportByFormat(
      format,
      _roots,
      sources: scope.sources.all,
    );
    if (content.trim().isEmpty) {
      _snack('没有可导出的内容，先扫描并导入一批源');
      return;
    }
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('复制到剪贴板'),
              onTap: () => Navigator.of(sheetContext).pop('copy'),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('保存为文件'),
              onTap: () => Navigator.of(sheetContext).pop('save'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null) return;
    if (action == 'copy') {
      await Clipboard.setData(ClipboardData(text: content));
      _snack('已复制 ${format.label}');
      return;
    }
    final location = await getSaveLocation(
      suggestedName: switch (format) {
        SourceExportFormat.sites => 'tvbox-sites.json',
        SourceExportFormat.multiRepo => 'tvbox-multi-repo.json',
        SourceExportFormat.plainList => 'source-urls.txt',
      },
    );
    if (location == null) return;
    final xfile = XFile.fromData(
      Uint8List.fromList(utf8.encode(content)),
      mimeType: 'application/json',
    );
    await xfile.saveTo(location.path);
    if (!mounted) return;
    _snack('已保存到 ${location.path}');
  }

  void _snack(String text) {
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------------- 构建 ----------------

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    final rows = _visibleRows();
    return Scaffold(
      appBar: AppBar(
        title: const Text('源市场'),
        actions: [
          IconButton(
            tooltip: '种子管理',
            icon: const Icon(Icons.tune),
            onPressed: () => _openSeeds(scope),
          ),
          PopupMenuButton<SourceExportFormat>(
            tooltip: '导出',
            icon: const Icon(Icons.ios_share),
            onSelected: (format) => _export(scope, format),
            itemBuilder: (context) => [
              for (final format in SourceExportFormat.values)
                PopupMenuItem(value: format, child: Text('导出：${format.label}')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: scope.settings.sourcesDisclaimerDismissed
                ? const SizedBox.shrink()
                : _DisclaimerBar(
                    onDismiss: () {
                      scope.settings.sourcesDisclaimerDismissed = true;
                      if (mounted) setState(() {});
                    },
                  ),
          ),
          _scanBar(theme, scope),
          if (_stats.nodes > 0) _statsBar(theme),
          const Divider(height: 1),
          Expanded(
            child: rows.isEmpty
                ? _emptyState(theme)
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: 120),
                    itemCount: rows.length,
                    itemBuilder: (context, index) =>
                        _nodeTile(rows[index], theme),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _stats.nodes == 0 ? null : _bottomBar(scope),
    );
  }

  Widget _scanBar(ThemeData theme, AppScope scope) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Row(
        children: [
          FilledButton.icon(
            onPressed: _scanning ? null : () => _startScan(scope),
            icon: Icon(_scanning ? Icons.hourglass_top : Icons.radar),
            label: Text(_scanning ? '扫描中…' : '开始扫描'),
          ),
          if (_scanning) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => _cancel?.cancel(),
              child: const Text('停止'),
            ),
          ],
          const Spacer(),
          DropdownButton<int>(
            value: _samples,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 1, child: Text('采样 1 次')),
              DropdownMenuItem(value: 2, child: Text('采样 2 次')),
              DropdownMenuItem(value: 3, child: Text('采样 3 次')),
            ],
            onChanged: _scanning
                ? null
                : (v) => setState(() => _samples = v ?? 1),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: scope.settings.scanConcurrency,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 4, child: Text('并发 4')),
              DropdownMenuItem(value: 8, child: Text('并发 8')),
              DropdownMenuItem(value: 12, child: Text('并发 12')),
              DropdownMenuItem(value: 24, child: Text('并发 24')),
              DropdownMenuItem(value: 32, child: Text('并发 32')),
            ],
            onChanged: _scanning
                ? null
                : (v) => setState(() {
                      if (v != null) scope.settings.scanConcurrency = v;
                    }),
          ),
        ],
      ),
    );
  }

  Widget _statsBar(ThemeData theme) {
    final text = '种子 ${_stats.seeds} · 已扫 ${_stats.scannedSeeds} · '
        '节点 ${_stats.nodes} · 可用 ${_stats.available} · '
        '平均 ${_stats.avgLatencyMs}ms';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.outline),
            ),
          ),
          if (_scanning)
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radar, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(
              '点「开始扫描」从内置 ${_stats.seeds == 0 ? 66 : _stats.seeds} 条种子里'
              '抓取可用影视源',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  /// 展平成可见行（只展开已折叠/展开过的节点）。
  List<_Row> _visibleRows() {
    final rows = <_Row>[];
    void walk(MarketNode node, int depth) {
      if (!_matches(node)) {
        // 多仓本身不匹配时，只要子节点可能匹配就继续下探。
        if (!node.isMulti || !node.children.any(_matchesDeep)) return;
      }
      rows.add(_Row(node, depth));
      if (!node.isMulti || !_expanded.contains(node.id)) return;
      final children = List<MarketNode>.of(node.children);
      switch (_sort) {
        case _ResultSort.latency:
          children.sort((a, b) => (a.bestLatencyMs ?? 1 << 30)
              .compareTo(b.bestLatencyMs ?? 1 << 30));
        case _ResultSort.sites:
          children.sort((a, b) => b.siteCount.compareTo(a.siteCount));
        case _ResultSort.name:
          children.sort((a, b) => a.name.compareTo(b.name));
      }
      for (final child in children) {
        walk(child, depth + 1);
      }
    }

    final roots = List<MarketNode>.of(_roots);
    switch (_sort) {
      case _ResultSort.latency:
        roots.sort((a, b) =>
            (a.bestLatencyMs ?? 1 << 30).compareTo(b.bestLatencyMs ?? 1 << 30));
      case _ResultSort.sites:
        roots.sort((a, b) => b.siteCount.compareTo(a.siteCount));
      case _ResultSort.name:
        roots.sort((a, b) => a.name.compareTo(b.name));
    }
    for (final root in roots) {
      walk(root, 0);
    }
    return rows;
  }

  bool _matchesDeep(MarketNode node) {
    if (_matches(node)) return true;
    if (!node.isMulti) return false;
    return node.children.any(_matchesDeep);
  }

  bool _matches(MarketNode node) => switch (_filter) {
        _ResultFilter.all => true,
        _ResultFilter.available => node.available,
        _ResultFilter.failed => !node.available,
        _ResultFilter.cleartext =>
          node.flags.contains(SecurityFlag.cleartextHttp),
      };

  Widget _nodeTile(_Row row, ThemeData theme) {
    final node = row.node;
    final ok = node.available;
    final canSelect = !node.isMulti && ok;
    final selected = _selected.contains(node.id);
    final scheme = theme.colorScheme;

    final metrics = <String>[
      if (node.ttfbMs != null) 'TTFB ${node.ttfbMs}ms',
      if (node.totalMs != null) '总 ${node.totalMs}ms',
      if (node.sizeKb != null) '${node.sizeKb!.toStringAsFixed(0)}KB',
      if (node.siteCount > 0) '${node.siteCount} 站',
    ].join(' · ');

    return InkWell(
      onTap: node.isMulti
          ? () => setState(() {
                if (!_expanded.remove(node.id)) _expanded.add(node.id);
              })
          : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12 + row.depth * 16.0, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (node.isMulti)
              Icon(
                _expanded.contains(node.id)
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 18,
                color: scheme.outline,
              )
            else
              SizedBox(
                width: 18,
                child: Icon(
                  ok ? Icons.check_circle : Icons.error_outline,
                  size: 14,
                  color: ok ? Colors.green : scheme.error,
                ),
              ),
            const SizedBox(width: 6),
            if (canSelect)
              SizedBox(
                width: 28,
                height: 28,
                child: Checkbox(
                  value: selected,
                  onChanged: (v) => setState(() {
                    if (v ?? false) {
                      _selected.add(node.id);
                    } else {
                      _selected.remove(node.id);
                    }
                  }),
                ),
              )
            else
              const SizedBox(width: 28),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          node.name.isEmpty ? node.url : node.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: node.isMulti
                                ? FontWeight.w600
                                : FontWeight.w400,
                            color: ok ? null : scheme.outline,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _Badge(text: node.isMulti ? node.shape.label : node.format.label),
                      for (final flag in node.flags)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: _Badge(
                            text: flag.label,
                            color: flag == SecurityFlag.cleartextHttp
                                ? scheme.error
                                : null,
                          ),
                        ),
                    ],
                  ),
                  if (metrics.isNotEmpty)
                    Text(
                      metrics,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.outline),
                    )
                  else
                    Text(
                      node.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.outline),
                    ),
                  if (!ok && node.error.isNotEmpty)
                    Text(
                      node.error,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(AppScope scope) {
    final availableCount = _selectedNodes().length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            PopupMenuButton<_ResultSort>(
              tooltip: '排序',
              initialValue: _sort,
              onSelected: (value) => setState(() => _sort = value),
              itemBuilder: (context) => [
                for (final sort in _ResultSort.values)
                  PopupMenuItem(value: sort, child: Text('排序：${sort.label}')),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.sort, size: 18),
                  const SizedBox(width: 4),
                  Text(_sort.label),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final filter in _ResultFilter.values)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label: Text(filter.label),
                          selected: _filter == filter,
                          onSelected: (_) => setState(() => _filter = filter),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            TextButton(
              onPressed: availableCount == 0
                  ? null
                  : () => setState(() {
                        _selected.addAll(_selectedNodes().map((n) => n.id));
                      }),
              child: Text('已选 $availableCount'),
            ),
            PopupMenuButton<int>(
              tooltip: '一键导入',
              enabled: !_importing,
              onSelected: (count) =>
                  count > 0 ? _importTop(scope, count) : _importAll(scope),
              itemBuilder: (context) => const [
                PopupMenuItem(value: 5, child: Text('导入延迟最低的 5 条')),
                PopupMenuItem(value: 10, child: Text('导入延迟最低的 10 条')),
                PopupMenuItem(value: 20, child: Text('导入延迟最低的 20 条')),
                PopupMenuItem(value: 50, child: Text('导入延迟最低的 50 条')),
                PopupMenuDivider(),
                PopupMenuItem(value: 0, child: Text('导入全部可用单仓')),
              ],
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8),
                child: Icon(Icons.bolt),
              ),
            ),
            FilledButton(
              onPressed: _importing ? null : () => _importSelected(scope),
              child: Text(_importing ? '导入中…' : '入库所选'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- 种子管理 ----------------

  Future<void> _openSeeds(AppScope scope) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.85,
        child: _SeedSheet(store: scope.seeds, status: _seedStatus),
      ),
    );
    if (mounted) setState(() {});
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = color ?? theme.colorScheme.outline;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        border: Border.all(color: base.withValues(alpha: 0.5), width: 0.8),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(color: base, fontSize: 9),
      ),
    );
  }
}

class _DisclaimerBar extends StatelessWidget {
  const _DisclaimerBar({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline,
              size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '内置的是接口清单地址，内容源由扫描产生；扫描只在你点开始时联网。',
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            tooltip: '不再提示',
            icon: const Icon(Icons.close, size: 16),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}

/// 种子管理面板。
class _SeedSheet extends StatefulWidget {
  const _SeedSheet({required this.store, required this.status});

  final SeedStore store;
  final Map<String, String> status;

  @override
  State<_SeedSheet> createState() => _SeedSheetState();
}

class _SeedSheetState extends State<_SeedSheet> {
  SeedKind _kind = SeedKind.line;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final theme = Theme.of(context);
        final seeds = widget.store.byKind(_kind);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('种子管理', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  TextButton(
                    onPressed: widget.store.restoreBuiltin,
                    child: const Text('恢复预置'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (final kind in SeedKind.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(
                            '${kind.label} ${widget.store.byKind(kind).length}'),
                        selected: _kind == kind,
                        onSelected: (_) => setState(() => _kind = kind),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                itemCount: seeds.length,
                itemBuilder: (context, index) {
                  final seed = seeds[index];
                  final enabled = widget.store.isEnabled(seed.id);
                  final status = widget.status[seed.id];
                  return CheckboxListTile(
                    value: enabled,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(seed.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      status == null ? seed.url : '${seed.url}\n$status',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: status?.startsWith('失败') == true
                            ? theme.colorScheme.error
                            : theme.colorScheme.outline,
                      ),
                    ),
                    secondary: IconButton(
                      tooltip: '删除',
                      icon: const Icon(Icons.delete_outline, size: 18),
                      onPressed: () => widget.store.remove(seed.id),
                    ),
                    onChanged: (v) =>
                        widget.store.setEnabled(seed.id, v ?? false),
                  );
                },
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '共 ${widget.store.seeds.length} 条'
                        '${widget.store.hiddenCount > 0 ? '（已隐藏 ${widget.store.hiddenCount} 条内置）' : ''}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    FilledButton.tonalIcon(
                      onPressed: () => _addSeed(context),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('新增'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _addSeed(BuildContext context) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    var kind = SeedKind.line;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('新增种子'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: urlController,
                decoration: const InputDecoration(labelText: '地址（http/https）'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<SeedKind>(
                showSelectedIcon: false,
                segments: [
                  for (final value in SeedKind.values)
                    ButtonSegment(value: value, label: Text(value.label)),
                ],
                selected: {kind},
                onSelectionChanged: (values) =>
                    setDialogState(() => kind = values.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );
    final name = nameController.text.trim();
    final url = urlController.text.trim();
    nameController.dispose();
    urlController.dispose();
    if (ok != true || url.isEmpty) return;
    await widget.store.add(name, url, kind);
    if (mounted) setState(() => _kind = kind);
  }
}
