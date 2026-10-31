import 'dart:async';

import 'package:flutter/material.dart';

import '../core/sources/source_adapter.dart';
import '../core/sources/spider_js_adapter.dart';
import '../core/sources/fongmi/fongmi_spider_adapter.dart';
import '../widgets/common.dart';
import '../core/bili/api.dart';
import 'media_hub_screen.dart' show SourceCover;
import 'source_player_screen.dart';

/// 第三方源详情：封面 + 简介 + 线路选择 + 分集网格 → 轻量播放器。
class SourceDetailScreen extends StatefulWidget {
  const SourceDetailScreen({
    super.key,
    required this.source,
    required this.series,
    required this.adapter,
    this.resolvePlay,
    this.loadDanmaku,
    this.onSendDanmaku,
  });

  final SourceConfig source;
  final UnifiedSeries series;
  final SourceAdapter adapter;

  /// 播放时解析钩子（B 站等 DASH 双轨源）与弹幕加载。
  final EpisodePlayResolver? resolvePlay;
  final Future<List<DanmakuItem>> Function(UnifiedEpisode episode)? loadDanmaku;
  final Future<void> Function(UnifiedEpisode episode, String msg)? onSendDanmaku;

  @override
  State<SourceDetailScreen> createState() => _SourceDetailScreenState();
}

class _SourceDetailScreenState extends State<SourceDetailScreen> {
  UnifiedSeries? _series;
  int _lineIndex = 0;
  bool _loading = true;
  Object? _error;

  /// 当前内容来自快照缓存（秒开）；后台刷新失败时保留缓存并提示。
  bool _fromCache = false;
  bool _refreshFailed = false;

  String get _snapshotKey =>
      'src:${widget.source.id}:${widget.series.sourceItemId}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _fromCache = false;
      _refreshFailed = false;
    });
    // 快照秒开：命中先渲染，后台刷新；失败保留缓存。
    final store = AppScope.read(context).detailSnapshots;
    await store.ensureLoaded();
    final cached = store.get(_snapshotKey);
    final hasSnapshot = cached != null;
    if (hasSnapshot && mounted) {
      final snapshot = UnifiedSeries.tryFromJson(cached);
      if (snapshot != null) {
        setState(() {
          _series = snapshot;
          _loading = false;
          _fromCache = true;
        });
      }
    }
    try {
      final detail = await widget.adapter.detail(widget.series.sourceItemId);
      if (!mounted) return;
      setState(() {
        _series = detail;
        _loading = false;
        _fromCache = false;
        _refreshFailed = false;
      });
      unawaited(store.put(_snapshotKey, detail.toJson()));
    } catch (e) {
      if (!mounted) return;
      if (hasSnapshot && _series != null) {
        setState(() {
          _loading = false;
          _refreshFailed = true;
        });
      } else {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  UnifiedSeries get series => _series ?? widget.series;

  PlayLine? get _line {
    final lines = series.lines;
    if (lines.isEmpty) return null;
    return lines[_lineIndex.clamp(0, lines.length - 1)];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scope = AppScope.of(context);
    final history = scope.history.entries
        .where((h) => h.seriesId == series.historyKey)
        .firstOrNull;
    return Scaffold(
      appBar: AppBar(title: Text(series.title)),
      body: Column(
        children: [
          if (_fromCache && _refreshFailed)
            Material(
              color: theme.colorScheme.surfaceContainerHighest,
              child: SizedBox(
                width: double.infinity,
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  child: Row(
                    children: [
                      Icon(Icons.cloud_off_rounded,
                          size: 14, color: theme.colorScheme.outline),
                      const SizedBox(width: 6),
                      Text('网络不可用，正在显示缓存数据',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline)),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: _load,
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SourceCover(
                    url: series.coverUrl,
                    headers: widget.source.headers,
                    width: 120,
                    height: 168,
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(series.title,
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 6),
                        Text(
                          [
                            if (series.year.isNotEmpty) series.year,
                            if (series.remarks.isNotEmpty) series.remarks,
                            '来源：${widget.source.name}',
                          ].join(' · '),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                        if (history != null && history.episode > 1) ...[
                          const SizedBox(height: 8),
                          Text(
                            '看到 第${history.episode}集'
                            '${history.position > 0 ? '（续播）' : ''}',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                        if (series.description.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Text(series.description,
                              maxLines: 6,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              if (series.lines.length > 1) ...[
                const SizedBox(height: 16),
                Text('播放线路', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    for (var i = 0; i < series.lines.length; i++)
                      ChoiceChip(
                        label: Text(series.lines[i].name),
                        selected: i == _lineIndex,
                        onSelected: (_) => setState(() => _lineIndex = i),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text('分集（${_line?.episodes.length ?? 0}）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Builder(builder: (context) {
                final line = _line;
                if (line == null || line.episodes.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text('该线路没有可播分集',
                        style: TextStyle(color: theme.colorScheme.outline)),
                  );
                }
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ep in line.episodes)
                      OutlinedButton(
                        onPressed: () => _play(ep),
                        child: Text(ep.title),
                      ),
                  ],
                );
              }),
                ],
              ),
            ),
          ),
        ),
          ],
        ),
      );
  }

  void _play(UnifiedEpisode ep) {
    final line = _line;
    if (line == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourcePlayerScreen(
        source: widget.source,
        series: series,
        line: line,
        startIndex: line.episodes.indexOf(ep).clamp(0, line.episodes.length - 1),
        adapter: widget.adapter,
        resolvePlay: _resolverFor(line.name) ?? widget.resolvePlay,
        loadDanmaku: widget.loadDanmaku,
        onSendDanmaku: widget.onSendDanmaku,
      ),
    ));
  }

  /// spider 源播放二次解析（playerContent）：分集 url 常是令牌；解析失败
  /// 回退直连 url，直连型 spider 不受影响。
  EpisodePlayResolver? _resolverFor(String flag) {
    if (widget.source.kind != SourceKind.spiderJs) return null;
    final adapter = widget.adapter;
    // 两种 JS 口味的二次解析同路径：解析失败回退直连 url。
    if (adapter is SpiderJsAdapter) {
      return (ep) async {
        try {
          final url = await adapter.resolvePlayUrl(flag: flag, id: ep.url);
          if (url.isNotEmpty) return ResolvedPlay(videoUrl: url);
        } catch (_) {}
        return ResolvedPlay(videoUrl: ep.url);
      };
    }
    if (adapter is FongmiSpiderAdapter) {
      return (ep) async {
        try {
          final url = await adapter.resolvePlayUrl(flag: flag, id: ep.url);
          if (url.isNotEmpty) return ResolvedPlay(videoUrl: url);
        } catch (_) {}
        return ResolvedPlay(videoUrl: ep.url);
      };
    }
    return null;
  }
}
