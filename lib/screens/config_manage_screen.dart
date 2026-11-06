import 'dart:async';

import 'package:flutter/material.dart';

import '../core/ops_switches.dart';
import '../core/sources/auto_source_manager.dart';
import '../core/sources/merged_source.dart';
import '../core/sources/source_import.dart';
import '../core/sources/source_seed.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/loading.dart';

/// 配置地址管理：自动找源状态 + 本地合并源 + 配置地址列表。
///
/// 与「源管理」的区别：源管理管的是**已经导入的站点**，这里管的是
/// **配置地址（种子）** —— 哪些地址参与扫描、上次验证是否可用、谁由自动找源维护。
class ConfigManageScreen extends StatefulWidget {
  const ConfigManageScreen({super.key});

  @override
  State<ConfigManageScreen> createState() => _ConfigManageScreenState();
}

enum _ConfigFilter { all, usable, dead, auto }

class _ConfigManageScreenState extends State<ConfigManageScreen> {
  final MergedSourceStore _mergedStore = MergedSourceStore();
  MergedSnapshotInfo? _mergedInfo;
  bool _rebuilding = false;
  bool _importing = false;
  _ConfigFilter _filter = _ConfigFilter.all;

  @override
  void initState() {
    super.initState();
    _loadMergedInfo();
  }

  Future<void> _loadMergedInfo() async {
    final info = await _mergedStore.info();
    if (!mounted) return;
    setState(() => _mergedInfo = info);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);
    final entries = scope.discovery.entries;
    final seeds = scope.seeds.seeds;
    final filtered = seeds.where((seed) {
      final entry = entries[normalizeSeedUrl(seed.url)];
      return switch (_filter) {
        _ConfigFilter.all => true,
        _ConfigFilter.usable => entry?.usable ?? false,
        _ConfigFilter.dead => entry != null && !entry.usable,
        _ConfigFilter.auto => entry?.auto ?? false,
      };
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('配置地址管理'),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () {
              setState(() {});
              _loadMergedInfo();
            },
          ),
          IconButton(
            tooltip: '恢复预置',
            icon: const Icon(Icons.restore),
            onPressed: () async {
              await scope.seeds.restoreBuiltin();
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '新增配置地址',
            icon: const Icon(Icons.add),
            onPressed: () => _addConfig(scope),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _AutoSourceCard(scope: scope),
          const Divider(height: 1),
          _MergedSourceTile(
            info: _mergedInfo,
            rebuilding: _rebuilding,
            importing: _importing,
            onRebuild: () => _rebuildMerged(scope),
            onImport: () => _importMerged(scope),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Row(
              children: [
                Text('配置地址', style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  '共 ${seeds.length} 条',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 42,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final (value, label) in <(_ConfigFilter, String)>[
                  (_ConfigFilter.all, '全部'),
                  (_ConfigFilter.usable, '可用'),
                  (_ConfigFilter.dead, '失效'),
                  (_ConfigFilter.auto, '自动'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _filter == value,
                      onSelected: (_) => setState(() => _filter = value),
                    ),
                  ),
              ],
            ),
          ),
          if (filtered.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _filter == _ConfigFilter.all
                    ? '还没有配置地址，点右上角新增，或先运行一次自动找源。'
                    : '没有符合筛选条件的配置地址。',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
            )
          else
            for (final seed in filtered)
              _ConfigTile(
                seed: seed,
                entry: entries[normalizeSeedUrl(seed.url)],
                enabled: scope.seeds.isEnabled(seed.id),
                onToggle: (value) async {
                  await scope.seeds.setEnabled(seed.id, value);
                  if (mounted) setState(() {});
                },
                onDelete: () async {
                  await scope.seeds.remove(seed.id);
                  if (mounted) setState(() {});
                },
              ),
        ],
      ),
    );
  }

