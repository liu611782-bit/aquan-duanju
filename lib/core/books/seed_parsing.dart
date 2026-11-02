/// 书源种子的**纯解析工具**（无网络、无 Flutter）：可单测。
///
/// 种子有两种形态：
/// 1. 直读 JSON（数组 / `{bookSources:[...]}` 包装 / 单对象）；
/// 2. HTML 索引页（aoaostar、喵公子等）——页面里给 `.json` 下载链接，
///    这里只负责把链接抽出来，取回后仍走 [tryDecodeBookSourceJson]。
library;

import 'dart:convert';

/// 尝试把文本解析成「书源集合」；不是可用 JSON 返回 null。
///
/// 接受：`[ {...}, ... ]`、`{"bookSources":[...]}`、单个书源对象。
Object? tryDecodeBookSourceJson(String text) {
  final trimmed = text.trimLeft();
  if (trimmed.isEmpty) return null;
  if (!trimmed.startsWith('[') && !trimmed.startsWith('{')) return null;
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return null;
  }
  if (decoded is List) return decoded.isEmpty ? null : decoded;
  if (decoded is Map<String, dynamic>) {
    if (decoded['bookSources'] is List) return decoded['bookSources'];
    if (decoded.containsKey('bookSourceUrl')) return decoded;
    // 其它包装（如 {"data":[...]}）尽量兜一层。
    for (final value in decoded.values) {
      if (value is List && value.isNotEmpty) return value;
    }
    return null;
  }
  return null;
}

/// 从 HTML 里抽取 `.json` 链接（绝对化、去重、限制同源优先）。
///
/// 只认 href 里以 `.json` 结尾（可带 query）的链接；`javascript:` /
/// `data:` 之类直接丢弃。
List<String> jsonLinksInHtml(String html, {required String baseUrl}) {
  final base = Uri.tryParse(baseUrl);
  if (base == null) return const [];
  final out = <String>[];
  final seen = <String>{};
  final pattern = RegExp(
    r'''href\s*=\s*["']([^"']+\.json(?:\?[^"']*)?)["']''',
    caseSensitive: false,
  );
  for (final match in pattern.allMatches(html)) {
    var raw = match.group(1)?.trim() ?? '';
    if (raw.isEmpty) continue;
    // `yuedu://import?src=https://…/x.json` 这类深链：取里面的 http(s) 地址。
    if (!raw.startsWith('http') && raw.contains('src=')) {
      final inner = raw.split('src=').last;
      raw = Uri.decodeComponent(inner);
    }
    if (raw.startsWith('javascript:') || raw.startsWith('data:')) continue;
    final Uri resolved;
    try {
      resolved = base.resolve(raw);
    } catch (_) {
      continue;
    }
    // 只认真实 http(s)（`legado://` / `yuedu://` 无法直接抓取）。
    if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
    final url = resolved.toString();
    if (!seen.add(url)) continue;
    out.add(url);
  }
  // 同源优先：索引页自己目录下的导出更可能是完整集合。
  out.sort((a, b) {
    final aHost = Uri.tryParse(a)?.host ?? '';
    final bHost = Uri.tryParse(b)?.host ?? '';
    final aSame = aHost == base.host ? 0 : 1;
    final bSame = bHost == base.host ? 0 : 1;
    return aSame.compareTo(bSame);
  });
  return out;
}
