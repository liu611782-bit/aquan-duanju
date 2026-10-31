import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
/// - `/p/<token>`：token → 登记项（直链 / HLS 清单 / 静态字幕字节）；
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
  Future<String?> register(String url, {Map<String, String> headers = const {}}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    if (!await start()) return null;
    final base = baseUrl;
    if (base == null) return null;
    final token = _addToken(_ProxyEntry(
      kind: _isPlaylist(uri) ? _ProxyKind.playlist : _ProxyKind.stream,
      url: uri,
      headers: Map.of(headers),
    ));
    return '$base/p/$token';
  }

  /// 登记字幕：SRT 拉取转 VTT 静态伺服；VTT/其他走直通。
  Future<String?> registerSubtitle(String url,
      {Map<String, String> headers = const {}}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme) return null;
    final isSrt = uri.path.toLowerCase().endsWith('.srt');
    if (!isSrt) return register(url, headers: headers);
    if (!await start()) return null;
    final base = baseUrl;
    if (base == null) return null;
    try {
      final body = await _fetchText(uri, headers, null);
      final vtt = utf8.encode(srtToVtt(body));
      final token = _addToken(_ProxyEntry(
        kind: _ProxyKind.static,
        bytes: vtt,
        contentType: 'text/vtt',
      ));
      return '$base/p/$token';
    } catch (_) {
      return null;
    }
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
      await _writeStatus(socket, 405, 'Method Not Allowed');
      return;
    }
    String? range;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'range') {
        range = line.substring(idx + 1).trim();
      }
    }
    final path = Uri.tryParse(requestLine[1])?.path ?? '';
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    final token = segments.length == 2 && segments.first == 'p'
        ? segments[1]
        : null;
    final entry = token != null ? _entries[token] : null;
    if (entry != null) {
      // LRU 续期：正在看的分片不被新注册的分片挤掉。
      _entries.remove(token);
      _entries[token!] = entry;
    }
    if (entry == null) {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    try {
      switch (entry.kind) {
        case _ProxyKind.static:
          await _serveStatic(socket, method, entry);
        case _ProxyKind.playlist:
          await _servePlaylist(socket, method, entry);
        case _ProxyKind.stream:
          await _serveStream(socket, method, entry, range);
      }
    } catch (_) {
      try {
        await _writeStatus(socket, 502, 'Bad Gateway');
      } catch (_) {}
    }
  }

  /// 静态字节（转换后的 VTT）。
  Future<void> _serveStatic(Socket socket, String method, _ProxyEntry entry) async {
    final bytes = entry.bytes!;
    final head = StringBuffer()
      ..write('HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: ${entry.contentType}\r\n')
      ..write('Content-Length: ${bytes.length}\r\n')
      ..write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));
    if (method != 'HEAD') socket.add(bytes);
    await socket.flush();
  }

  /// HLS 清单：拉取文本 → 重写 URI 为代理 token → 伺服。
  Future<void> _servePlaylist(Socket socket, String method, _ProxyEntry entry) async {
    final text = await _fetchText(entry.url!, entry.headers, null);
    final rewritten = await _rewritePlaylist(text, entry.url!, entry.headers);
    final bytes = utf8.encode(rewritten);
    final head = StringBuffer()
      ..write('HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: application/vnd.apple.mpegurl\r\n')
      ..write('Content-Length: ${bytes.length}\r\n')
      ..write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));
    if (method != 'HEAD') socket.add(bytes);
    await socket.flush();
  }

  /// 直链/分片：Range 透传，状态码与 Content-Range 原样回给电视。
  ///
  /// 加固：Range 格式校验（非法 416）、上游 ≥400 归一 502、GET 先嗅探
  /// 前 512B——防盗链错误页/失效页（HTML/XML/清单文本）不喂给电视（防黑屏）。
  Future<void> _serveStream(
      Socket socket, String method, _ProxyEntry entry, String? range) async {
    if (range != null && !validRangeHeader(range)) {
      await _writeStatus(socket, 416, 'Range Not Satisfiable');
      return;
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
      return;
    }

    final head = StringBuffer()
      ..write('HTTP/1.1 ${res.statusCode} ${res.reasonPhrase}\r\n')
      ..write('Content-Type: '
          '${res.headers.contentType?.toString() ?? mimeTypeForPath(entry.url!.path)}\r\n')
      ..write('Accept-Ranges: bytes\r\n');
    final contentLength = res.headers.value(HttpHeaders.contentLengthHeader);
    if (contentLength != null) head.write('Content-Length: $contentLength\r\n');
    final contentRange = res.headers.value('content-range');
    if (contentRange != null) head.write('Content-Range: $contentRange\r\n');
    head.write('Connection: close\r\n\r\n');

    if (method == 'HEAD') {
      socket.add(utf8.encode(head.toString()));
      await drainUpstream();
      await socket.flush();
      return;
    }
    // 嗅探 + 转发（单订阅流只听一次）：先攒前 512B 判文本特征（二进制媒体
    // 永远放行），之后的数据块在回调里直接写 socket。命中错误页 → 取消订阅
    // 并回 502（防黑屏）。
    final peeked = BytesBuilder(copy: false);
    final peekReady = Completer<void>();
    final upstreamDone = Completer<void>();
    List<int>? remainder;
    late final StreamSubscription<List<int>> sub;
    sub = res.listen((chunk) {
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
      return;
    }
    socket.add(utf8.encode(head.toString()));
    socket.add(bytes);
    final rest = remainder;
    if (rest != null) socket.add(rest);
    await upstreamDone.future;
    await socket.flush();
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

  Future<String> _rewritePlaylist(String text, Uri base, Map<String, String> headers) async {
    final out = StringBuffer();
    for (final rawLine in const LineSplitter().convert(text)) {
      final line = rawLine.trim();
      if (line.isEmpty) {
        out.writeln();
        continue;
      }
      if (line.startsWith('#')) {
        out.writeln(await _rewriteUriAttributes(line, base, headers));
        continue;
      }
      out.writeln(await _childUrl(line, base, headers) ?? line);
    }
    return out.toString();
  }

  Future<String> _rewriteUriAttributes(
      String line, Uri base, Map<String, String> headers) async {
    final uris =
        RegExp('URI="([^"]+)"').allMatches(line).map((m) => m.group(1)!).toList();
    var result = line;
    for (final uri in uris) {
      final proxied = await _childUrl(uri, base, headers);
      if (proxied != null) result = result.replaceFirst('URI="$uri"', 'URI="$proxied"');
    }
    return result;
  }

  Future<String?> _childUrl(String rawUri, Uri base, Map<String, String> headers) async {
    final resolved = _resolveAgainst(rawUri, base);
    if (resolved == null) return null;
    return register(resolved.toString(), headers: headers);
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
}

enum _ProxyKind { static, playlist, stream }

class _ProxyEntry {
  _ProxyEntry({
    required this.kind,
    this.url,
    this.headers = const {},
    this.bytes,
    this.contentType = 'application/octet-stream',
  });

  final _ProxyKind kind;
  final Uri? url;
  final Map<String, String> headers;
  final List<int>? bytes;
  final String contentType;
}
