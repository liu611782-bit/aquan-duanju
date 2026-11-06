import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'source_adapter.dart';
import 'source_import.dart';

/// jx 解析引擎：播放地址不是直链（或站点声明 jx==1）时，并发轮询配置里的
/// type=1 JSON 解析接口，先返回可用直链者胜（xiugou-tv parse_engine 同语义）。
///
/// 只支持 JSON 解析接口（`{parseApi}{播放页}` → `{"url": …}`）；WebView 网页
/// 嗅探不做（桌面/Android 均重，二期再议）。
class ParseEngine {
  ParseEngine({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static final RegExp _directMedia =
      RegExp(r'\.(m3u8|mp4|mkv|flv|avi|mov|ts|m4s|mpd)(\?|#|$)',
          caseSensitive: false);

  /// 播放地址是否可直接交给播放器（不需要 jx）。
  ///
  /// 旧实现只认带媒体扩展名的地址，会把 `/api/play?type=m3u8`、
  /// `/live/channel` 这类合法流误判成「需要解析」；解析接口为空时反而
  /// 原样丢给 mpv 卡住。这里放宽为「明确是流」即直链。
  static bool isDirectMedia(String url) {
    if (_directMedia.hasMatch(url)) return true;
    final lower = url.toLowerCase();
    if (!lower.startsWith('http')) return false;
    return lower.contains('m3u8') ||
        lower.contains('mpegurl') ||
        lower.contains('/hls/') ||
        lower.contains('type=hls');
  }

  /// 是否需要走解析：显式 jx 标记，或地址不是直链。
  static bool needsParse(String url, {bool jx = false}) =>
      jx || !isDirectMedia(url);

  /// 并发轮询解析接口；全部失败返回 null（调用方回退原地址 + 诊断）。
  ///
  /// [playPageUrl] 是播放页/原始地址；解析接口通常按 `{url}{encodeURIComponent(page)}` 拼接。
  /// 内部用独立 CancelToken「先到先得」地打断其余请求，不影响调用方的 [cancel]。
  Future<ParsedMedia?> resolve(
    String playPageUrl, {
    required List<ParseApi> parses,
    Duration perApiTimeout = const Duration(seconds: 6),
    CancelToken? cancel,
  }) async {
    if (parses.isEmpty) return null;
    final internal = CancelToken();
    cancel?.whenCancelled(internal.cancel);
    ParsedMedia? winner;
    await Future.wait(parses.map((p) async {
      if (internal.isCancelled) return;
      try {
        final target = p.url.endsWith('=') || p.url.endsWith('?')
            ? '${p.url}${Uri.encodeQueryComponent(playPageUrl)}'
            : '${p.url}${p.url.contains('?') ? '&' : '?'}url=${Uri.encodeQueryComponent(playPageUrl)}';
        final res = await _client
            .get(Uri.parse(target), headers: {
              'User-Agent': SourceImporter.defaultUa,
            })
            .timeout(perApiTimeout);
        if (res.statusCode != 200) return;
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is! Map) return;
        final url = body['url'];
        if (url is! String || !url.startsWith('http')) return;
        if (winner != null) return;
        winner = ParsedMedia(apiName: p.name, url: url);
        internal.cancel(); // 打断其余解析请求。
      } catch (_) {
        // 单个解析接口失败不影响其它。
      }
    }));
    return winner;
  }

  void close() => _client.close();
}

/// 解析结果。
class ParsedMedia {
  const ParsedMedia({required this.apiName, required this.url});
  final String apiName;
  final String url;
}