  Future<void> _rebuildMerged(AppScope scope) async {
    if (_rebuilding) return;
    setState(() => _rebuilding = true);
    final result = MergedSourceBuilder.build(
      scope.sources.enabled,
      parses: scope.marketSites.parses,
    );
    var ok = false;
    if (result.ok) {
      ok = await _mergedStore.write(result.json);
      if (ok) await scope.discovery.markMerged(result.siteCount);
    }
    await _loadMergedInfo();
    if (!mounted) return;
    setState(() => _rebuilding = false);
    _snack(ok
        ? '已重建合并源：${result.siteCount} 个站点'
            '${result.duplicates > 0 ? '（去重 ${result.duplicates}）' : ''}'
        : (result.message.isEmpty ? '重建失败，已保留旧文件' : result.message));
  }

  Future<void> _importMerged(AppScope scope) async {
    if (_importing) return;
    final text = await _mergedStore.read();
    if (text == null || text.trim().isEmpty) {
      _snack('还没有合并源文件，请先重建');
      return;
    }
    setState(() => _importing = true);
    try {
      final report = await SourceImporter.importFromText(
        text,
        sourceUrl: mergedSourceUrl,
      );
      final added = await scope.sources.addCandidates(report.added);
      if (report.parses.isNotEmpty) {
        await scope.marketSites.addParses(report.parses);
      }
      _snack(added > 0
          ? '已从合并源导入 $added 个站点'
          : '合并源里的站点都已存在');
    } catch (e) {
      _snack('导入失败：$e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  Future<void> _addConfig(AppScope scope) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    var kind = SeedKind.line;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('新增配置地址'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              TextField(
                controller: urlController,
                decoration:
                    const InputDecoration(labelText: '地址（http/https）'),
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
    await scope.seeds.add(name, url, kind);
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

/// 自动找源面板：开关 + 状态 + Token + 立即运行。
class _AutoSourceCard extends StatefulWidget {
  const _AutoSourceCard({required this.scope});

  final AppScope scope;

  @override
  State<_AutoSourceCard> createState() => _AutoSourceCardState();
}

class _AutoSourceCardState extends State<_AutoSourceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final settings = widget.scope.settings;
    final manager = widget.scope.autoSource;
    return ValueListenableBuilder<AutoSourceState>(
      valueListenable: manager.state,
      builder: (context, state, _) {
        final discovery = widget.scope.discovery;
        return ExpansionTile(
          initiallyExpanded: _expanded,
          onExpansionChanged: (value) => setState(() => _expanded = value),
          leading: Icon(
            Icons.travel_explore,
            color: settings.autoDiscovery
                ? theme.colorScheme.primary
                : theme.colorScheme.outline,
          ),
          title: const Text('自动找源'),
          subtitle: Text(
            state.running
                ? (state.message.isEmpty ? '正在找源…' : state.message)
                : discovery.statusText,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          children: [
            SwitchListTile(
              value: settings.autoDiscovery,
              title: const Text('后台自动发现'),
              subtitle: Text(
                OpsSwitches.disableAutoSource
                    ? '运维急停已停用（app_ops.yaml）'
                    : 'GitHub / GitLab / Gitee 定时发现并验证配置；关闭后不再联网',
              ),
              onChanged: OpsSwitches.disableAutoSource
                  ? null
                  : (value) {
                      settings.autoDiscovery = value;
                      manager.rescheduleOnSettingsChanged();
                      setState(() {});
                    },
            ),
            ListTile(
              dense: true,
              title: const Text('GitHub Token（可选）'),
              subtitle: Text(
                settings.githubToken.isEmpty
                    ? '未配置：匿名调用，可能提前触发限流'
                    : '已配置：${_mask(settings.githubToken)}',
              ),
              trailing: const Icon(Icons.edit_outlined, size: 18),
              onTap: () => _editToken(context),
            ),
            ListTile(
              dense: true,
              title: const Text('下次运行'),
              subtitle: Text(_nextRunText(state.nextRunAt)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: state.running
                          ? null
                          : () async {
                              await manager.runNow();
                              if (mounted) setState(() {});
                            },
                      icon: state.running
                          ? const AppLoading.inline()
                          : const Icon(Icons.play_arrow),
                      label: Text(state.running ? '找源中…' : '立即找源'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '可用 ${discovery.all.where((e) => e.usable).length} 条',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  static String _mask(String token) {
    if (token.length <= 8) return '****';
    return '${token.substring(0, 4)}…${token.substring(token.length - 4)}';
  }

  static String _nextRunText(DateTime? at) {
    if (at == null) return '已关闭自动发现';
    final diff = at.difference(DateTime.now());
    if (diff.isNegative) return '即将运行';
    final minutes = diff.inMinutes;
    if (minutes < 1) return '不到 1 分钟后';
    if (minutes < 60) return '$minutes 分钟后';
    return '${diff.inHours} 小时后';
  }

  Future<void> _editToken(BuildContext context) async {
    final controller =
        TextEditingController(text: widget.scope.settings.githubToken);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('GitHub Token'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'ghp_…（留空恢复匿名）',
            helperText: '只保存在本机，用于提高 GitHub 搜索 API 限额',
          ),
          obscureText: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final value = controller.text;
    controller.dispose();
    if (ok != true) return;
    widget.scope.settings.githubToken = value;
    if (mounted) setState(() {});
  }
}

/// 本地合并源：配置列表第一行。
class _MergedSourceTile extends StatelessWidget {
  const _MergedSourceTile({
    required this.info,
    required this.rebuilding,
    required this.importing,
    required this.onRebuild,
    required this.onImport,
  });

  final MergedSnapshotInfo? info;
  final bool rebuilding;
  final bool importing;
  final VoidCallback onRebuild;
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = info;
    return ListTile(
      leading: Icon(Icons.merge, color: theme.colorScheme.primary),
      title: Row(
        children: [
          const Text(mergedSourceName),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '默认',
              style: TextStyle(
                fontSize: 10,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
          ),
        ],
      ),
      subtitle: Text(
        snapshot == null
            ? mergedSourceUrl
            : '$mergedSourceUrl · ${snapshot.siteCount} 个站点 · '
                '${_timeText(snapshot.builtAt)}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '重建',
            icon: rebuilding
                ? const AppLoading.inline()
                : const Icon(Icons.build_outlined),
            onPressed: rebuilding ? null : onRebuild,
          ),
          IconButton(
            tooltip: '导入到源列表',
            icon: importing
                ? const AppLoading.inline()
                : const Icon(Icons.download_outlined),
            onPressed: importing ? null : onImport,
          ),
        ],
      ),
    );
  }

  static String _timeText(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

/// 单条配置地址。
class _ConfigTile extends StatelessWidget {
  const _ConfigTile({
    required this.seed,
    required this.entry,
    required this.enabled,
    required this.onToggle,
    required this.onDelete,
  });

  final SourceSeed seed;
  final DiscoveryEntry? entry;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = _statusText(theme);
    return ListTile(
      dense: true,
      leading: Checkbox(
        value: enabled,
        onChanged: (value) => onToggle(value ?? false),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              seed.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: enabled ? null : theme.colorScheme.outline,
              ),
            ),
          ),
          if (seed.builtin)
            _Badge(text: '内置', color: theme.colorScheme.outline)
          else if (entry?.auto == true)
            _Badge(text: '自动', color: theme.colorScheme.primary),
        ],
      ),
      subtitle: Text(
        '${seed.url}${status.isEmpty ? '' : ' · $status'}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall?.copyWith(
          color: entry != null && !(entry?.usable ?? false)
              ? theme.colorScheme.error
              : theme.colorScheme.outline,
        ),
      ),
      trailing: IconButton(
        tooltip: '删除',
        icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: onDelete,
      ),
    );
  }

  String _statusText(ThemeData theme) {
    final value = entry;
    if (value == null) return '未验证';
    if (!value.usable) {
      return value.message.isEmpty ? '失效' : '失效：${value.message}';
    }
    final parts = <String>[
      '可用 ${value.siteCount} 站',
      if (value.latencyMs > 0) '${value.latencyMs}ms',
      value.origin.label,
    ];
    return parts.join(' · ');
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
      margin: const EdgeInsets.only(left: 6),
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
