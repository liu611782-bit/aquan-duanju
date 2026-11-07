import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'cast_diagnostics.dart';
import 'cast_media_type.dart';
import 'cast_recipe.dart';
import 'local_media_server.dart';
import 'subtitle_converter.dart';

/// 受保护流直通代理：给电视喂「它拉得动」的 URL。
///
/// 为什么需要：电视拉流时无法自带源站的 Referer/UA/Cookie，带防盗链的
/// 直链、HLS（含嵌套清单/KEY）投过去全是 403/黑屏。由本机代理转发并注入
/// 请求头（playbridge LocalProxyServer / dart_cast MediaProxy 同思路）。
///
/// 与 [LocalMediaServer] 同一套手写 HTTP 约束（ServerSocket + Connection: close，
/// HEAD 的 Content-Length 正确；响应**不附加任何安全头**——部分渲染器见到
/// x-frame-options 会拒播）。
///
/// - `/p/<token>/<fileName>`：token → 登记项（直链 / HLS 清单 / 静态字幕字节）；
///   fileName 来自 CastMediaType（index.m3u8 / stream.ts / video.mp4…），
///   让接收端靠 URL 扩展名选播放器（M1-3；`bare` 配方回退旧裸 URL 形态）；
/// - HLS 清单：改写全部 URI（变体/分片/EXT-X-KEY/EXT-X-MAP/EXT-X-MEDIA 的
///   `URI="..."` 属性与裸行）为新的代理 token，逐级穿透；
/// - 直链/分片：Range 原样转上游，透传 206/Content-Range；
/// - 字幕：SRT 拉取后转 VTT 以静态字节伺服（Chromecast 只认 VTT）。
class CastMediaProxy {
  CastMediaProxy({
    this.defaultPort = 18280,
    this.portAttempts = 20,
    this.hostOverride,
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = const Duration(seconds: 8);
  }

  /// 登记条目上限：HLS 逐级改写会为每个变体/分片/KEY 各注册一条，
  /// 不设上限会随播放时长无限增长。超限按最旧淘汰（LRU，访问即续期）。
  static const int maxEntries = 512;

  /// 清单/字幕等文本体的大小上限：异常源（错误页循环、死循环清单）不撑爆内存。
  static const int maxTextBytes = 2 * 1024 * 1024;

  static final Random _random = Random.secure();

  final int defaultPort;
  final int portAttempts;

  /// 测试注入点：跳过局域网地址探测。
  final String? hostOverride;
  final HttpClient _client;

  ServerSocket? _socket;
  String? _localAddress;
  final Map<String, _ProxyEntry> _entries = <String, _ProxyEntry>{};

  bool get running => _socket != null;
  int? get port => _socket?.port;

  String? get baseUrl {
    final host = _localAddress;
    final server = _socket;
    if (host == null || server == null) return null;
    return 'http://$host:${server.port}';
  }

  /// 启动（幂等）；失败返回 false（拿到不到私网地址/端口全被占）。
  Future<bool> start() async {
    if (_socket != null) return true;
    final host = hostOverride ?? await LocalMediaServer.resolveLanIPv4();
    if (host == null) return false;
    for (var i = 0; i < portAttempts; i++) {
      try {
        final socket =
            await ServerSocket.bind(InternetAddress.anyIPv4, defaultPort + i);
        socket.listen(_handleSocket, onError: (Object _) {});
        _socket = socket;
        _localAddress = host;
        return true;
      } on SocketException {
        continue;
      }
    }
    return false;
  }

  Future<void> stop() async {
    final socket = _socket;
    _socket = null;
    _localAddress = null;
    _entries.clear();
    await socket?.close();
  }

  /// 登记一个媒体 URL，返回代理 URL。清单（.m3u8）会走改写分支。
  ///
  /// URL 形态（M1-3）：`/p/<token>/<fileName>`，fileName 来自
  /// [resolveCastMediaType]（HLS → index.m3u8、.ts → stream.ts、mp4 →
  /// video.mp4…），让接收端靠 URL 扩展名选播放器；[urlSuffixMode] = bare
  /// 时退回旧形态 `/p/<token>`。
  ///
  /// [hintMime] 传调用方已知的媒体 mime（如 `ResolvedPlayback.mimeType`）；
  /// URL 无扩展名且 hint 不足以判定时对上游做一次 8KB 内容嗅探（只发生在
  /// 顶层登记——清单改写产生的子 URL 一律不嗅探，避免逐分片放大）。
  ///
  /// [targetHost] 是目标设备 controlURL 的 host（M0.5 per-device IP）：
  /// 提供时对外 URL 的 host 用「到该设备的路由源 IP」（电视拉得到流的
  /// 地址），探测失败回退全局本机地址。同一媒体投两台设备 = 两个 token
  /// （上游缓存可共享，不影响正确性）。
  Future<String?> register(
    String url, {
    Map<String, String> headers = const {},
    String? targetHost,
    String? hintMime,
    bool live = false,
    CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension,
  }) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    if (!await start()) return null;
    final authority = await _advertisedAuthority(targetHost);
    if (authority == null) return null;
    // 类型判定（三级：hint → 扩展名 → 嗅探上游前 8KB）；嗅探到 HTML/JSON
    // 会抛 CastException（把「错误页不喂电视」前移到登记阶段）。
    final mediaType = await resolveCastMediaType(
      url: uri,
      hintMime: hintMime,
      live: live,
      sniffHead: (u) => _sniffUpstream(u, headers),
    );
    final token = _addToken(_ProxyEntry(
      kind: mediaType.isHls || _isPlaylist(uri)
          ? _ProxyKind.playlist
          : _ProxyKind.stream,
      url: uri,
      headers: Map.of(headers),
      mediaType: mediaType,
      advertisedHost: _hostOfAuthority(authority),
      urlSuffixMode: urlSuffixMode,
    ));
    return _entryUrl(authority, token, mediaType.fileName, urlSuffixMode);
  }

