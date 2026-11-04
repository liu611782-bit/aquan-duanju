import 'source_adapter.dart';

/// 采集站「后端」签名：同一后端被多份配置重复收录时只应请求一次。
///
/// 语义对齐 TVBox `SourceDedupe.backendSig`：
/// - 非爬虫：`kind|api`，api 去协议、去尾斜杠，`/at/xml` 视为同一后端；
/// - 爬虫：`3|api|ext|jar`，因为真实后端由 ext / jar 决定，光看 api 会误合并。
///
/// 不用 host 做键：同一 host 下 `/api.php/provide/vod` 与 `/api.php/app/vod`
/// 是两个完全不同的采集站。
String backendSignature(SourceConfig config) {
  final api = config.api.trim();
  if (config.kind == SourceKind.spider || config.kind == SourceKind.spiderJs) {
    return '3|$api|${config.ext.trim()}|${config.spiderKey ?? ''}';
  }
  var normalized = api.toLowerCase();
  normalized = normalized.replaceFirst(RegExp(r'^https?://'), '');
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  if (normalized.endsWith('/at/xml')) {
    normalized = normalized.substring(0, normalized.length - '/at/xml'.length);
    while (normalized.endsWith('/')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
  }
  return '${config.kind.name}|$normalized';
}

/// 按后端去重，保留每组第一个（配置里的先后顺序即用户排序）。
///
/// [priorityId] 对应的源（视频聚合正在用的主页源）提前到首位，
/// 这样它若能搜到结果就最先返回；其余顺序不变。
List<SourceConfig> dedupeByBackend(
  Iterable<SourceConfig> sources, {
  String priorityId = '',
}) {
  final list = List<SourceConfig>.of(sources);
  if (priorityId.isNotEmpty) {
    final index = list.indexWhere((s) => s.id == priorityId);
    if (index > 0) {
      final first = list.removeAt(index);
      list.insert(0, first);
    }
  }
  final seen = <String>{};
  final out = <SourceConfig>[];
  for (final source in list) {
    if (source.api.trim().isEmpty) continue;
    if (!seen.add(backendSignature(source))) continue;
    out.add(source);
  }
  return out;
}
