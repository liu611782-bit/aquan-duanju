import 'source_adapter.dart';
import 'source_probe.dart';

/// 源注册表的纯逻辑助手：去重、排序、归一化（持久化在 stores.dart 的 store 类里）。
///
/// 展示排序语义（tvbox / MoonTVPlus 同构）：
/// 钉选 > 启用 > 本轮测速状态（成功→超时→失败→未测）> 成功的 TTFB 升序
/// > 健康分降序 > 健康延迟升序 > 原始下标（稳定兜底）。
///
/// [probeOf] 为空时退化为改造前的「钉选 > 启用 > 健康分 > 延迟」，
/// 只是多了原始下标兜底——`List.sort` 不稳定，同分项不能每帧乱跳。
List<SourceConfig> sortSourcesForDisplay(
  Iterable<SourceConfig> sources, {
  required int Function(SourceConfig config) scoreOf,
  required int Function(SourceConfig config) latencyOf,
  ProbeOutcome? Function(SourceConfig config)? probeOf,
}) {
  final list = List.of(sources);
  final order = <SourceConfig, int>{
    for (var i = 0; i < list.length; i++) list[i]: i,
  };

  /// 0 成功 / 1 超时 / 2 失败 / 3 本轮未测。
  int probeRank(SourceConfig config) =>
      switch (probeOf?.call(config)?.state) {
        ProbeState.ok => 0,
        ProbeState.timeout => 1,
        ProbeState.failed => 2,
        null => 3,
      };

  int probeLatency(SourceConfig config) =>
      probeOf?.call(config)?.latencyMs ?? 1 << 30;

  list.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    if (a.enabled != b.enabled) return a.enabled ? -1 : 1;
    if (probeOf != null) {
      final rankA = probeRank(a);
      final rankB = probeRank(b);
      if (rankA != rankB) return rankA.compareTo(rankB);
      // 都成功：本轮实测 TTFB 比累计健康分更能代表「现在快不快」。
      if (rankA == 0) {
        final byTtfb = probeLatency(a).compareTo(probeLatency(b));
        if (byTtfb != 0) return byTtfb;
      }
    }
    final byScore = scoreOf(b).compareTo(scoreOf(a));
    if (byScore != 0) return byScore;
    final byLatency = latencyOf(a).compareTo(latencyOf(b));
    if (byLatency != 0) return byLatency;
    return (order[a] ?? 0).compareTo(order[b] ?? 0);
  });
  return list;
}

/// 候选去重：按 kind + api 归一化（去尾斜杠）合并，保留首个名称。
List<SourceCandidate> dedupeCandidates(Iterable<SourceCandidate> candidates) {
  final seen = <String, SourceCandidate>{};
  for (final c in candidates) {
    if (!c.usable) continue;
    final key =
        '${c.kind.name}|${c.api.endsWith('/') ? c.api.substring(0, c.api.length - 1) : c.api}';
    seen.putIfAbsent(key, () => c);
  }
  return seen.values.toList();
}

/// CMS 搜索结果的归一化去重键：标题 + 年份。
String dedupeKeyForSeries(String normalizedTitle, String year) =>
    '$normalizedTitle@$year';
