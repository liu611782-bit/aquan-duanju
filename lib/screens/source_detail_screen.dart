import 'dart:async';

import 'package:flutter/material.dart';

import '../core/sources/backend_dedupe.dart';
import '../core/sources/normal_title.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_adapter_factory.dart';
import '../core/sources/spider_js_adapter.dart';
import '../core/sources/fongmi/fongmi_spider_adapter.dart';
import '../store/stores.dart';
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
  /// 当前源与适配器：换源后就地替换（页面不重开）。
  late SourceConfig _source;
  late SourceAdapter _adapter;

  UnifiedSeries? _series;
  int _lineIndex = 0;
  bool _loading = true;
  bool _switching = false;
  Object? _error;

  /// 换源后要定位的分集名（归一化后唯一匹配时高亮）。
  String _highlightEpisode = '';

  /// 当前内容来自快照缓存（秒开）；后台刷新失败时保留缓存并提示。
  bool _fromCache = false;
  bool _refreshFailed = false;

  String get _snapshotKey => 'src:${_source.id}:${series.sourceItemId}';

  @override
  void initState() {
    super.initState();
    _source = widget.source;
    _adapter = widget.adapter;
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
      final detail = await _adapter
          .detail(series.sourceItemId)
          .timeout(const Duration(seconds: 20));
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
      appBar: AppBar(
        title: Text(series.title),
        actions: [
          if (_switching)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (scope.settings.detailSourceSwitch)
            IconButton(
              tooltip: '换源',
              icon: const Icon(Icons.swap_horiz),
              onPressed: _showSwitchSource,
            ),
        ],
      ),
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
                    headers: _source.headers,
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
                            '来源：${_source.name}',
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
                      _episodeButton(theme, ep),
                  ],
                );
              }),
                ],
              ),
            ),
          ),
        ),
          if (_error != null && _fallbackUrlOf(history).isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton.icon(
                onPressed: () => _playDirectFallback(history!),
                icon: const Icon(Icons.play_arrow),
                label: const Text('用上次线路继续播放'),
              ),
            ),
          ],
        ),
      );
  }

  /// 换源后命中的那一集用实心按钮标出来；其余保持描边。
  Widget _episodeButton(ThemeData theme, UnifiedEpisode ep) {
    final highlight = _highlightEpisode.isNotEmpty &&
        normalizeEpisodeName(ep.title) == _highlightEpisode;
    if (highlight) {
      return FilledButton.tonal(
        onPressed: () => _play(ep),
        child: Text(ep.title),
      );
    }
    return OutlinedButton(
      onPressed: () => _play(ep),
      child: Text(ep.title),
    );
  }

  /// 换源：在其他（按后端去重后的）启用源里搜同名剧，逐个试详情。
  Future<void> _showSwitchSource() async {
    if (_switching) return;
    final scope = AppScope.read(context);
    final current = backendSignature(_source);
    final candidates = dedupeByBackend(scope.sources.enabled)
        .where((s) => backendSignature(s) != current)
        .where((s) =>
            s.kind == SourceKind.cmsJson ||
            s.kind == SourceKind.cmsXml ||
            s.kind == SourceKind.spiderJs)
        .take(20)
        .toList();
    if (candidates.isEmpty) {
      _snack('没有其它可换的源');
      return;
    }
    final picked = await showModalBottomSheet<SourceConfig>(
      context: context,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Text('换源', style: Theme.of(sheetContext).textTheme.titleMedium),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '按剧名在其他源重新查找（最多试 '
                      '${candidates.length.clamp(0, _maxSwitchTry)} 个）',
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: candidates.length,
                itemBuilder: (_, index) {
                  final config = candidates[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.live_tv),
                    title: Text(config.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      config.api,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(sheetContext).textTheme.bodySmall,
                    ),
                    onTap: () => Navigator.of(sheetContext).pop(config),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    await _switchTo(picked);
  }

  static const int _maxSwitchTry = 8;

  Future<void> _switchTo(SourceConfig config) async {
    final adapter = buildSourceAdapter(config);
    if (adapter == null) {
      _snack('该源暂不支持切换');
      return;
    }
    // 换源后要定位的集：优先上次看到的集，否则第一集。
    final oldLine = _line;
    var targetEpisode = '';
    final history = AppScope.read(context)
        .history
        .entries
        .where((h) => h.seriesId == series.historyKey)
        .firstOrNull;
    if (oldLine != null && oldLine.episodes.isNotEmpty) {
      final index = (history?.episode ?? 1) - 1;
      targetEpisode = oldLine.episodes[
              index.clamp(0, oldLine.episodes.length - 1)]
          .title;
    }

    setState(() => _switching = true);
    UnifiedSeries? found;
    try {
      final query = series.title.trim();
      await for (final event in adapter
          .search(query)
          .timeout(const Duration(seconds: 8), onTimeout: (sink) => sink.close())) {
        if (event is SourceHits) {
          for (final hit in event.items) {
            if (hit.normalizedTitle != series.normalizedTitle) continue;
            if (series.year.isNotEmpty &&
                hit.year.isNotEmpty &&
                hit.year != series.year) {
              continue;
            }
            found = hit;
            break;
          }
        }
        if (found != null) break;
      }
    } catch (_) {
      // 搜索失败按「没找到」处理，下面给统一文案。
    }

    if (found == null) {
      if (mounted) setState(() => _switching = false);
      _snack('其他源没有找到《${series.title}》');
      return;
    }

    try {
      final detail = await adapter
          .detail(found.sourceItemId)
          .timeout(const Duration(seconds: 6));
      if (!mounted) return;
      final line = detail.defaultLine;
      var lineIndex = 0;
      var highlight = '';
      if (line != null) {
        final at = detail.lines.indexWhere((l) => identical(l, line));
        if (at >= 0) lineIndex = at;
        if (targetEpisode.isNotEmpty) {
          final key = normalizeEpisodeName(targetEpisode);
          final matches = <int>[
            for (var i = 0; i < line.episodes.length; i++)
              if (normalizeEpisodeName(line.episodes[i].title) == key) i,
          ];
          // 只接受唯一匹配：同名多集说明命名不可靠，不猜。
          if (matches.length == 1) {
            highlight = key;
          }
        }
      }
      setState(() {
        _source = config;
        _adapter = adapter;
        _series = detail;
        _lineIndex = lineIndex;
        _highlightEpisode = highlight;
        _error = null;
        _fromCache = false;
        _refreshFailed = false;
        _loading = false;
        _switching = false;
      });
      _snack(highlight.isEmpty
          ? '已切换到 ${config.name}'
          : '已切换到 ${config.name}，并定位到「$targetEpisode」');
    } catch (e) {
      if (mounted) setState(() => _switching = false);
      _snack('换源失败：${e is SourceException ? e.friendlyText : '该源暂时不可用'}');
    }
  }

  /// 历史里可用的直链：新记录在 `playUrl`，老记录把 URL 存在 `episodeId`。
  static String _fallbackUrlOf(HistoryEntry? history) {
    if (history == null) return '';
    if (history.playUrl.isNotEmpty) return history.playUrl;
    if (history.episodeId.startsWith('http://') ||
        history.episodeId.startsWith('https://')) {
      return history.episodeId;
    }
    return '';
  }

  /// 详情挂掉时的兜底：直接用历史里存的直链起播。
  void _playDirectFallback(HistoryEntry history) {
    final url = _fallbackUrlOf(history);
    if (url.isEmpty) return;
    final fallback = UnifiedSeries(
      sourceKey: _source.id,
      sourceItemId: series.sourceItemId,
      title: series.title,
      normalizedTitle: series.normalizedTitle,
      year: series.year,
      coverUrl: series.coverUrl,
      remarks: series.remarks,
      headers: _source.headers,
      lines: [
        PlayLine(
          name: '上次线路',
          episodes: [
            UnifiedEpisode(
              title: history.episode > 0 ? '第${history.episode}集' : '上次播放',
              url: url,
              index: 0,
            ),
          ],
        ),
      ],
    );
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourcePlayerScreen(
        source: _source,
        series: fallback,
        line: fallback.lines.first,
        startIndex: 0,
        adapter: _adapter,
      ),
    ));
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _play(UnifiedEpisode ep) {
    final line = _line;
    if (line == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => SourcePlayerScreen(
        source: _source,
        series: series,
        line: line,
        startIndex: line.episodes.indexOf(ep).clamp(0, line.episodes.length - 1),
        adapter: _adapter,
        resolvePlay: _resolverFor(line.name) ?? widget.resolvePlay,
        loadDanmaku: widget.loadDanmaku,
        onSendDanmaku: widget.onSendDanmaku,
      ),
    ));
  }

  /// spider 源播放二次解析（playerContent）：分集 url 常是令牌；解析失败
  /// 回退直连 url，直连型 spider 不受影响。
  EpisodePlayResolver? _resolverFor(String flag) {
    if (_source.kind != SourceKind.spiderJs) return null;
    final adapter = _adapter;
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
