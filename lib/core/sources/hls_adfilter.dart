/// HLS 清单去广告。
///
/// 三层判定（保守优先，宁可不净化也不误杀）：
/// 1. **CUE-OUT/CUE-IN 区间**：`#EXT-X-CUE-OUT` 到 `#EXT-X-CUE-IN` 之间的分片整体判广告；
/// 2. **单分片关键字**：URI 命中 [adKeywords]；
/// 3. **短广告组**：按 `#EXT-X-DISCONTINUITY` 分组后，组时长 ≤ 30s、≤ 主组时长 1/3、
///    ≤ 12 片，且组内有广告标记 → 整组删除。
///
/// 安全阈值：删除分片数超过总数 50% 视为误杀，整体回退成「只重写 URI」。
class HlsAdFilter {
  HlsAdFilter._();

  /// 广告分片 URI 关键字（MoonTVPlus / webhtv 同源表）。
  static const adKeywords = [
    'sponsor',
    '/ad/',
    '/ads/',
    'advert',
    'advertisement',
    '/adjump',
    'redtraffic',
  ];

  /// 短广告组的最大时长（秒）。
  static const double shortGroupMaxSeconds = 30;

  /// 短广告组的最大分片数。
  static const int shortGroupMaxSegments = 12;

  /// URI 是否命中广告关键字（小写包含匹配）。
  static bool isAdUri(String uri) {
    final lower = uri.toLowerCase();
    for (final k in adKeywords) {
      if (lower.contains(k)) return true;
    }
    return false;
  }

  /// 清单是否主清单（含 STREAM-INF）。
  static bool isMasterManifest(String text) =>
      text.contains('#EXT-X-STREAM-INF');

  /// 统一入口：[rewriteUri] 把（已转绝对的）URI 换成代理 URL。
  static String rewriteManifest(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    if (isMasterManifest(text)) {
      return _rewriteAllUris(text, baseUri, rewriteUri);
    }
    return _rewriteMedia(text, baseUri, rewriteUri);
  }

  static String _rewriteMedia(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    final parsed = _parse(text, baseUri);
    final chunks = parsed.chunks;
    if (chunks.isEmpty) return _rewriteAllUris(text, baseUri, rewriteUri);

    _markSingleAds(chunks);
    _markShortAdGroups(chunks);

    final total = chunks.length;
    final dropped = chunks.where((c) => c.ad).length;
    // 误杀保护：删太多就整篇回退（URI 仍要重写，否则播放必坏）。
    if (total > 0 && dropped * 2 > total) {
      return _rewriteAllUris(text, baseUri, rewriteUri);
    }

    final out = <String>[];
    var pendingDiscontinuity = false;
    for (final chunk in chunks) {
      if (chunk.discontinuityBefore) {
        // 仅当两侧都有保留分片时才保留标记，避免首尾出现孤立 DISCONTINUITY。
        pendingDiscontinuity = true;
      }
      if (chunk.ad) continue;
      if (pendingDiscontinuity && out.isNotEmpty) {
        out.add('#EXT-X-DISCONTINUITY');
      }
      pendingDiscontinuity = false;
      for (final comment in chunk.leadingComments) {
        out.add(_rewriteTagUris(comment, baseUri, rewriteUri));
      }
      if (chunk.extInf != null) out.add(chunk.extInf!);
      out.add(rewriteUri(chunk.uri!));
    }
    // 末尾标签（#EXT-X-ENDLIST 等）不属于任何分片，丢掉会让 VOD 变成「未结束」。
    for (final comment in parsed.trailing) {
      out.add(_rewriteTagUris(comment, baseUri, rewriteUri));
    }
    return out.join('\n');
  }

  /// 1) CUE-OUT 区间 + 2) 单分片关键字。
  static void _markSingleAds(List<_Chunk> chunks) {
    for (final chunk in chunks) {
      if (chunk.inCue || isAdUri(chunk.uri!)) {
        chunk.ad = true;
      }
    }
  }

  /// 3) 短广告组：整组删除。
  ///
  /// 只在「有广告标记」时才升级为整组删除——纯粹的短组（正常片子的小段落）
  /// 不动，避免把正片剪掉。
  static void _markShortAdGroups(List<_Chunk> chunks) {
    if (chunks.every((c) => !c.discontinuityBefore)) return;
    final duration = <int, double>{};
    final count = <int, int>{};
    for (final chunk in chunks) {
      duration[chunk.group] = (duration[chunk.group] ?? 0) + chunk.duration;
      count[chunk.group] = (count[chunk.group] ?? 0) + 1;
    }
    if (duration.length < 2) return;
    final main = duration.values.reduce((a, b) => a > b ? a : b);
    final adGroups = <int>{};
    duration.forEach((group, seconds) {
      final segments = count[group] ?? 0;
      if (seconds > shortGroupMaxSeconds) return;
      if (segments > shortGroupMaxSegments) return;
      if (seconds > main / 3) return;
      final marked = chunks.any(
        (c) => c.group == group && (c.inCue || isAdUri(c.uri!)),
      );
      if (marked) adGroups.add(group);
    });
    if (adGroups.isEmpty) return;
    for (final chunk in chunks) {
      if (adGroups.contains(chunk.group)) chunk.ad = true;
    }
  }

