import 'source_import.dart';

/// 播放地址归一：源站常带 `&amp;`、转义斜杠、换行或多余空白，直接丢给
/// `Uri.parse` / mpv 会 400 或解析失败。
///
/// 不做参数重排或删减（鉴权串顺序敏感），只修明显的编码噪声。
String normalizeMediaUrl(String raw) => raw
    .trim()
    .replaceAll('&amp;', '&')
    .replaceAll(r'\/', '/')
    .replaceAll('\r', '')
    .replaceAll('\n', '')
    .replaceAll(RegExp(r'\s+'), '');

/// 一集媒体在本地播放与投屏之间共享的解析结果。
///
/// 此前 `_open()` 会把 CMS 源强制包一层本地去广告代理，而 `_resolveCastMedia()`
/// 用 `ep.url` 原始直链——同一部片在 APP 内 403、投到电视却能播，正是这条
/// 链路分叉造成的。两条链路必须消费同一个 [ResolvedPlayback]。
class ResolvedPlayback {
  const ResolvedPlayback({
    required this.url,
    required this.headers,
    required this.isHls,
    required this.needsProxy,
    required this.mimeType,
  });

  /// 归一后的上游原始直链（未包代理）。
  final String url;

  /// 源级 headers + 默认 UA；本地播放与投屏都用它。
  final Map<String, String> headers;

  final bool isHls;

  /// 是否值得尝试去广告代理：只有「用户开启 + 是 HLS」才为真。
  final bool needsProxy;

  /// DIDL `protocolInfo` 用的 MIME。
  final String mimeType;

  /// 非 http(s) 的地址（spider 令牌 / 自定义 scheme）不直接可播，仅供诊断。
  bool get isPlayable =>
      url.startsWith('http://') || url.startsWith('https://');

  String get host => Uri.tryParse(url)?.host ?? '-';

  /// 诊断标签：不含完整 URL、query、凭据或 UA 全值。
  String get diagnostic {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    final tail = path.isEmpty
        ? '-'
        : (path.length > 48 ? path.substring(path.length - 48) : path);
    return '${isHls ? 'hls' : 'vod'}/h${headers.length}/'
        '${isPlayable ? 'http' : 'scheme!'}/$host/$tail';
  }
}

/// 按 URL 形态判断 HLS（不发起网络请求）。
///
/// 不能只看 split('?').first：很多源用 `/api/play?type=m3u8` 或
/// `/live/channel` 这类无扩展名地址返回清单。
bool looksLikeHls(String url) {
  final lower = url.toLowerCase();
  return lower.contains('m3u8') ||
      lower.contains('mpegurl') ||
      lower.contains('/hls/') ||
      lower.contains('type=hls');
}

/// 按扩展名推断 MIME，供投屏 hint 使用。
///
/// 2026-11-07（M1-1）起**不再以 `video/mp4` 兜底**：无扩展名且不像 HLS 的
/// 地址返回空串（投屏侧三级判定的 hint 只在「有真实证据」时才可信，
/// 无证据交给 URL 嗅探，绝不静默按 mp4 投）。
String mimeTypeForMedia(String url, {bool? isHls}) {
  final hls = isHls ?? looksLikeHls(url);
  if (hls) return 'application/vnd.apple.mpegurl';
  final path = url.toLowerCase().split('?').first;
  if (path.endsWith('.mp4') || path.endsWith('.m4v')) return 'video/mp4';
  if (path.endsWith('.mkv')) return 'video/x-matroska';
  if (path.endsWith('.avi')) return 'video/x-msvideo';
  if (path.endsWith('.ts')) return 'video/mp2t';
  if (path.endsWith('.flv')) return 'video/x-flv';
  if (path.endsWith('.mov')) return 'video/quicktime';
  if (path.endsWith('.webm')) return 'video/webm';
  if (path.endsWith('.mp3')) return 'audio/mpeg';
  if (path.endsWith('.m4a') || path.endsWith('.aac')) return 'audio/mp4';
  return '';
}

/// 把「分集原始 URL + 源级 headers + 用户设置」收敛成一份解析结果。
///
/// [sourceHeaders] 传 `SourceConfig.headers`；缺 UA 时补 `SourceImporter.defaultUa`。
/// [adFilterEnabled] 为 false 时 [ResolvedPlayback.needsProxy] 恒为 false，
/// 默认播放路径因此永远是「直链 + mpv 头注入」，不会被去广告代理破坏。
ResolvedPlayback resolvePlayback({
  required String rawUrl,
  required Map<String, String> sourceHeaders,
  required bool adFilterEnabled,
  String? defaultUa,
  String baseUrl = '',
}) {
  final headers = <String, String>{...sourceHeaders};
  final hasUa = headers.keys.any((k) => k.toLowerCase() == 'user-agent');
  if (!hasUa) {
    headers['User-Agent'] = defaultUa ?? SourceImporter.defaultUa;
  }
  var url = normalizeMediaUrl(rawUrl);
  // 部分 spider / CMS 源给的是相对播放地址（/play/xxx）。解析层没有
  // baseUrl 时只保留原样，这里用源 api 兜底补全，不让分集凭空消失。
  if (url.isNotEmpty &&
      !url.startsWith('http://') &&
      !url.startsWith('https://') &&
      baseUrl.isNotEmpty) {
    final base = Uri.tryParse(baseUrl);
    if (base != null && base.hasScheme) {
      try {
        url = base
            .resolve(url.startsWith('//') ? '${base.scheme}:$url' : url)
            .toString();
      } catch (_) {}
    }
  }
  final isHls = looksLikeHls(url);
  return ResolvedPlayback(
    url: url,
    headers: Map.unmodifiable(headers),
    isHls: isHls,
    needsProxy: adFilterEnabled && isHls,
    mimeType: mimeTypeForMedia(url, isHls: isHls),
  );
}

/// 大小写不敏感取头：配置里写 `referer` / `REFERER` 都应生效。
String? headerOf(Map<String, String> headers, String wanted) {
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == wanted.toLowerCase()) return entry.value;
  }
  return null;
}

/// 投屏用的「防盗链信号头」。
///
/// 只有带 Referer 或自定义 UA 的源才需要经本机代理中转，让电视能拉流；
/// 仅默认 UA 的源直投，保住「投屏后手机可离开前台」的体验。
/// 与本地播放共用同一份 [ResolvedPlayback.headers]，避免口径分叉。
Map<String, String> castHeadersOf(
  ResolvedPlayback playback, {
  String? defaultUa,
}) {
  final headers = playback.headers;
  final hasReferer = (headerOf(headers, 'referer') ?? '').trim().isNotEmpty;
  final ua = headerOf(headers, 'user-agent') ?? '';
  final customUa = ua.isNotEmpty && ua != (defaultUa ?? SourceImporter.defaultUa);
  return (hasReferer || customUa) ? headers : const <String, String>{};
}
