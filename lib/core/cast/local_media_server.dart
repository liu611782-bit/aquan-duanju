import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 本地 HTTP 媒体服务：把本机文件以「token URL」的形式喂给电视。
///
/// 为什么需要：DLNA 电视只能拉 HTTP 直链，本地下载的剧集没有公网地址。
///
/// 实现要点（对齐 UPnPCast `LocalFileServer`）：
/// - 绑定 `anyIPv4`（不是 127.0.0.1，电视要访问）；
/// - 端口从 [defaultPort] 起逐个探测，避开被占用；
/// - URL 用一次性 token，**不暴露真实路径**；token 表按 LRU 淘汰；
/// - 支持 `Range`（拖动进度必须）、`HEAD`（部分电视先探长度）；
/// - 按扩展名推断 `Content-Type`（电视对 `application/octet-stream` 常常拒播）。
///
/// 这里没有用 `dart:io` 的 [HttpServer]：它在 HEAD 请求上会把
/// `Content-Length` 强制归零，而电视探测长度恰恰依赖这个头。改用
/// [ServerSocket] 手写响应，`Connection: close` 一请求一连接，简单可控。

/// DLNA 响应头 + 宽松 CORS（本地媒体服务 / 投屏代理 / 网页投屏共用）。
///
/// 严格校验 DIDL/响应头的接收端（WMP、QQLiveTV、Hisilicon 等）依赖
/// `transferMode` / `contentFeatures` / `realTimeInfo`；CORS 允许局域网网页
/// 投屏页里的 `<video>` 跨域拉流。
///
/// 注意：这里只加 DLNA 与**放宽型** CORS 头，**不加** `x-frame-options`、
/// `x-content-type-options` 之类的限制性安全头——部分渲染器见到会拒播
/// （见 cast-contract.md P0「零安全头」语义，既有测试断言这些头必须缺席）。
const String kDlnaResponseHeaders = 'transferMode.dlna.org: Streaming\r\n'
    'contentFeatures.dlna.org: DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
    'DLNA.ORG_FLAGS=01700000000000000000000000000000\r\n'
    'realTimeInfo.dlna.org: DLNA.ORG_TLAG=*\r\n'
    'Access-Control-Allow-Origin: *\r\n';

class LocalMediaServer {
  LocalMediaServer({
    this.defaultPort = 18080,
    this.portAttempts = 20,
    this.hostOverride,
  });

  static const int maxEntries = 128;
  static const int maxHeaderBytes = 16 * 1024;

  final int defaultPort;
  final int portAttempts;

  /// 测试注入点：跳过局域网地址探测（单测里拿不到私网地址）。
  final String? hostOverride;

  ServerSocket? _socket;
  final Map<String, String> _tokens = <String, String>{};
  final List<String> _order = <String>[];

  bool get running => _socket != null;

  int? get port => _socket?.port;

  /// 形如 `http://192.168.1.7:18080`；未启动时为 null。
  String? get baseUrl {
    final host = _localAddress;
    final server = _socket;
    if (host == null || server == null) return null;
    return 'http://$host:${server.port}';
  }

  String? _localAddress;