  static _Parsed _parse(String text, Uri baseUri) {
    final chunks = <_Chunk>[];
    var current = _Chunk(group: 0);
    var group = 0;
    var inCue = false;

    void flush() {
      if (current.uri != null) {
        chunks.add(current);
      } else if (current.leadingComments.isNotEmpty) {
        // 无 URI 的纯注释块（如窗口标签）挂到下一个分片前面。
        current.leadingComments.clear();
      }
      current = _Chunk(group: group);
    }

    for (final raw in text.split('\n')) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        continue;
      }
      if (trimmed.startsWith('#EXT-X-CUE-OUT')) {
        inCue = true;
        current.leadingComments.add(line);
        continue;
      }
      if (trimmed.startsWith('#EXT-X-CUE-IN')) {
        inCue = false;
        current.leadingComments.add(line);
        continue;
      }
      if (trimmed == '#EXT-X-DISCONTINUITY') {
        flush();
        group++;
        current.group = group;
        current.discontinuityBefore = true;
        continue;
      }
      if (trimmed.startsWith('#EXTINF')) {
        current.extInf = line;
        current.duration = _parseDuration(trimmed);
        continue;
      }
      if (trimmed.startsWith('#')) {
        current.leadingComments.add(line);
        continue;
      }
      current.uri = _absolute(trimmed, baseUri);
      current.inCue = inCue;
      flush();
    }
    // EOF 时 current 只剩「最后一个分片之后的标签」。
    return _Parsed(chunks, List<String>.from(current.leadingComments));
  }

  static double _parseDuration(String extInf) {
    final colon = extInf.indexOf(':');
    if (colon < 0) return 0;
    var value = extInf.substring(colon + 1);
    final comma = value.indexOf(',');
    if (comma >= 0) value = value.substring(0, comma);
    return double.tryParse(value.trim()) ?? 0;
  }

  /// 逐行把非注释行当 URI 重写（主清单与回退路径共用）。
  static String _rewriteAllUris(
    String text,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    final out = <String>[];
    for (final raw in text.split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) {
        out.add(raw);
        continue;
      }
      if (trimmed.startsWith('#')) {
        out.add(_rewriteTagUris(raw, baseUri, rewriteUri));
        continue;
      }
      out.add(rewriteUri(_absolute(trimmed, baseUri)));
    }
    return out.join('\n');
  }

  /// `#EXT-X-KEY:URI="…"` / `#EXT-X-MAP:URI="…"` 里的密钥与初始化分片
  /// 同样要经代理带走 Referer/UA；旧实现把整行当注释保留，AES-128 密钥
  /// 请求直连源站被 403，表现为「有画面但解码失败 / 直接播不出来」。
  static final RegExp _tagUri =
      RegExp(r'URI="([^"]+)"', caseSensitive: false);

  static String _rewriteTagUris(
    String line,
    Uri baseUri,
    String Function(String absUri) rewriteUri,
  ) {
    if (!line.toUpperCase().contains('URI="')) return line;
    return line.replaceAllMapped(_tagUri, (m) {
      final matched = m.group(0)!;
      final eq = matched.indexOf('=');
      final prefix = matched.substring(0, eq + 2); // 保留原属性名大小写
      final abs = _absolute(m.group(1)!, baseUri);
      return '$prefix${rewriteUri(abs)}"';
    });
  }

  static String _absolute(String ref, Uri baseUri) {
    final uri = Uri.tryParse(ref);
    if (uri == null) return ref;
    if (uri.hasScheme && uri.host.isNotEmpty) return uri.toString();
    try {
      final resolved = baseUri.resolve(ref);
      // 相对分片继承父清单的鉴权 query（时效 token 常见），否则分片 403。
      if (resolved.query.isEmpty && baseUri.query.isNotEmpty) {
        return resolved.replace(query: baseUri.query).toString();
      }
      return resolved.toString();
    } catch (_) {
      return ref;
    }
  }
}

/// 解析结果：分片列表 + 末尾不属于任何分片的标签（#EXT-X-ENDLIST 等）。
class _Parsed {
  _Parsed(this.chunks, this.trailing);

  final List<_Chunk> chunks;
  final List<String> trailing;
}

class _Chunk {
  _Chunk({required this.group});

  int group;
  final List<String> leadingComments = <String>[];
  String? extInf;
  String? uri;
  double duration = 0;
  bool inCue = false;
  bool discontinuityBefore = false;
  bool ad = false;
}
