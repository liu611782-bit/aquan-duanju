import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/sources/cms_json_adapter.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_checker.dart';
import '../core/sources/source_import.dart';
import '../core/sources/qr_share_server.dart';
import '../core/sources/source_probe.dart';
import '../core/sources/source_registry.dart';
import '../widgets/common.dart';
import 'source_market_screen.dart';

/// 源管理：增删改查 / 开关 / 钉选 / 排序 / 单源检测 / 导入导出 / 清缓存。
class SourceManageScreen extends StatefulWidget {
  const SourceManageScreen({super.key});

  @override
  State<SourceManageScreen> createState() => _SourceManageScreenState();
}

class _SourceManageScreenState extends State<SourceManageScreen> {
  /// 单源测速/检测状态：sourceId → 展示文本。
  final Map<String, ProbeOutcome?> _probe = {};
  final Map<String, String> _checkText = {};
  final Set<String> _probing = {};
  bool _probingAll = false;

  /// 测完重排后回到顶部：好源在最上面，不用再自己往下找。
  final ScrollController _listController = ScrollController();

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final health = scope.sourceHealth;
    final sorted = sortSourcesForDisplay(
      scope.sources.all,
      scoreOf: (s) => health.scoreOf(s.id),
      latencyOf: (s) => health.latencyOf(s.id),
      // 批量测速进行中不重排（只更新行内结果文本），测完一次性重排。
      // 边测边重排会让列表在用户眼皮底下反复跳动（MoonTVPlus 同款门控）。
      // 结论存在 SourceHealthStore 里：back 回影视聚合后排序口径不变。
      probeOf: _probingAll ? null : (s) => health.probeOf(s.id),
    );
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('源管理'),
        actions: [
          IconButton(
            tooltip: '源市场（自动扫描抓源）',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SourceMarketScreen()));
              if (mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '批量测速',
            icon: Icon(_probingAll ? Icons.hourglass_top : Icons.speed),
            onPressed: _probingAll ? null : () => _probeAll(sorted),
          ),
          IconButton(
            tooltip: '导入',
            icon: const Icon(Icons.download),
            onPressed: () => _importDialog(scope),
          ),
          IconButton(
            tooltip: '扫码导入（手机粘贴提交）',
            icon: const Icon(Icons.qr_code_scanner),
            onPressed: () => _showQrImport(context, scope),
          ),
          IconButton(
            tooltip: '导出到手机',
            icon: const Icon(Icons.share_outlined),
            onPressed: () => _showQrExport(context, scope),
          ),
          IconButton(
            tooltip: '导出',
            icon: const Icon(Icons.upload),
            onPressed: () => _exportDialog(scope),
          ),
        ],
      ),
      body: sorted.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('还没有源',
                      style: TextStyle(color: theme.colorScheme.outline)),
                  const SizedBox(height: 8),
                  Text('去「源市场」扫描抓源，或点右上角导入',
                      style: TextStyle(color: theme.colorScheme.outline)),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () async {
                      await Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => const SourceMarketScreen()));
                      if (mounted) setState(() {});
                    },
                    icon: const Icon(Icons.storefront_outlined),
                    label: const Text('去源市场'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              controller: _listController,
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: sorted.length,
              itemBuilder: (context, index) {
                final s = sorted[index];
                final probe = _probe[s.id];
                final check = _checkText[s.id];
                return ListTile(
                  leading: s.kind == SourceKind.spider
                      ? const Icon(Icons.bug_report_outlined)
                      : const Icon(Icons.live_tv),
                  title: Row(
                    children: [
                      Expanded(
                        child: Text(s.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                      if (s.shortDrama)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('短剧',
                              style: TextStyle(
                                  fontSize: 10,
                                  color: theme.colorScheme.onPrimaryContainer)),
                        ),
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.api,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      if (_probing.contains(s.id))
                        const Text('测速中…'),
                      if (probe != null) _probeText(probe, theme),
                      if (check != null) Text(check, style: theme.textTheme.bodySmall),
                      if (health.coolingDown(s.id))
                        Text('冷却中（近期失败）',
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.error)),
                    ],
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) async {
                      switch (action) {
                        case 'probe':
                          _probeOne(scope, s);
                        case 'check':
                          await _checkOne(scope, s);
                        case 'pin':
                          await scope.sources.togglePinned(s.id);
                        case 'up':
                          final ids = [
                            for (final x in sorted) x.id,
                          ];
                          if (index > 0) {
                            final tmp = ids[index - 1];
                            ids[index - 1] = ids[index];
                            ids[index] = tmp;
                            await scope.sources.reorder(ids);
                          }
                        case 'edit':
                          await _editDialog(scope, s);
                        case 'remove':
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (context) => AlertDialog(
                              title: Text('删除「${s.name}」？'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('删除')),
                              ],
                            ),
                          );
                          if (ok ?? false) await scope.sources.remove(s.id);
                      }
                      if (mounted) setState(() {});
                    },
                    itemBuilder: (context) => [
                      const PopupMenuItem(
                          value: 'probe', child: Text('测速')),
                      const PopupMenuItem(
                          value: 'check', child: Text('站点自检')),
                      PopupMenuItem(
                          value: 'pin',
                          child: Text(s.pinned ? '取消钉选' : '钉选置顶')),
                      const PopupMenuItem(value: 'up', child: Text('上移')),
                      const PopupMenuItem(
                          value: 'edit', child: Text('编辑')),
                      const PopupMenuItem(
                          value: 'remove', child: Text('删除')),
                    ],
                  ),
                  isThreeLine: true,
                );
              },
            ),
    );
  }

  Widget _probeText(ProbeOutcome probe, ThemeData theme) {
    final style = theme.textTheme.bodySmall;
    return switch (probe.state) {
      ProbeState.ok => Text(
          '连接成功 ${probe.latencyMs}ms',
          style: style?.copyWith(
            color: switch (probeLevel(probe.latencyMs ?? 9999)) {
              ProbeLevel.fast => Colors.green,
              ProbeLevel.normal => Colors.orange,
              ProbeLevel.slow => Colors.red,
            },
          ),
        ),
      ProbeState.timeout =>
        Text('超时', style: style?.copyWith(color: theme.colorScheme.error)),
      ProbeState.failed => Text('失败：${probe.reason}',
          style: style?.copyWith(color: theme.colorScheme.error)),
    };
  }

  /// 主动测速也是一次真实命中：成功写延迟，失败写原因，健康分才有区分度。
  ///
  /// 爬虫源恒返回失败（需 JVM 引擎），写进去会让它永久垫底并进入冷却，故跳过；
  /// 其余方言（cmsJson / cmsXml / spiderJs）都记，测速排序才对所有源一致。
  Future<void> _recordProbeHealth(
      AppScope scope, SourceKind? kind, ProbeOutcome outcome) async {
    if (kind == null || kind == SourceKind.spider) return;
    scope.sourceHealth.rememberProbe(outcome);
    if (outcome.isOk) {
      await scope.sourceHealth.recordSuccess(
          outcome.sourceId, outcome.latencyMs ?? 0);
    } else {
      await scope.sourceHealth
          .recordFailure(outcome.sourceId, outcome.reason);
    }
  }

  Future<void> _probeOne(AppScope scope, SourceConfig s) async {
    // 测速是网络调用，短则几百毫秒长则超时：先给「测速中」反馈，
    // 否则用户点了行内菜单看不到任何动静（「点测试没有反应」的主诉）。
    setState(() => _probing.add(s.id));
    try {
      final outcome = await probeSource(s,
          timeout: Duration(milliseconds: scope.settings.sourcesProbeTimeoutMs));
      await _recordProbeHealth(scope, s.kind, outcome);
      if (!mounted) return;
      setState(() {
        _probing.remove(s.id);
        _probe[s.id] = outcome;
      });
    } catch (_) {
      if (mounted) setState(() => _probing.remove(s.id));
    }
  }

  Future<void> _probeAll(List<SourceConfig> sources) async {
    setState(() => _probingAll = true);
    final scope = AppScope.read(context);
    final kinds = {for (final s in sources) s.id: s.kind};
    var ok = 0;
    var timeout = 0;
    var failed = 0;
    await for (final e in probeSources(sources,
        timeout: Duration(milliseconds: scope.settings.sourcesProbeTimeoutMs))) {
      if (e is ProbeProgress) {
        await _recordProbeHealth(scope, kinds[e.outcome.sourceId], e.outcome);
        if (e.outcome.state == ProbeState.ok) {
          ok++;
        } else if (e.outcome.state == ProbeState.timeout) {
          timeout++;
        } else {
          failed++;
        }
        if (!mounted) return;
        setState(() => _probe[e.outcome.sourceId] = e.outcome);
      }
    }
    if (!mounted) return;
    // 全部测完才重排（此时 probeOf 生效），并回到顶部让最快的源直接可见。
    setState(() => _probingAll = false);
    if (_listController.hasClients) _listController.jumpTo(0);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text('测速完成：$ok 成功 / $timeout 超时 / $failed 失败，已按速度排序'),
      duration: const Duration(seconds: 3),
    ));
  }

  Future<void> _checkOne(AppScope scope, SourceConfig s) async {
    if (s.kind == SourceKind.spider) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
          content: Text('爬虫源暂不支持自检（需桌面爬虫引擎）')));
      return;
    }
    setState(() => _checkText[s.id] = '自检中…');
    final result = await checkSource(CmsJsonAdapter(s));
    if (!mounted) return;
    setState(() => _checkText[s.id] = result.friendlyText);
  }

  Future<void> _importDialog(AppScope scope) async {
    final controller = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导入源'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '支持 TVBox 配置 / MoonTV / 多仓 / Base64 / 「名称|地址」文本行。'
                '内容由第三方提供，请自行确认授权与合法性。',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                maxLines: 6,
                decoration: const InputDecoration(
                  hintText: '粘贴配置文本或接口地址（http://…）',
                  border: OutlineInputBorder(),
                ),
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
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;
    final text = controller.text.trim();
    if (text.isEmpty) return;

    final report = text.startsWith('http://') || text.startsWith('https://')
        ? await SourceImporter.importFromUrl(text)
        : await SourceImporter.importFromText(text);
    if (!mounted) return;
    final added = await scope.sources.addCandidates(report.added);
    if (report.lives.isNotEmpty) {
      await scope.lives.addCandidates(report.lives);
    }
    if (report.parses.isNotEmpty) {
      await scope.marketSites.addParses(report.parses);
    }
    if (!mounted) return;
    final problems = report.failed.length + report.skipped.length;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(
          '导入完成：新增 $added，跳过 ${report.skipped.length}，失败 ${report.failed.length}'
          '${problems > 0 ? '（详情见错误日志）' : ''}'),
    ));
  }

  /// 扫码导入：桌面生成一次性二维码，手机浏览器粘贴配置提交。
  Future<void> _showQrImport(BuildContext context, AppScope scope) async {
    final server = QrShareServer();
    String status = '正在生成二维码…';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final messenger = ScaffoldMessenger.maybeOf(context);
          Future<void> run() async {
            server.onSubmit = (text) async {
              if (!dialogContext.mounted) return;
              Navigator.of(dialogContext).pop();
              final report = await SourceImporter.importFromText(text);
              final added = await scope.sources.addCandidates(report.added);
              if (report.lives.isNotEmpty) {
                await scope.lives.addCandidates(report.lives);
              }
              if (report.parses.isNotEmpty) {
                await scope.marketSites.addParses(report.parses);
              }
              if (!mounted) return;
              setState(() {});
              messenger?.showSnackBar(SnackBar(
                content: Text('扫码导入完成：新增 $added 个点播源、'
                    '${report.lives.length} 个直播配置'),
              ));
            };
            final url = await server.start();
            if (!mounted) return;
            _qrUrl = url;
            setDialogState(() => status = '手机扫码，在浏览器里粘贴配置提交（5 分钟内有效）');
            Future.delayed(const Duration(minutes: 5), () {
              if (mounted) setDialogState(() => status = '二维码已过期，请重新打开');
            });
          }

          if (status.startsWith('正在生成')) {
            WidgetsBinding.instance.addPostFrameCallback((_) => run());
          }
          return AlertDialog(
            title: const Text('扫码导入配置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: status.startsWith('正在生成') ? ' ' : _qrUrl ?? ' ',
                    size: 200,
                  ),
                ),
                const SizedBox(height: 12),
                Text(status, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
    await server.stop();
  }

  String? _qrUrl;

  /// 导出到手机：生成含当前配置的二维码，手机浏览器查看/复制/下载。
  Future<void> _showQrExport(BuildContext context, AppScope scope) async {
    final sources = scope.sources.all;
    if (sources.isEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('还没有可导出的源')));
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      'sites': [
        for (final s in sources)
          {
            'key': s.id,
            'name': s.name,
            'type': s.kind == SourceKind.cmsXml ? 0 : 1,
            'api': s.api,
            if (s.headers.isNotEmpty) 'header': s.headers,
          },
      ],
      'lives': [
        for (final l in scope.lives.all)
          {'name': l.name, 'url': l.url},
      ],
    });
    final server = QrShareServer();
    String status = '正在生成二维码…';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          Future<void> run() async {
            final url = await server.startExport(json);
            if (!mounted) return;
            _qrUrl = url;
            setDialogState(() => status = '手机扫码查看/复制/下载（5 分钟内有效）');
            Future.delayed(const Duration(minutes: 5), () {
              if (mounted) setDialogState(() => status = '二维码已过期，请重新打开');
            });
          }

          if (status.startsWith('正在生成')) {
            WidgetsBinding.instance.addPostFrameCallback((_) => run());
          }
          return AlertDialog(
            title: const Text('导出到手机'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  color: Colors.white,
                  child: QrImageView(
                    data: status.startsWith('正在生成') ? ' ' : _qrUrl ?? ' ',
                    size: 200,
                  ),
                ),
                const SizedBox(height: 12),
                Text(status, textAlign: TextAlign.center),
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('关闭')),
            ],
          );
        },
      ),
    );
    await server.stop();
  }

  Future<void> _exportDialog(AppScope scope) async {
    final sources = scope.sources.all;
    if (sources.isEmpty) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('没有可导出的源')));
      return;
    }
    final json = const JsonEncoder.withIndent('  ').convert({
      'sites': [
        for (final s in sources)
          {
            'key': s.id,
            'name': s.name,
            'type': s.kind == SourceKind.cmsXml ? 0 : 1,
            'api': s.api,
            if (s.headers.isNotEmpty) 'header': s.headers,
          }
      ],
    });
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出源（TVBox sites 格式）'),
        content: SingleChildScrollView(
          child: SelectableText(json),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: json));
              ScaffoldMessenger.maybeOf(context)
                  ?.showSnackBar(const SnackBar(content: Text('已复制到剪贴板')));
            },
            child: const Text('复制'),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭')),
        ],
      ),
    );
  }

  Future<void> _editDialog(AppScope scope, SourceConfig s) async {
    final nameController = TextEditingController(text: s.name);
    final apiController = TextEditingController(text: s.api);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('编辑源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称')),
            TextField(
                controller: apiController,
                decoration: const InputDecoration(labelText: '接口地址')),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存')),
        ],
      ),
    );
    if (ok != true) return;
    // 简化：编辑 = 删除旧的再按新地址入库（保留开关状态）。
    final enabled = s.enabled;
    final pinned = s.pinned;
    await scope.sources.remove(s.id);
    final updated = await scope.sources.addManual(
      name: nameController.text.trim(),
      api: apiController.text.trim(),
      kind: s.kind,
      headers: s.headers,
      note: s.note,
    );
    updated.enabled = enabled;
    updated.pinned = pinned;
    if (mounted) setState(() {});
  }
}