  /// 启动服务（幂等）。
  Future<bool> start() async {
    if (_socket != null) return true;
    final host = hostOverride ?? await _resolveLocalAddress();
    if (host == null) return false;
    for (var i = 0; i < portAttempts; i++) {
      final candidate = defaultPort + i;
      try {
        final socket = await ServerSocket.bind(InternetAddress.anyIPv4, candidate);
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
    _tokens.clear();
    _order.clear();
    await socket?.close();
  }

  /// 把一个文件登记进服务，返回可直接投给电视的 URL。
  ///
  /// 服务未启动时自动启动；启动失败返回 null。
  Future<String?> urlFor(String filePath) async {
    if (!await start()) return null;
    final token = _register(filePath);
    final base = baseUrl;
    if (base == null) return null;
    return '$base/m/$token';
  }

  String _register(String filePath) {
    _order.remove(filePath);
    _order.insert(0, filePath);
    while (_order.length > maxEntries) {
      final dropped = _order.removeLast();
      _tokens.removeWhere((_, path) => path == dropped);
    }
    for (final entry in _tokens.entries) {
      if (entry.value == filePath) return entry.key;
    }
    final token = _newToken();
    _tokens[token] = filePath;
    return token;
  }

  static final Random _random = Random.secure();

  /// 随机 token（SecureRandom 24B base64Url）：局域网内不可猜测，
  /// 防止非目标设备枚举 token 拉取本机文件。旧「时间戳+序号」可预测，已弃。
  static String _newToken() {
    final bytes =
        List<int>.generate(24, (_) => _random.nextInt(256), growable: false);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  Future<void> _handleSocket(Socket socket) async {
    final buffer = BytesBuilder(copy: true);
    try {
      await for (final chunk in socket) {
        buffer.add(chunk);
        final bytes = buffer.toBytes();
        final headerEnd = _indexOfHeaderEnd(bytes);
        if (headerEnd < 0) {
          if (bytes.length > maxHeaderBytes) break;
          continue;
        }
        await _respond(socket, utf8.decode(bytes.sublist(0, headerEnd)));
        return;
      }
    } catch (_) {
      // 电视切集时会直接断连，属正常。
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
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

  Future<void> _respond(Socket socket, String header) async {
    final lines = header.split('\r\n');
    if (lines.isEmpty) return;
    final requestLine = lines.first.split(' ');
    if (requestLine.length < 2) return;
    final method = requestLine[0].toUpperCase();
    if (method != 'GET' && method != 'HEAD') {
      await _writeStatus(socket, 405, 'Method Not Allowed');
      return;
    }
    final rawPath = requestLine[1];
    String? rangeHeader;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      if (line.substring(0, idx).trim().toLowerCase() == 'range') {
        rangeHeader = line.substring(idx + 1).trim();
      }
    }

    final path = Uri.tryParse(rawPath)?.path ?? '';
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segments.length != 2 || segments.first != 'm') {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final filePath = _tokens[segments[1]];
    if (filePath == null) {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }

    final total = await file.length();
    final mime = mimeTypeForPath(filePath);
    final range = _parseRange(rangeHeader, total);
    if (range == null) {
      // 不可满足的 Range（起点越界/区间非法/多段）：按 HTTP 语义回 416，
      // 不再静默退化成整文件 200（旧行为会掩盖客户端的错区间 bug）。
      await _writeStatus(
        socket,
        416,
        'Range Not Satisfiable',
        extraHeaders: 'Content-Range: bytes */$total\r\n',
      );
      return;
    }
    final head = StringBuffer()
      ..write(range.partial ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: $mime\r\n')
      ..write('Content-Length: ${range.length}\r\n')
      ..write('Accept-Ranges: bytes\r\n');
    if (range.partial) {
      head.write('Content-Range: bytes ${range.start}-${range.end - 1}/$total\r\n');
    }
    head.write('Connection: close\r\n\r\n');
    socket.add(utf8.encode(head.toString()));

    if (method == 'HEAD') {
      await socket.flush();
      return;
    }
    if (range.length > 0) {
      await socket.addStream(file.openRead(range.start, range.end));
    }
    await socket.flush();
  }

  static Future<void> _writeStatus(
    Socket socket,
    int code,
    String reason, {
    String extraHeaders = '',
  }) async {
    socket.add(utf8.encode(
      'HTTP/1.1 $code $reason\r\n'
      '$extraHeaders'
      'Content-Length: 0\r\n'
      'Connection: close\r\n\r\n',
    ));
    await socket.flush();
  }

  /// 解析 `bytes=` 单段 Range；返回 null = 不可满足（调用方回 416）。
  ///
  /// 支持 `bytes=s-e`、`bytes=s-`、`bytes=-n`（末尾 n 字节）；多段 Range
  /// 一律不可满足（电视端不会发，发了也没法逐段伺服）。
  static _ByteRange? _parseRange(String? header, int total) {
    if (header == null || !header.startsWith('bytes=')) {
      return _ByteRange(0, total, partial: false);
    }
    final spec = header.substring('bytes='.length);
    final m = RegExp(r'^([0-9]{0,19})-([0-9]{0,19})$').firstMatch(spec);
    if (m == null) return null;
    final startText = m.group(1)!;
    final endText = m.group(2)!;
    if (startText.isEmpty) {
      // suffix：末尾 n 字节；n<=0、无 end 或空文件视为非法。
      final n = int.tryParse(endText);
      if (n == null || n <= 0 || total <= 0) return null;
      final start = n >= total ? 0 : total - n;
      return _ByteRange(start, total, partial: true);
    }
    final start = int.parse(startText);
    if (start >= total) return null;
    var end = total;
    if (endText.isNotEmpty) {
      final requested = int.parse(endText) + 1;
      if (requested < start) return null;
      end = requested > total ? total : requested;
    }
    return _ByteRange(start, end, partial: true);
  }

  /// 私网 IPv4 探测（192.168.* > 10.* > 172.16-31；跳过回环）。
  /// 供本目录各本地服务（媒体服务/代理）共用。
  static Future<String?> resolveLanIPv4() => _resolveLocalAddress();

  static Future<String?> _resolveLocalAddress() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          if (_isPrivate(address.address)) return address.address;
        }
      }
      for (final interface in interfaces) {
        if (interface.addresses.isNotEmpty) {
          return interface.addresses.first.address;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') ||
      ip.startsWith('10.') ||
      RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
}

class _ByteRange {
  const _ByteRange(this.start, this.end, {required this.partial});

  final int start;
  final int end;
  final bool partial;

  int get length => end - start < 0 ? 0 : end - start;
}

/// 扩展名 → MIME。电视对 `application/octet-stream` 常常直接拒播。
String mimeTypeForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'webm' => 'video/webm',
    'ts' => 'video/mp2t',
    'm3u8' => 'application/vnd.apple.mpegurl',
    'mov' => 'video/quicktime',
    'avi' => 'video/x-msvideo',
    'flv' => 'video/x-flv',
    'mp3' => 'audio/mpeg',
    'm4a' => 'audio/mp4',
    'aac' => 'audio/aac',
    'flac' => 'audio/flac',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'srt' => 'application/x-subrip',
    'vtt' => 'text/vtt',
    'jpg' || 'jpeg' => 'image/jpeg',
    'png' => 'image/png',
    'webp' => 'image/webp',
    _ => 'application/octet-stream',
  };
}
