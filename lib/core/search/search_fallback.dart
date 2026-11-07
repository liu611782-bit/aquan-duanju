/// 漫剧搜索的退化重试。
///
/// 服务端检索对完整剧名可能不匹配：实测搜「万妖图录传」空结果、
/// 搜「万妖图录」命中——全名带尾字时检索不到。客户端兜底：结果为空、
/// query 含 CJK 且长度 ≥4 时，逐次去尾退化重试（至多 2 次），命中即止
/// （更短的词只会匹配更宽，继续退化只会引入噪声），命中词与原词结果
/// 合并去重（按 [SeriesSummary.id]，即红果 seriesId）。
library;

import '../../models/models.dart';

/// 是否包含 CJK 统一表意文字（基本区 + 扩展 A）。
bool containsCJK(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x4E00 && rune <= 0x9FFF) ||
        (rune >= 0x3400 && rune <= 0x4DBF)) {
      return true;
    }
  }
  return false;
}

/// 退化重试词：第一次去尾 1 字（剧名最常见的单字后缀，如「传」——
/// 用户实测「万妖图录传 → 万妖图录」可命中），之后每步再去 2 字
/// （覆盖「之恋」「第二季」这类两字后缀），至多 [maxSteps] 次；
/// 候选词长不足 2 字的丢弃（单字检索是噪声）。
///
/// 例：万妖图录传 → [万妖图录, 万妖]；万妖图录 → [万妖图]。
List<String> degradedQueries(String query, {int maxSteps = 2}) {
  final q = query.trim();
  if (!containsCJK(q) || q.length < 4) return const [];
  final out = <String>[];
  var current = q;
  for (var step = 0; step < maxSteps; step++) {
    final drop = step == 0 ? 1 : 2;
    if (current.length - drop < 2) break;
    current = current.substring(0, current.length - drop);
    out.add(current);
  }
  return out;
}

/// 一次「退化重试搜索」的结果。
class FallbackSearchResult {
  const FallbackSearchResult({
    required this.page,
    required this.query,
    required this.degraded,
  });

  /// 合并去重后的结果页（cursor/hasMore 取自实际命中的那一页）。
  final AquaPage<SeriesSummary> page;

  /// 实际产生这批结果的检索词：未退化即原词，退化过即命中的退化词。
  final String query;

  /// 是否按退化词出了结果（用于 UI「已按 X 检索」提示）；
  /// 全链为空时为 false（没有「实际检索词」可标注）。
  final bool degraded;
}

/// 带退化重试的搜索：先用原词搜，结果为空且满足退化条件时逐次退化重试，
/// 命中即止。所有层级的结果合并去重（按 id，先到者优先）。
///
/// [search] 是单次搜索调用（调用方决定 tab/filters 等参数怎么带）；
/// 原词调用的异常**原样抛出**（源失败要进编排器的健康统计/负缓存），
/// 退化层的异常经 [onError] 交给调用方记 ErrorLog 后视为该层为空，
/// 不打断后续退化；[isCancelled] 返回真时停止后续重试（取消令牌）。
Future<FallbackSearchResult> searchWithDegradedRetry(
  Future<AquaPage<SeriesSummary>> Function(String query) search,
  String query, {
  int maxSteps = 2,
  bool Function()? isCancelled,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final q = query.trim();
  final collected = <SeriesSummary>[];

  Future<FallbackSearchResult?> attempt(
    String term, {
    required bool degraded,
  }) async {
    final page = await search(term);
    for (final item in page.items) {
      if (item.id.isEmpty) continue;
      if (collected.any((s) => s.id == item.id)) continue;
      collected.add(item);
    }
    if (page.items.isNotEmpty) {
      return FallbackSearchResult(
        page: AquaPage<SeriesSummary>(
          items: List.of(collected),
          cursor: page.cursor,
          hasMore: page.hasMore,
        ),
        query: term,
        degraded: degraded,
      );
    }
    return null;
  }

  if (isCancelled?.call() ?? false) {
    return FallbackSearchResult(
        page: const AquaPage<SeriesSummary>(items: []), query: q, degraded: false);
  }
  // 原词失败不吞：编排器/页面要按「源失败」处理（健康统计、负缓存、错误页）。
  final first = await attempt(q, degraded: false);
  if (first != null) return first;

  for (final term in degradedQueries(q, maxSteps: maxSteps)) {
    if (isCancelled?.call() ?? false) break;
    FallbackSearchResult? hit;
    try {
      hit = await attempt(term, degraded: true);
    } catch (e, st) {
      onError?.call(e, st);
      continue;
    }
    if (hit != null) return hit;
  }
  return FallbackSearchResult(
    page: AquaPage<SeriesSummary>(items: List.of(collected)),
    query: q,
    degraded: false,
  );
}