  /// 登记字幕：SRT 拉取转 VTT 静态伺服（URL 带 `subtitle.vtt` 文件名段）；
  /// VTT/其他走 [register] 直通。
  Future<String?> registerSubtitle(String url,
      {Map<String, String> headers = const {},
      String? targetHost,
      CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final isSrt = uri.path.toLowerCase().endsWith('.srt');
    if (!isSrt) {
      return register(url,
          headers: headers,
          targetHost: targetHost,
          urlSuffixMode: urlSuffixMode);
    }
    if (!await start()) return null;
    final authority = await _advertisedAuthority(targetHost);
    if (authority == null) return null;
    try {
      final body = await _fetchText(uri, headers, null);
      final vtt = utf8.encode(srtToVtt(body));
      final token = _addToken(_ProxyEntry(
        kind: _ProxyKind.static,
        bytes: vtt,
        contentType: 'text/vtt',
        mediaType: const CastMediaType(
          mime: 'text/vtt',
          fileName: 'subtitle.vtt',
          kind: CastMediaKind.unknown,
        ),
        advertisedHost: _hostOfAuthority(authority),
        urlSuffixMode: urlSuffixMode,
      ));
      return _entryUrl(authority, token, 'subtitle.vtt', urlSuffixMode);
    } catch (_) {
      return null;
    }
  }

  /// 对外登记 URL：withExtension → `/p/<token>/<fileName>`，bare → `/p/<token>`。
  static String _entryUrl(
      String authority, String token, String fileName, CastUrlSuffixMode mode) {
    final suffix = mode == CastUrlSuffixMode.bare ? '' : '/$fileName';
    return 'http://$authority/p/$token$suffix';
  }

  /// 上游 8KB 嗅探（带登记时的源站请求头；只用于顶层登记的类型判定）。
  Future<List<int>?> _sniffUpstream(Uri uri, Map<String, String> headers) async {
    try {
      final req = await _client.openUrl('GET', uri);
      headers.forEach(req.headers.set);
      req.headers.set('Range', 'bytes=0-8191');
      final res = await req.close().timeout(const Duration(seconds: 4));
      if (res.statusCode >= 400) return null;
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
        if (builder.length >= 8192) break; // 上游不理 Range 时止步 8KB
      }
      return builder.takeBytes();
    } catch (_) {
      return null;
    }
  }

