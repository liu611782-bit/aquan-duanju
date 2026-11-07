import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'cast_diagnostics.dart';
import 'cast_media_type.dart';
import 'cast_recipe.dart';

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

/// `contentFeatures.dlna.org` 的值（与本地路由真实能力一致：支持字节 Range
/// 206 → OP=01；不转码 → CI=0）。
const String kDlnaContentFeatures =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

/// DLNA 条件化响应头（M1-9，review §8.1/§8.5；playbridge 条件化写法）。
///
/// - `transferMode.dlna.org`：媒体路由恒 `Streaming`；字幕等 text/* 路由
///   （[media] = false）走 `Interactive` 且不给 contentFeatures/realTimeInfo；
/// - `contentFeatures.dlna.org`：仅当请求带 `getcontentFeatures.dlna.org: 1`
///   才回（[contentFeaturesRequested]）；
/// - `realTimeInfo.dlna.org: DLNA.ORG_TLAG=*`：流式媒体路由恒带；
/// - `Accept-Ranges`：仅本路由真的会答 206 才声明（[acceptRanges]）——
///   本地文件恒真；代理直链按上游；HLS 清单路由不声明（谎报 byte-seek
///   有 TCL 一 seek 就停播的实证回归，review §8.5）；
/// - 附带宽松 CORS（网页投屏页跨域拉流）。
///
/// 注意：这里只加 DLNA 与**放宽型** CORS 头，**不加** `x-frame-options`、
/// `x-content-type-options` 之类的限制性安全头——部分渲染器见到会拒播
/// （见 cast-contract.md P0「零安全头」语义，既有测试断言这些头必须缺席）。
String dlnaResponseHeaders({
  bool media = true,
  bool contentFeaturesRequested = false,
  bool acceptRanges = true,
}) {
  final b = StringBuffer()
    ..write('transferMode.dlna.org: ${media ? 'Streaming' : 'Interactive'}\r\n');
  if (media && contentFeaturesRequested) {
    b.write('contentFeatures.dlna.org: $kDlnaContentFeatures\r\n');
  }
  if (media) {
    b.write('realTimeInfo.dlna.org: DLNA.ORG_TLAG=*\r\n');
  }
  if (acceptRanges) {
    b.write('Accept-Ranges: bytes\r\n');
  }
  b.write('Access-Control-Allow-Origin: *\r\n');
  return b.toString();
}

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
  ///
  /// [targetHost] 是目标设备 controlURL 的 host（M0.5 per-device IP）：
  /// 提供时对外 URL 的 host 用「到该设备的路由源 IP」（电视拉得到流的
  /// 地址），探测失败回退登记时的全局本机地址。同一媒体投两台设备 =
  /// 两个 token，互不影响。
  ///
  /// URL 形态（M1-4）：`/m/<token>/<fileName>`，fileName 来自
  /// [resolveCastMediaType]（按文件扩展名映射，如 ep1.mp4 → video.mp4，
  /// 不暴露真实文件名）；[urlSuffixMode] = bare 时退回旧形态 `/m/<token>`。
  Future<String?> urlFor(
    String filePath, {
    String? targetHost,
    CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension,
  }) async {
    if (!await start()) return null;
    final token = _register(filePath);
    final server = _socket;
    if (server == null) return null;
    String? host;
    if (targetHost != null && targetHost.isNotEmpty) {
      host = await resolveRouteSourceIp(targetHost);
    }
    host ??= _localAddress;
    if (host == null) return null;
    final suffix =
        urlSuffixMode == CastUrlSuffixMode.bare ? '' : '/${_fileNameFor(filePath)}';
    return 'http://$host:${server.port}/m/$token$suffix';
  }

  /// 登记文件的对外文件名（按扩展名映射的通用名，不暴露真实文件名）。
  static String _fileNameFor(String filePath) =>
      castMediaTypeFromUrlPath(Uri.file(filePath)).fileName;

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
      _traceMedia(requestLine[1], method, null, null, 405, 0);
      await _writeStatus(socket, 405, 'Method Not Allowed');
      return;
    }
    final rawPath = requestLine[1];
    String? rangeHeader;
    String? userAgent;
    bool contentFeaturesRequested = false;
    for (final line in lines.skip(1)) {
      final idx = line.indexOf(':');
      if (idx <= 0) continue;
      final key = line.substring(0, idx).trim().toLowerCase();
      if (key == 'range') {
        rangeHeader = line.substring(idx + 1).trim();
      } else if (key == 'user-agent') {
        userAgent = line.substring(idx + 1).trim();
      } else if (key == 'getcontentfeatures.dlna.org') {
        // playbridge 条件化写法：设备显式索要才回 contentFeatures。
        contentFeaturesRequested = line.substring(idx + 1).trim() == '1';
      }
    }
    // 取流埋点（M0 纯采集；recordMediaRequest 自身吞异常）。
    void trace(int status, int bytes) =>
        _traceMedia(rawPath, method, rangeHeader, userAgent, status, bytes);

    final path = Uri.tryParse(rawPath)?.path ?? '';
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    // M1-4：路由放宽到 `>= 2` 段——`/m/<token>/<fileName>` 的末段只是让
    // URL 带扩展名（接收端靠它选播放器），token 恒取 segments[1]；
    // 旧形态 `/m/<token>` 继续兼容。
    if (segments.length < 2 || segments.first != 'm') {
      trace(404, 0);
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final filePath = _tokens[segments[1]];
    if (filePath == null) {
      trace(404, 0);
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }
    final file = File(filePath);
    if (!await file.exists()) {
      trace(404, 0);
      await _writeStatus(socket, 404, 'Not Found');
      return;
    }

    final total = await file.length();
    final mime = mimeTypeForPath(filePath);
    final range = _parseRange(rangeHeader, total);
    if (range == null) {
      // 不可满足的 Range（起点越界/区间非法/多段）：按 HTTP 语义回 416，
      // 不再静默退化成整文件 200（旧行为会掩盖客户端的错区间 bug）。
      trace(416, 0);
      await _writeStatus(
        socket,
        416,
        'Range Not Satisfiable',
        extraHeaders: 'Content-Range: bytes */$total\r\n',
      );
      return;
    }
    trace(range.partial ? 206 : 200, range.length);
    final head = StringBuffer()
      ..write(range.partial ? 'HTTP/1.1 206 Partial Content\r\n' : 'HTTP/1.1 200 OK\r\n')
      ..write('Content-Type: $mime\r\n')
      ..write('Content-Length: ${range.length}\r\n')
      // 本地文件路由恒真支持 Range 206 → Accept-Ranges 诚实声明（M1-9）。
      ..write(dlnaResponseHeaders(
        media: true,
        contentFeaturesRequested: contentFeaturesRequested,
        acceptRanges: true,
      ));
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

  /// 电视取流埋点（M0 纯采集；不改变任何响应行为）。
  static void _traceMedia(String url, String method, String? range,
      String? userAgent, int status, int bytes) {
    CastDiagnostics.instance.recordMediaRequest(MediaRequestTrace(
      url: url,
      method: method,
      range: range,
      userAgent: userAgent,
      statusCode: status,
      bytesServed: bytes,
      source: 'local',
    ));
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

  /// 私网 IPv4 探测（192.168.* > 10.* > 172.16-31；跳过回环与虚拟网卡）。
  /// 供本目录各本地服务（媒体服务/代理）共用。
  static Future<String?> resolveLanIPv4() => _resolveLocalAddress();

  /// 到 [targetHost]（目标设备 controlURL 的 host）的路由源 IP（M0.5 P0b）。
  ///
  /// 多网卡 Windows 上「第一个私网地址」常落在 WSL/Hyper-V/VMware 等虚拟
  /// 交换机上，电视根本不可达（review §2.1 的最可疑根因：旧实现直接返回
  /// 第一个私网地址，注释承诺的优先级从未生效）。这里按「到该设备的路由」
  /// 取本机源 IP：
  ///
  /// - Windows：iphlpapi `GetBestInterface` 查到目标的最优路由接口，再由
  ///   `GetIpAddrTable` 取该接口地址——纯路由表查询，**不发出任何数据包**。
  ///   go2tv `iptools.go` 的 UDP `connect()` 在 Dart 没有对应 API
  ///   （[RawDatagramSocket] 无 connect 方法，实测确认），这是同语义的
  ///   Windows 实现；
  /// - 回退：本机枚举，按 `192.168.* > 10.* > 172.16-31` 排序、跳过虚拟
  ///   网卡（[rankInterfaceAddresses]），与目标同 /24 的地址优先。
  ///
  /// 整体限时 [timeout]（默认 800ms）；任何失败都回退枚举，绝不抛出。
  static Future<String?> resolveRouteSourceIp(
    String targetHost, {
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    if (targetHost.isEmpty) return resolveLanIPv4();
    try {
      final targets = await _resolveTargetAddresses(targetHost).timeout(timeout);
      for (final address in targets) {
        if (address.isLoopback) return address.address;
        final routed = windowsRouteSourceIp(address);
        if (routed != null) return routed;
      }
    } catch (_) {
      // 超时/域名解析失败/FFI 异常：走回退枚举。
    }
    return _resolveLocalAddress(targetHost: targetHost);
  }

  static Future<List<InternetAddress>> _resolveTargetAddresses(String host) async {
    final direct = InternetAddress.tryParse(host);
    if (direct != null) return <InternetAddress>[direct];
    return InternetAddress.lookup(host, type: InternetAddressType.IPv4);
  }

  // ---------------------------------------------------------------------------
  // Windows 路由表查询（iphlpapi；无网络包）
  // ---------------------------------------------------------------------------

  static final DynamicLibrary? _iphlpapi = () {
    if (!Platform.isWindows) return null;
    try {
      return DynamicLibrary.open('iphlpapi.dll');
    } catch (_) {
      return null;
    }
  }();

  // DWORD GetBestInterface(IPAddr dwDestAddr, PDWORD pdwBestIfIndex);
  static final _getBestInterface = _iphlpapi?.lookupFunction<
      Int32 Function(Uint32, Pointer<Uint32>),
      int Function(int, Pointer<Uint32>)>('GetBestInterface');

  // DWORD GetIpAddrTable(PMIB_IPADDRTABLE pIpAddrTable, PULONG pdwSize, BOOL bOrder);
  static final _getIpAddrTable = _iphlpapi?.lookupFunction<
      Int32 Function(Pointer<Uint32>, Pointer<Uint32>, Int32),
      int Function(Pointer<Uint32>, Pointer<Uint32>, int)>('GetIpAddrTable');

  /// MIB_IPADDRROW = 24 字节（6 个 32 位字）。
  static const int _ipAddrRowDwords = 6;

  /// MIB_IPADDRTABLE 初始容量（头 1 字 + 64 行）：预分配一次成功，够用。
  static const int _ipAddrTableInitDwords = 1 + _ipAddrRowDwords * 64;

  /// Windows：查「到 [target] 的最优路由接口」的本机地址（iphlpapi
  /// `GetBestInterface` + `GetIpAddrTable`；纯路由表查询，无网络包）。
  /// 非 Windows / FFI 失败 / 目标无路由 → null（调用方回退枚举）。
  /// 公开供单测锁定实测的行布局。
  static String? windowsRouteSourceIp(InternetAddress target) {
    final getBestInterface = _getBestInterface;
    final getIpAddrTable = _getIpAddrTable;
    if (getBestInterface == null || getIpAddrTable == null) return null;
    Pointer<Uint32>? table;
    Pointer<Uint32>? sizeBuf;
    Pointer<Uint32>? bestBuf;
    try {
      final packed = _packedIp(target.address);
      if (packed == null) return null;
      bestBuf = calloc<Uint32>();
      if (getBestInterface(packed, bestBuf) != 0) return null;
      final bestIndex = bestBuf.value;

      sizeBuf = calloc<Uint32>()..value = _ipAddrTableInitDwords * 4;
      table = calloc<Uint32>(_ipAddrTableInitDwords);
      var rc = getIpAddrTable(table, sizeBuf, 0);
      if (rc == 122 /* ERROR_INSUFFICIENT_BUFFER */ &&
          sizeBuf.value > _ipAddrTableInitDwords * 4) {
        calloc.free(table);
        table = calloc<Uint32>(sizeBuf.value ~/ 4 + 1);
        rc = getIpAddrTable(table, sizeBuf, 0);
      }
      if (rc != 0) return null;
      final count = table[0];
      // 实测（Win10 19045 + Get-NetIPAddress 双重核对）MIB_IPADDRROW 的
      // 运行时布局是 dwAddr@+0 / dwIfIndex@+4 / dwMask@+8——与常被引用的
      // 文档顺序（mask 在 ifIndex 前）相反。两遍扫描兜住两种布局：
      // 先按实测布局匹配，无命中再按文档布局试一次。
      for (var i = 0; i < count; i++) {
        final base = 1 + i * _ipAddrRowDwords;
        if (table[base + 1] == bestIndex) {
          return _ipFromPacked(table[base] /* dwAddr */);
        }
      }
      for (var i = 0; i < count; i++) {
        final base = 1 + i * _ipAddrRowDwords;
        if (table[base + 2] == bestIndex) {
          return _ipFromPacked(table[base]);
        }
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      final t = table;
      if (t != null) calloc.free(t);
      final s = sizeBuf;
      if (s != null) calloc.free(s);
      final b = bestBuf;
      if (b != null) calloc.free(b);
    }
  }

  /// `a.b.c.d` → IPAddr 的 uint32 表示（等价 inet_addr 的内存布局）。
  static int? _packedIp(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) return null;
    var v = 0;
    for (var i = 0; i < 4; i++) {
      final octet = int.tryParse(parts[i]);
      if (octet == null || octet < 0 || octet > 255) return null;
      v |= octet << (8 * i);
    }
    return v;
  }

  static String _ipFromPacked(int v) =>
      '${v & 0xff}.${(v >> 8) & 0xff}.${(v >> 16) & 0xff}.${(v >> 24) & 0xff}';

  // ---------------------------------------------------------------------------
  // 回退枚举（纯函数，表驱动单测）
  // ---------------------------------------------------------------------------

  /// 虚拟网卡名判定（M0.5 纯函数）：这些接口上的地址对局域网电视几乎
  /// 不可达（WSL/Hyper-V/VMware 等虚拟交换机与隧道）。
  static bool isVirtualAdapterName(String name) {
    final lower = name.toLowerCase();
    const marks = <String>[
      'vethernet',
      'wsl',
      'hyper-v',
      'vmware',
      'virtualbox',
      'tap',
      'tailscale',
      'zerotier',
    ];
    for (final mark in marks) {
      if (lower.contains(mark)) return true;
    }
    return false;
  }

  /// 私网优先级：192.168.* > 10.* > 172.16-31；其余（含非私网）排最后。
  static int _privateRank(String ip) {
    if (ip.startsWith('192.168.')) return 0;
    if (ip.startsWith('10.')) return 1;
    if (RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip)) return 2;
    return 3;
  }

  /// 与目标是否同 /24 网段（dart_cast network_utils 思路：同网段地址优先）。
  static bool _sameSubnet24(String a, String b) {
    final pa = a.split('.');
    final pb = b.split('.');
    if (pa.length != 4 || pb.length != 4) return false;
    for (var i = 0; i < 3; i++) {
      if (pa[i] != pb[i]) return false;
    }
    return true;
  }

  /// 回退枚举的排序（M0.5 纯函数）：跳过虚拟网卡与非私网地址；
  /// [target] 给定时与目标同 /24 的地址最优先；同级按
  /// `192.168 > 10 > 172.16-31`（修正旧实现「直接返回第一个私网地址」）。
  static List<String> rankInterfaceAddresses(
    Iterable<(String name, String address)> entries, {
    String? target,
  }) {
    final ranked = <String>[
      for (final (name, address) in entries)
        if (!isVirtualAdapterName(name) && _isPrivate(address)) address,
    ];
    int score(String ip) {
      final sameSubnet =
          (target != null && target.isNotEmpty && _sameSubnet24(ip, target))
              ? 0
              : 1;
      return sameSubnet * 10 + _privateRank(ip);
    }

    ranked.sort((a, b) => score(a).compareTo(score(b)));
    return ranked;
  }

  static Future<String?> _resolveLocalAddress({String? targetHost}) async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final entries = <(String, String)>[
        for (final interface in interfaces)
          for (final address in interface.addresses)
            (interface.name, address.address),
      ];
      final ranked = rankInterfaceAddresses(entries, target: targetHost);
      if (ranked.isNotEmpty) return ranked.first;
      // 最后兜底：跳过虚拟网卡后的任意地址（旧实现会选到 WSL/Hyper-V）。
      for (final (name, address) in entries) {
        if (!isVirtualAdapterName(name)) return address;
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
    'm4a' || 'aac' => 'audio/mp4',
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
