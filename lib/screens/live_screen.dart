import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/live/epg.dart';
import '../core/live/live_parser.dart';
import '../core/live/live_probe.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_import.dart';
import '../core/sources/source_probe.dart';
import '../store/stores.dart';
import '../widgets/common.dart';
import '../widgets/skeleton.dart';
import 'live_player_screen.dart';

/// 直播页：TVBox lives 配置 → 频道分组浏览 → 测速 → 播放。
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final _groupsCache = <String, List<LiveGroup>>{};
  final _latency = <String, ProbeOutcome>{};

  List<LiveGroup> _groups = const [];
  int _groupIndex = 0;
  bool _loading = true;
  bool _probing = false;
  Object? _error;
  CancelToken? _probeCancel;

  /// EPG：url → 节目单（会话缓存 1h，由调用时间戳判定）。
  final Map<String, (EpgGuide, DateTime)> _epgCache = {};
  EpgGuide? _epg;
  StreamSubscription<(LiveChannel, ProbeOutcome)>? _probeSub;

  /// 直播源加载代号：快速切换源时旧响应必须丢弃。
  int _loadEpoch = 0;

  /// EPG 加载代号：与源切换解耦，避免旧节目单盖到新源上。
  int _epgEpoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _probeCancel?.cancel();
    _probeSub?.cancel();
    super.dispose();
  }

  LiveEntry? get _currentLive {
    final scope = AppScope.read(context);
    final enabled = scope.lives.enabled;
    if (enabled.isEmpty) return null;
    final lastId = scope.lives.lastLiveId;
    return enabled.where((e) => e.id == lastId).firstOrNull ?? enabled.first;
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    final live = _currentLive;
    if (live == null) {
      setState(() => _loading = false);
      return;
    }
    final cached = _groupsCache[live.url];
    if (cached != null) {
      setState(() {
        _groups = cached;
        _loading = false;
        _error = null;
      });
      // 缓存分支以前直接 return：切到没有 EPG 的源时，上一套节目单会留在界面上。
      if (live.epg.isEmpty) {
        setState(() => _epg = null);
      } else {
        unawaited(_loadEpg(live.epg, epoch: epoch));
      }
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final text = await SourceImporter.fetchConfigText(live.url);
      if (!mounted || epoch != _loadEpoch) return;
      final groups = LiveParser.parse(text);
      _groupsCache[live.url] = groups;
      setState(() {
        _groups = groups;
        _loading = false;
      });
      // EPG 后台加载：失败静默（不打扰频道浏览）。
      if (live.epg.isNotEmpty) {
        unawaited(_loadEpg(live.epg, epoch: epoch));
      } else if (mounted) {
        setState(() => _epg = null);
      }
    } on FormatException catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _error = '直播源格式无法识别：${e.message}';
      });
    } on SourceException catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _error = e.friendlyText;
      });
    } catch (e) {
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadEpg(String epgUrl, {int? epoch}) async {
    final sourceEpoch = epoch ?? _loadEpoch;
    final epgEpoch = ++_epgEpoch;
    final cached = _epgCache[epgUrl];
    if (cached != null &&
        DateTime.now().difference(cached.$2) < const Duration(hours: 1)) {
      if (mounted && sourceEpoch == _loadEpoch) setState(() => _epg = cached.$1);
      return;
    }
    try {
      final bytes = await SourceImporter.fetchConfigText(epgUrl);
      if (!mounted || sourceEpoch != _loadEpoch || epgEpoch != _epgEpoch) {
        return;
      }
      final guide = parseEpgBytes(utf8.encode(bytes));
      _epgCache[epgUrl] = (guide, DateTime.now());
      setState(() => _epg = guide);
    } catch (_) {
      // EPG 失败静默：频道照常浏览。
    }
  }

  /// 频道当前的节目（tvg-id/频道名两级匹配）。
  EpgProgramme? _nowPlaying(LiveChannel channel) {
    final epg = _epg;
    if (epg == null || epg.isEmpty) return null;
    final keys = epgKeysFor(channelName: channel.name, tvgId: channel.tvgId);
    final now = DateTime.now().toUtc();
    return epg.nowFor(keys, now);
  }

  Future<void> _switchLive(LiveEntry live) async {
    final scope = AppScope.read(context);
    await scope.lives.setLastWatched(live.id, scope.lives.lastChannelName ?? '');
    _groupIndex = 0;
    await _load();
  }

  Future<void> _probeAll() async {
    if (_probing) return;
    final channels = [
      for (final g in _groups) ...g.channels,
    ];
    if (channels.isEmpty) return;
    _probeCancel?.cancel();
    final cancel = _probeCancel = CancelToken();
    setState(() => _probing = true);
    await for (final (channel, outcome) in LiveProbe.probeAll(channels, cancel: cancel)) {
      if (!mounted) return;
      setState(() => _latency[channel.name] = outcome);
    }
    if (mounted) setState(() => _probing = false);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final lives = scope.lives.enabled;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          IconButton(
            tooltip: '全部测速',
            icon: Icon(_probing ? Icons.hourglass_top : Icons.speed),
            onPressed: _probing ? null : _probeAll,
          ),
          IconButton(
            tooltip: '添加直播配置',
            icon: const Icon(Icons.add_link),
            onPressed: () => _addLiveDialog(scope),
          ),
        ],
      ),
      body: Column(
        children: [
          if (lives.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                children: [
                  for (final live in lives)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(live.name),
                        selected: _currentLive?.id == live.id,
                        onSelected: (_) => _switchLive(live),
                      ),
                    ),
                ],
              ),
            ),
          Expanded(
            child: lives.isEmpty
                ? _EmptyLivesView(onAdd: () => _addLiveDialog(scope))
                : _buildChannels(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildChannels(ThemeData theme) {
    if (_loading) return const Center(child: SkeletonView(layout: SkeletonLayout.grid));
    if (_error != null) {
      return ErrorRetryView(error: _error!, onRetry: _load);
    }
    if (_groups.isEmpty) {
      return Center(
          child: Text('频道列表为空',
              style: TextStyle(color: theme.colorScheme.outline)));
    }
    final group = _groups[_groupIndex.clamp(0, _groups.length - 1)];
    final lastChannel = AppScope.read(context).lives.lastChannelName;
    return Column(
      children: [
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (var i = 0; i < _groups.length; i++)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text('${_groups[i].name} (${_groups[i].channels.length})'),
                    selected: i == _groupIndex,
                    onSelected: (_) => setState(() => _groupIndex = i),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 24),
            itemCount: group.channels.length,
            itemBuilder: (context, index) {
              final channel = group.channels[index];
              final outcome = _latency[channel.name];
              final nowPlaying = _nowPlaying(channel);
              return ListTile(
                dense: true,
                leading: const Icon(Icons.live_tv, size: 20),
                title: Text(channel.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(
                    [
                      if (nowPlaying != null) '正在播：${nowPlaying.title}',
                      '${channel.urls.length} 个地址',
                      if (channel.name == lastChannel) '上次观看',
                    ].join(' · '),
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: outcome == null
                    ? null
                    : _LatencyChip(outcome: outcome),
                onTap: () => _play(channel),
              );
            },
          ),
        ),
      ],
    );
  }

  void _play(LiveChannel channel) {
    final live = _currentLive;
    if (live == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LivePlayerScreen(
        live: live,
        groups: _groups,
        initialGroup: _groupIndex,
        channel: channel,
        latency: Map.of(_latency),
        epg: _epg,
      ),
    ));
  }

  Future<void> _addLiveDialog(AppScope scope) async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加直播配置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: '名称')),
            TextField(
              controller: urlController,
              decoration: const InputDecoration(
                  labelText: '频道清单地址（TXT/M3U/JSON）'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('添加')),
        ],
      ),
    );
    if (ok != true) return;
    if (!mounted) return;
    final url = urlController.text.trim();
    if (!url.startsWith('http')) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('地址必须是 http/https')));
      return;
    }
    await scope.lives.addManual(
      name: nameController.text.trim().isEmpty
          ? Uri.parse(url).host
          : nameController.text.trim(),
      url: url,
    );
    if (!mounted) return;
    await _load();
  }
}

class _EmptyLivesView extends StatelessWidget {
  const _EmptyLivesView({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.settings_input_antenna_outlined,
              size: 64, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          const Text('还没有直播配置'),
          const SizedBox(height: 4),
          Text('源市场扫描 TVBox 配置会自动带出，也可手动添加',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.outline, fontSize: 12)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_link),
            label: const Text('手动添加'),
          ),
        ],
      ),
    );
  }
}

class _LatencyChip extends StatelessWidget {
  const _LatencyChip({required this.outcome});

  final ProbeOutcome outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, color) = switch (outcome.state) {
      ProbeState.ok => (
          '连接成功 ${outcome.latencyMs}ms',
          switch (probeLevel(outcome.latencyMs ?? 9999)) {
            ProbeLevel.fast => Colors.green,
            ProbeLevel.normal => Colors.orange,
            ProbeLevel.slow => Colors.red,
          }
        ),
      ProbeState.timeout => ('超时', Colors.grey),
      ProbeState.failed => ('失败', theme.colorScheme.error),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11)),
    );
  }
}