  /// 该 token 对外广播的 authority（`host:port`）：目标设备的路由源 IP
  /// 优先，回退全局本机地址（M0.5 per-device IP；服务端 bind 仍 anyIPv4，
  /// 改的只是广播出去的 URL host）。
  Future<String?> _advertisedAuthority(String? targetHost) async {
    final server = _socket;
    if (server == null) return null;
    if (targetHost != null && targetHost.isNotEmpty) {
      final routed = await LocalMediaServer.resolveRouteSourceIp(targetHost);
      if (routed != null) return '$routed:${server.port}';
    }
    final local = _localAddress;
    return local == null ? null : '$local:${server.port}';
  }

  /// 从 `host:port`（或裸 host）里取 host 段（本服务只产生 IPv4 host）。
  static String? _hostOfAuthority(String authority) {
    final idx = authority.lastIndexOf(':');
    return idx <= 0 ? authority : authority.substring(0, idx);
  }

  // ---------------------------------------------------------------------------
  // 请求处理
  // ---------------------------------------------------------------------------

  Future<void> _handleSocket(Socket socket) async {
    final buffer = BytesBuilder(copy: true);
    try {
      await for (final chunk in socket) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final headerEnd = _indexOfHeaderEnd(bytes);
        if (headerEnd < 0) {
          if (bytes.length > LocalMediaServer.maxHeaderBytes) break;
          continue;
        }
        await _respond(socket, utf8.decode(bytes.sublist(0, headerEnd)));
        return;
      }
    } catch (_) {
      // 电视切集/取消会直接断连，属正常。
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<void> _respond(Socket socket, String header) async {
    final lines = header.split('\r\n');
    if (lines.isEmpty) return;
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) return;
    final method = requestLine[0].toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      // 只读代理：POST 等一律拒绝（防把代理当转发器滥用）。
      _traceRequest(requestLine[1], method, null, null, 405, 0);
      await _writeStatus(socket, 405, 'Method Not Allowed');
      return;
    }
    final rawTarget = requestLine[1];
    String? range;
    String? userAgent;
    String? hostHeader;
    bool contentFeaturesRequested = false;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toLowerCase();
      if (key == 'range') {
        range = line.substring(idx + 1).trim();
      } else if (key == 'user-agent') {
        userAgent = line.substring(idx + 1).trim();
      } else if (key == 'host') {
        hostHeader = line.substring(idx + 1).trim();
      } else if (key == 'getcontentfeatures.dlna.org') {
        // playbridge 条件化写法：设备显式索要才回 contentFeatures。
        contentFeaturesRequested = line.substring(idx + 1).trim() == '1';
      }
    }
    final path = Uri.tryParse(rawTarget)?.path ?? '';
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    // M1-3：路由放宽到 `>= 2` 段——`/p/<token>/<fileName>` 的末段只是让
    // URL 带扩展名，token 恒取 segments[1]；旧形态 `/p/<token>` 继续兼容。
    final token =
        segments.length >= 2 && segments.first == 'p' ? segments[1] : null;
    final entry = token != null ? _entries[token] : null;
    if (entry != null) {
      // LRU 续期：正在看的分片不被新注册的分片挤掉。
      _entries.remove(token);
      _entries[token!] = entry;
    }
    if (entry == null) {
      _traceRequest(rawTarget, method, range, userAgent, 404, 0);
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final Future<(int, int)> served;
    switch (entry.kind) {
      case _ProxyKind.static:
        served = _serveStatic(socket, method, entry);
      case _ProxyKind.playlist:
        served = _servePlaylist(
            socket, method, entry, hostHeader, contentFeaturesRequested);
      case _ProxyKind.stream:
        served =
            _serveStream(socket, method, entry, range, contentFeaturesRequested);
    }
    try {
      final (status, bytes) = await served;
      _traceRequest(rawTarget, method, range, userAgent, status, bytes);
    } catch (_) {
      _traceRequest(rawTarget, method, range, userAgent, 502, 0);
      try {
        await _writeStatus(socket, 502, 'Bad Gateway');
      } catch (_) {}
    }
  }

  /// 静态字节（转换后的 VTT 字幕）；返回 (状态码, 发给电视的字节数) 供埋点。
  ///
  /// 字幕是 text/*：transferMode 走 Interactive 且不给 contentFeatures
  /// （M1-9 playbridge 条件化规则）。
  Future<(int, int)> _serveStatic(Socket socket, String method, _ProxyEntry entry) async {
    final bytes = entry.bytes!;
    final head = StringBuffer()
      ..write('HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: ${entry.contentType}\r\n')
      ..write('Content-Length: ${bytes.length}\r\n')
      ..write(dlnaResponseHeaders(media: false, acceptRanges: false))
      ..write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));
    if (method != 'HEAD') socket.add(bytes);
    await socket.flush();
    return (200, method == 'HEAD' ? 0 : bytes.length);
  }

  /// HLS 清单：拉取文本 → 重写 URI 为代理 token → 伺服；返回供埋点。
  ///
  /// Content-Type 用登记时 [CastMediaType].mime（与 DIDL 同源，M1-3）。
  /// 清单路由不答 Range → **不声明** Accept-Ranges（诚实化，M1-9）。
  ///
  /// 子 URL 的 host 按「两段机制」（review §8.3）选：优先本次请求的 Host
  /// 头——电视能取到父 URL 就必然可达同一 host:port；无 Host 头退回登记
  /// 时设备 IP；最后退回全局本机地址。服务端 bind 仍是 anyIPv4，只改
  /// 「广播出去的 URL host」。
  Future<(int, int)> _servePlaylist(Socket socket, String method,
      _ProxyEntry entry, String? hostHeader, bool contentFeaturesRequested) async {
    final text = await _fetchText(entry.url!, entry.headers, null);
    final rewritten = await _rewritePlaylist(text, entry.url!, entry.headers,
        _rewriteAuthority(hostHeader, entry.advertisedHost),
        urlSuffixMode: entry.urlSuffixMode);
    final bytes = utf8.encode(rewritten);
    final head = StringBuffer()
      ..write('HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: ${entry.mediaType.mime}\r\n')
      ..write('Content-Length: ${bytes.length}\r\n')
      ..write(dlnaResponseHeaders(
        media: true,
        contentFeaturesRequested: contentFeaturesRequested,
        acceptRanges: false,
      ))
      ..write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));
    if (method != 'HEAD') socket.add(bytes);
    await socket.flush();
    return (200, method == 'HEAD' ? 0 : bytes.length);
  }

  /// 直链/分片：Range 透传，状态码与 Content-Range 原样回给电视。
  /// 返回 (状态码, 转发给电视的字节数) 供埋点。
  ///
  /// Content-Type 用登记时 [CastMediaType].mime（kind 已知时）——上游把
  /// .ts 伪装成 image/png 也按 URL 证据改写（M1-3 伪装规则）；kind 未知
  /// 时回退上游声明的类型。
  /// `Accept-Ranges` 只在上游真的答 206 时声明（M1-9 诚实化）。
  ///
  /// 加固：Range 格式校验（非法 416）、上游 ≥400 归一 502、GET 先嗅探
  /// 前 512B——防盗链错误页/失效页（HTML/XML/清单文本）不喂给电视（防黑屏）。
  Future<(int, int)> _serveStream(Socket socket, String method,
      _ProxyEntry entry, String? range, bool contentFeaturesRequested) async {
    if (range != null && !validRangeHeader(range)) {
      await _writeStatus(socket, 416, 'Range Not Satisfiable');
      return (416, 0);
    }
    final req = await _client.openUrl('GET', entry.url!);
    entry.headers.forEach(req.headers.set);
    if (range != null) req.headers.set('Range', range);
    final res = await req.close();

    Future<void> drainUpstream() =>
        res.drain<void>().timeout(const Duration(seconds: 2), onTimeout: () {});

    if (res.statusCode >= 400) {
      await drainUpstream();
      await _writeStatus(socket, 502, 'Bad Gateway');
      return (502, 0);
    }

    final contentType = entry.mediaType.kind == CastMediaKind.unknown
        ? (res.headers.contentType?.toString() ??
            mimeTypeForPath(entry.url!.path))
        : entry.mediaType.mime;
    final head = StringBuffer()
      ..write('HTTP/1.1 ${res.statusCode} ${res.reasonPhrase}\r\n')
      ..write('Content-Type: $contentType\r\n')
      // 诚实化：上游没答 206（整流 200）就不声明 byte-seek（review §8.5）。
      ..write(dlnaResponseHeaders(
        media: true,
        contentFeaturesRequested: contentFeaturesRequested,
        acceptRanges: res.statusCode == 206,
      ));
    final contentLength = res.headers.value(HttpHeaders.contentLengthHeader);
    if (contentLength != null) head.write('Content-Length: $contentLength\r\n');
    final contentRange = res.headers.value('content-range');
    if (contentRange != null) head.write('Content-Range: $contentRange\r\n');
    head.write('Connection: close\r\n\r\n');

    if (method == 'HEAD') {
      socket.add(utf8.encode(head.toString()));
      await drainUpstream();
      await socket.flush();
      return (res.statusCode, 0);
    }
    // 嗅探 + 转发（单订阅流只听一次）：先攒前 512B 判文本特征（二进制媒体
    // 永远放行），之后的数据块在回调里直接写 socket。命中错误页 → 取消订阅
    // 并回 502（防黑屏）。
    var served = 0;
    final peeked = BytesBuilder(copy: false);
    final peekReady = Completer<void>();
    final upstreamDone = Completer<void>();
    List<int>? remainder;
    late final StreamSubscription<List<int>> sub;
    sub = res.listen((chunk) {
      served += chunk.length;
      if (peekReady.isCompleted) {
        socket.add(chunk);
        return;
      }
      final need = 512 - peeked.length;
      if (chunk.length <= need) {
        peeked.add(chunk);
        if (peeked.length >= 512) peekReady.complete();
      } else {
        peeked.add(chunk.sublist(0, need));
        remainder = chunk.sublist(need);
        peekReady.complete();
      }
    }, onError: (Object e, StackTrace st) {
      if (!peekReady.isCompleted) peekReady.complete();
      upstreamDone.completeError(e, st);
    }, onDone: () {
      if (!peekReady.isCompleted) peekReady.complete();
      if (!upstreamDone.isCompleted) upstreamDone.complete();
    });
    await peekReady.future;

    final bytes = peeked.takeBytes();
    if (_looksLikeTextDocument(bytes)) {
      await sub.cancel();
      await _writeStatus(socket, 502, 'Bad Gateway');
      return (502, 0);
    }
    socket.add(utf8.encode(head.toString()));
    socket.add(bytes);
    final rest = remainder;
    if (rest != null) socket.add(rest);
    await upstreamDone.future;
    await socket.flush();
    return (res.statusCode, served);
  }

  /// 文本文档特征：清单/错误页/裸 URL。只看开头，二进制媒体不会命中。
  static bool _looksLikeTextDocument(List<int> bytes) {
    if (bytes.isEmpty) return false;
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final lower = text.trimLeft().toLowerCase();
    return lower.startsWith('#extm3u') ||
        lower.startsWith('<!doctype') ||
        lower.startsWith('<html') ||
        lower.startsWith('<?xml') ||
        lower.startsWith('<mpd') ||
        lower.startsWith('http://') ||
        lower.startsWith('https://');
  }

  /// 客户端 Range 头格式校验：`bytes=s-e` / `bytes=s-` / `bytes=-n`，
  /// 多段/带空格/非数字一律非法（不透传，避免上游行为不可控）。
  static bool validRangeHeader(String value) {
    final m = RegExp(r'^bytes=([0-9]{0,19})-([0-9]{0,19})$').firstMatch(value);
    if (m == null) return false;
    final startText = m.group(1)!;
    final endText = m.group(2)!;
    if (startText.isEmpty) return endText.isNotEmpty && int.parse(endText) > 0;
    final start = int.parse(startText);
    return endText.isEmpty || int.parse(endText) >= start;
  }

  // ---------------------------------------------------------------------------
  // 清单改写
  // ---------------------------------------------------------------------------

  Future<String> _rewritePlaylist(String text, Uri base,
      Map<String, String> headers, String authority,
      {CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    final out = StringBuffer();
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        out.writeln();
        continue;
      }
      if (line.startsWith('#')) {
        out.writeln(await _rewriteUriAttributes(line, base, headers, authority,
            urlSuffixMode: urlSuffixMode));
        continue;
      }
      out.writeln(
          await _childUrl(line, base, headers, authority, urlSuffixMode) ??
              line);
    }
    return out.toString();
  }

  Future<String> _rewriteUriAttributes(
      String line, Uri base, Map<String, String> headers, String authority,
      {CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    final uris =
        RegExp('URI="([^"]+)"').allMatches(line).map((m) => m.group(1)!).toList();
    var result = line;
    for (final uri in uris) {
      final proxied =
          await _childUrl(uri, base, headers, authority, urlSuffixMode);
      if (proxied != null) result = result.replaceFirst('URI="$uri"', 'URI="$proxied"');
    }
    return result;
  }

  Future<String?> _childUrl(String rawUri, Uri base, Map<String, String> headers,
      String authority, CastUrlSuffixMode urlSuffixMode) async {
    final resolved = _resolveAgainst(rawUri, base);
    if (resolved == null) return null;
    return _registerWithAuthority(resolved, headers, authority,
        urlSuffixMode: urlSuffixMode);
  }

  /// 子 URL 改写用的 authority（`host:port`）：优先电视本次请求的 Host 头，
  /// 退回登记时设备 IP [entryHost]，最后退回全局本机地址。
  ///
  /// Host 头没带端口（或登记 IP 是裸 host）时补上本服务端口——本服务
  /// 不可能跑在 80 端口语义之外的「无端口」形态，补齐才是可达地址。
  String _rewriteAuthority(String? requestHost, String? entryHost) {
    final server = _socket;
    if (server == null) return '';
    if (requestHost != null && requestHost.isNotEmpty) {
      return requestHost.contains(':')
          ? requestHost
          : '$requestHost:${server.port}';
    }
    if (entryHost != null && entryHost.isNotEmpty) {
      return entryHost.contains(':') ? entryHost : '$entryHost:${server.port}';
    }
    final local = _localAddress;
    return local == null ? '' : '$local:${server.port}';
  }

  /// 登记一个上游 URL 并用给定 authority 生成对外 URL（清单子 URL 专用：
  /// host 已由父请求/登记时的设备决定，不再按目标探测）。
  /// [authority] 为空时退回 [register] 的默认解析。
  /// 子 URL **不做内容嗅探**（逐分片放大不可接受）；类型只按 URL 扩展名与
  /// 清单子串判定，URL 形态继承父条目的 [urlSuffixMode]（M1-3）。
  Future<String?> _registerWithAuthority(
      Uri uri, Map<String, String> headers, String authority,
      {CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    if (authority.isEmpty) {
      return register(uri.toString(),
          headers: headers, urlSuffixMode: urlSuffixMode);
    }
    if (!await start()) return null;
    final mediaType = castMediaTypeFromUrlPath(uri);
    final token = _addToken(_ProxyEntry(
      kind: mediaType.isHls || _isPlaylist(uri)
          ? _ProxyKind.playlist
          : _ProxyKind.stream,
      url: uri,
      headers: Map.of(headers),
      mediaType: mediaType,
      advertisedHost: _hostOfAuthority(authority),
      urlSuffixMode: urlSuffixMode,
    ));
    return _entryUrl(authority, token, mediaType.fileName, urlSuffixMode);
  }

  // ---------------------------------------------------------------------------
  // 工具
  // ---------------------------------------------------------------------------

  String _addToken(_ProxyEntry entry) {
    // 随机 token（SecureRandom 24B base64Url）：旧「时间戳+序号」在局域网
    // 内可预测枚举，任何设备都能拉走登记过的受保护流。
    final bytes =
        List<int>.generate(24, (_) => _random.nextInt(256), growable: false);
    final token = base64Url.encode(bytes).replaceAll('=', '');
    _entries[token] = entry;
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first); // LinkedHashMap 保序：最旧先出
    }
    return token;
  }

  Future<String> _fetchText(
      Uri uri, Map<String, String> headers, String? range) async {
    final req = await _client.openUrl('GET', uri);
    headers.forEach(req.headers.set);
    if (range != null) req.headers.set('Range', range);
    final res = await req.close();
    if (res.statusCode >= 400) {
      unawaited(
          res.drain<void>().timeout(const Duration(seconds: 2), onTimeout: () {}));
      throw HttpException('upstream ${res.statusCode}');
    }
    // 大小上限：异常源（循环清单/超大错误页）不撑爆内存。
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
      if (builder.length > maxTextBytes) {
        throw HttpException('text body exceeds $maxTextBytes bytes');
      }
    }
    return utf8.decode(builder.takeBytes(), allowMalformed: true);
  }

  Uri? _resolveAgainst(String ref, Uri base) {
    try {
      final parsed = Uri.tryParse(ref);
      if (parsed == null) return null;
      if (parsed.hasScheme && parsed.host.isNotEmpty) return parsed;
      return base.resolve(ref);
    } catch (_) {
      return null;
    }
  }

  static bool _isPlaylist(Uri uri) {
    final s = uri.toString().toLowerCase();
    return uri.path.toLowerCase().endsWith('.m3u8') ||
        s.contains('.m3u8') ||
        uri.path.toLowerCase().endsWith('.m3u');
  }

  static int _indexOfHeaderEnd(Uint8List bytes) {
    for (var i = 0; i + 3 < bytes.length; i++) {
      if (bytes[i] == 13 &&
          bytes[i + 1] == 10 &&
          bytes[i + 2] == 13 &&
          bytes[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  static Future<void> _writeStatus(Socket socket, int code, String reason) async {
    socket.add(utf8.encode(
      'HTTP/1.1 $code $reason\r\n'
      'Content-Length: 0\r\n'
      'Connection: close\r\n\r\n',
    ));
    await socket.flush();
  }

  /// 电视取流埋点（M0 纯采集；不改变任何响应行为）。
  static void _traceRequest(String url, String method, String? range,
      String? userAgent, int status, int bytes) {
    CastDiagnostics.instance.recordMediaRequest(MediaRequestTrace(
      url: url,
      method: method,
      range: range,
      userAgent: userAgent,
      statusCode: status,
      bytesServed: bytes,
      source: 'proxy',
    ));
  }
}

enum _ProxyKind { static, playlist, stream }

class _ProxyEntry {
  _ProxyEntry({
    required this.kind,
    this.url,
    this.headers = const {},
    this.bytes,
    this.contentType = 'application/octet-stream',
    this.mediaType = CastMediaType.unknown,
    this.advertisedHost,
    this.urlSuffixMode = CastUrlSuffixMode.withExtension,
  });

  final _ProxyKind kind;
  final Uri? url;
  final Map<String, String> headers;
  final List<int>? bytes;
  final String contentType;

  /// 登记时解析出的规范媒体类型（M1-3）：mime 用于响应 Content-Type
  /// （与 DIDL 同源；kind 已知时覆盖上游伪装的类型），fileName 用于
  /// 对外 URL 的扩展名段。
  final CastMediaType mediaType;

  /// 登记时对外广播的设备 IP（M0.5）：清单子 URL 在电视请求时才改写，
  /// 无 Host 头时退回这里（review §8.3 两段机制的第二段）。
  final String? advertisedHost;

  /// URL 形态（M1-3）：清单改写的子 URL 继承父条目（bare 父 → bare 子）。
  final CastUrlSuffixMode urlSuffixMode;
}
