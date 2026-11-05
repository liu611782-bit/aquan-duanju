/// 图片缓存 key 的规范化。
///
/// 封面 URL 带 `x-signature` / `x-expires` 这类签名参数，签名随会话变化。直接
/// 拿完整 URL 当缓存 key，会导致「同一张图每次刷新都不命中磁盘」，每次都重新
/// 下载并经 Go 核心做 HEIC 转码——这是图片加载慢的主要原因之一。
///
/// 只剔除签名 / 时效类参数，其余参数（尺寸模板、裁剪参数等）原样保留，避免把
/// 内容不同的图片归一成同一个 key。
library;

/// 与签名/时效相关、对图片内容没有影响的查询参数（比较时统一小写）。
const Set<String> _volatileQueryKeys = {
  'x-signature',
  'x-expires',
  'signature',
  'expires',
  'sign',
  'token',
  'auth_key',
  'authkey',
};

/// 生成稳定的缓存 key。
///
/// - 无查询串 → 去掉 `?` 后的原始地址；
/// - 剔除签名参数后仍保留剩余参数的**原始顺序与编码**（不做重编码，避免同一
///   URL 因编码差异产生不同 key）；
/// - 无法解析（相对路径、空串）时原样返回，调用方行为不变。
String stableImageKey(String url) {
  if (url.isEmpty) return url;
  final q = url.indexOf('?');
  if (q < 0) return url;
  final base = url.substring(0, q);
  if (base.isEmpty) return url;

  final kept = <String>[];
  for (final part in url.substring(q + 1).split('&')) {
    if (part.isEmpty) continue;
    final eq = part.indexOf('=');
    final name = (eq < 0 ? part : part.substring(0, eq)).toLowerCase();
    if (_volatileQueryKeys.contains(name)) continue;
    kept.add(part);
  }
  return kept.isEmpty ? base : '$base?${kept.join('&')}';
}
