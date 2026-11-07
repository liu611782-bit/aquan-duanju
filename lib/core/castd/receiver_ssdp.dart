/// SSDP 接收侧（蓝本 Ssdp.kt / SsdpServer.kt 语义移植）：应答 M-SEARCH、
/// 周期 NOTIFY alive、停止 byebye；多网卡逐接口收发（复用发送端
/// [LocalMediaServer.isVirtualAdapterName] 的虚拟网卡清单）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../cast/local_media_server.dart';
import '../error_log.dart';
import 'receiver_descriptions.dart';

/// SSDP 报文组包/解析（纯函数，单测覆盖 AC-1）。
abstract final class ReceiverSsdp {
  static const String multicastAddress = '239.255.255.250';
  static const int multicastPort = 1900;

  /// 控制点缓存时长；alive 在此之前反复重发。
  static const int maxAgeSec = 1800;

  /// SERVER / HTTP Server 头的产品段（蓝本口径带 OS 前缀）。
  static const String productToken = 'aquan-duanju/1.6';
  static String get serverProduct =>
      '${Platform.operatingSystem}/1 UPnP/1.0 $productToken';

  static const String rootDevice = 'upnp:rootdevice';
  static const String mediaRenderer =
      'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const String avTransport = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const String renderingControl =
      'urn:schemas-upnp-org:service:RenderingControl:1';
  static const String connectionManager =
      'urn:schemas-upnp-org:service:ConnectionManager:1';

  /// 本接收端宣告的全部 (NT, USN) 组（蓝本 targets）。
  static List<(String, String)> targets(String udn) {
    final device = 'uuid:$udn';
    return [
      (rootDevice, '$device::$rootDevice'),
      (device, device),
      (mediaRenderer, '$device::$mediaRenderer'),
      (avTransport, '$device::$avTransport'),
      (renderingControl, '$device::$renderingControl'),
      (connectionManager, '$device::$connectionManager'),
    ];
  }

  /// 报文里的 M-SEARCH；其余（NOTIFY/应答/垃圾）返回 null。
  static SsdpSearchRequest? parseSearch(String message) {
    // 容错 \r\n 与纯 \n 分隔。
    final lines = message
        .split(RegExp(r'\r?\n'))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (lines.isEmpty) return null;
    if (!lines.first.toUpperCase().startsWith('M-SEARCH')) return null;
    final headers = _headerMap(lines.sublist(1));
    final man = (headers['man'] ?? '').replaceAll('"', '').trim();
    if (man.toLowerCase() != 'ssdp:discover') return null;
    final st = headers['st'];
    if (st == null || st.isEmpty) return null;
    final mx = int.tryParse(headers['mx'] ?? '') ?? 1;
    return SsdpSearchRequest(st, mx.clamp(0, 5));
  }

  /// 搜索 ST 命中的宣告组；`ssdp:all` 命中全部（蓝本 matches）。
  static List<(String, String)> matches(
    SsdpSearchRequest search,
    String udn,
  ) {
    final all = targets(udn);
    final st = search.searchTarget;
    if (st.toLowerCase() == 'ssdp:all') return all;
    return all.where((t) => t.$1.toLowerCase() == st.toLowerCase()).toList();
  }

  /// M-SEARCH 单播应答（PRD R1.1 头集合：CACHE-CONTROL/DATE/EXT/LOCATION/
  /// SERVER/ST/USN）。
  static String searchResponse(
    (String, String) target,
    String location, {
    DateTime? now,
  }) => _message(
        'HTTP/1.1 200 OK',
        [
          ('CACHE-CONTROL', 'max-age=$maxAgeSec'),
          ('DATE', HttpDate.format(now ?? DateTime.now())),
          ('EXT', ''),
          ('LOCATION', location),
          ('SERVER', serverProduct),
          ('ST', target.$1),
          ('USN', target.$2),
        ],
      );

  static String alive((String, String) target, String location) => _message(
        'NOTIFY * HTTP/1.1',
        [
          ('HOST', '$multicastAddress:$multicastPort'),
          ('CACHE-CONTROL', 'max-age=$maxAgeSec'),
          ('LOCATION', location),
          ('NT', target.$1),
          ('NTS', 'ssdp:alive'),
          ('SERVER', serverProduct),
          ('USN', target.$2),
        ],
      );

  static String byeBye((String, String) target) => _message(
        'NOTIFY * HTTP/1.1',
        [
          ('HOST', '$multicastAddress:$multicastPort'),
          ('NT', target.$1),
          ('NTS', 'ssdp:byebye'),
          ('USN', target.$2),
        ],
      );

  /// 头名统一小写、后值覆盖前值（蓝本 headers）。
  static Map<String, String> _headerMap(List<String> lines) {
    final out = <String, String>{};
    for (final line in lines) {
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      out[line.substring(0, colon).trim().toLowerCase()] =
          line.substring(colon + 1).trim();
    }
    return out;
  }

  static String _message(String startLine, List<(String, String)> headers) {
    final buf = StringBuffer(startLine)..write('\r\n');
    for (final (name, value) in headers) {
      buf.write(name);
      buf.write(': ');
      buf.write(value);
      buf.write('\r\n');
    }
    buf.write('\r\n');
    return buf.toString();
  }
}

/// 一个控制点的搜索请求。
class SsdpSearchRequest {
  const SsdpSearchRequest(this.searchTarget, this.maxWaitSec);

  final String searchTarget;

  /// MX（秒），已钳 0..5。
  final int maxWaitSec;
}

/// M-SEARCH 应答限速门：同源 IP 在 [window] 内最多 [maxPerWindow] 包
/// （design.md §2「同源 IP 1s 内限速」；上限取 12——一次 `ssdp:all`
/// 应答 6 包 + 同轮 3 个 ST 各 1 包 = 9，再留余量，自家发送端多网卡
/// 双 socket 同轮不会被误伤）。
class SsdpReplyGate {
  SsdpReplyGate({
    this.maxPerWindow = 12,
    this.window = const Duration(seconds: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxPerWindow;
  final Duration window;
  final DateTime Function() _now;

  final Map<String, DateTime> _windowStart = {};
  final Map<String, int> _counts = {};

  bool allow(String sourceIp) {
    final now = _now();
    final start = _windowStart[sourceIp];
    if (start == null || now.difference(start) >= window) {
      _windowStart[sourceIp] = now;
      _counts[sourceIp] = 1;
      return true;
    }
    final count = _counts[sourceIp] ?? 0;
    if (count >= maxPerWindow) return false;
    _counts[sourceIp] = count + 1;
    return true;
  }

  /// 测试钩子：清空窗口记忆。
  void reset() {
    _windowStart.clear();
    _counts.clear();
  }
}

/// MX 随机延迟：0..min(MX,5) 秒内均匀取（避免同刻应答风暴；蓝本口径）。
Duration searchReplyDelay(int mxSec, Random rng) {
  final capped = mxSec < 0 ? 0 : (mxSec > 5 ? 5 : mxSec);
  if (capped == 0) return Duration.zero;
  return Duration(milliseconds: rng.nextInt(capped * 1000 + 1));
}

/// SSDP 服务：收 M-SEARCH（组播 1900）并单播应答，周期发 alive，停止发 byebye。
///
/// 1900 被占（Windows 上其它 DLNA 软件常见）时 [answersSearches] = false，
/// 只靠 alive 通告被发现——蓝本同款降级。
class ReceiverSsdpServer {
  ReceiverSsdpServer({
    required this.udn,
    required this.httpPort,
    this.announceInterval = const Duration(seconds: 60),
    this.initialBurstCount = 3,
    SsdpReplyGate? replyGate,
    this.mxOverride,
    Random? rng,
  })  : replyGate = replyGate ?? SsdpReplyGate(),
        _rng = rng ?? Random.secure();

  final String udn;

  /// HTTP 描述服务端口（start 前须已确定）。
  final int httpPort;

  /// alive 重发周期；启动后先以 1s 间隔连发 [initialBurstCount] 次
  /// （蓝本「先密集后常速」）。默认 60s（蓝本口径；UPnP 建议不超过
  /// max-age/2，60s 远在其内）。
  final Duration announceInterval;

  final int initialBurstCount;
  final SsdpReplyGate replyGate;

  /// 非 null 时覆盖 M-SEARCH 的 MX 随机延迟（0 = 立即应答；测试用）。
  final int? mxOverride;
  final Random _rng;

  RawDatagramSocket? _listener;
  final List<(RawDatagramSocket, InternetAddress)> _ifaceSockets = [];
  RawDatagramSocket? _replySocket;
  Timer? _announceTimer;
  int _announceTicks = 0;
  bool _running = false;
  bool _socketsClosed = false;
  bool _answersSearches = false;

  /// 1900 是否绑定成功（能否收 M-SEARCH）。
  bool get answersSearches => _answersSearches;

  Future<void> start() async {
    if (_running) return;
    _running = true;
    final interfaces = await _candidateInterfaces();

    // 应答源 socket（OS 按路由选源地址）。
    try {
      final reply = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      reply.multicastLoopback = false;
      _replySocket = reply;
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·SSDP 应答 socket', e, st);
    }

    // 监听 socket：组播 1900。绑定失败只降级，不致命。
    try {
      final listener = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        ReceiverSsdp.multicastPort,
        reuseAddress: true,
      );
      listener.multicastLoopback = false;
      var joined = false;
      try {
        listener.joinMulticast(
          InternetAddress(ReceiverSsdp.multicastAddress),
        );
        joined = true;
      } catch (_) {}
      for (final (iface, _) in interfaces) {
        try {
          listener.joinMulticast(
            InternetAddress(ReceiverSsdp.multicastAddress),
            iface,
          );
          joined = true;
        } catch (_) {
          // 单接口 join 失败不致命：其它接口/默认组仍可达。
        }
      }
      _listener = listener;
      _answersSearches = joined;
      listener.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = listener.receive();
        if (datagram == null) return;
        _onDatagram(datagram);
      }, onError: (Object e, StackTrace st) {
        ErrorLog.instance.record('DLNA 接收·SSDP 监听', e, st);
      });
    } catch (e, st) {
      _answersSearches = false;
      ErrorLog.instance.record('DLNA 接收·SSDP 1900 绑定', e, st);
    }

    // 逐接口发送 socket：alive 从每张网卡各出一份，LOCATION 用该网卡 IP
    // （design.md §2；Dart 无 IP_MULTICAST_IF，与发送端同款多 socket）。
    for (final (_, address) in interfaces) {
      try {
        final socket = await RawDatagramSocket.bind(address, 0);
        socket.multicastLoopback = false;
        _ifaceSockets.add((socket, address));
      } catch (_) {
        // 单接口绑定失败跳过（默认路由由 reply/接口 socket 覆盖不了时，
        // alive 少一张网卡只是该网段发现变慢，不致命）。
      }
    }

    _announceAlive();
    final intervalSeconds =
        announceInterval.inSeconds > 0 ? announceInterval.inSeconds : 60;
    _announceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_running) return;
      _announceTicks++;
      // 先密集后常速（蓝本 announceLoop）：启动 1s 间隔连发 3 次，此后每
      // announceInterval 一轮。
      if (_announceTicks < initialBurstCount) {
        _announceAlive();
        return;
      }
      final elapsed = _announceTicks - initialBurstCount + 1;
      if (elapsed % intervalSeconds == 0) {
        _announceAlive();
      }
    });
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _announceTimer?.cancel();
    _announceTimer = null;
    _sendByeBye();
    _socketsClosed = true;
    _listener?.close();
    _listener = null;
    _replySocket?.close();
    _replySocket = null;
    for (final (socket, _) in _ifaceSockets) {
      socket.close();
    }
    _ifaceSockets.clear();
    _answersSearches = false;
  }

  void _onDatagram(Datagram datagram) {
    final text = utf8.decode(datagram.data, allowMalformed: true);
    final search = ReceiverSsdp.parseSearch(text);
    if (search == null) return;
    final matched = ReceiverSsdp.matches(search, udn);
    if (matched.isEmpty) return;
    // 应答限速（同源 IP 窗口内限量）。
    if (!replyGate.allow(datagram.address.address)) return;
    _locationFor(datagram.address.address).then((location) {
      if (!_running) return;
      final delay = mxOverride != null
          ? Duration(milliseconds: mxOverride!)
          : searchReplyDelay(search.maxWaitSec, _rng);
      if (delay == Duration.zero) {
        _reply(datagram, matched, location);
      } else {
        Timer(delay, () {
          if (_running) _reply(datagram, matched, location);
        });
      }
    }).catchError((Object e, StackTrace st) {
      ErrorLog.instance.record('DLNA 接收·SSDP 应答定位', e, st);
    });
  }

  void _reply(Datagram datagram, List<(String, String)> targets, String location) {
    final socket = _replySocket;
    if (socket == null) return;
    for (final target in targets) {
      final data = utf8.encode(
        ReceiverSsdp.searchResponse(target, location, now: DateTime.now()),
      );
      try {
        socket.send(data, datagram.address, datagram.port);
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·SSDP 应答发送', e, st);
      }
    }
  }

  void _announceAlive() {
    _sendPerInterface((target, location) => ReceiverSsdp.alive(target, location));
  }

  void _sendByeBye() {
    _sendPerInterface((target, _) => ReceiverSsdp.byeBye(target));
  }

  void _sendPerInterface(String Function((String, String), String) build) {
    final group = InternetAddress(ReceiverSsdp.multicastAddress);
    final port = ReceiverSsdp.multicastPort;
    if (_ifaceSockets.isEmpty) {
      // 全部接口 socket 绑定失败的兜底：用应答 socket 发一份（LOCATION 用
      // 主选地址），保证至少默认网段可达。
      final socket = _replySocket;
      if (socket == null || _socketsClosed) return;
      LocalMediaServer.resolveLanIPv4().then((ip) {
        if (_socketsClosed || socket != _replySocket) return;
        final location = 'http://${ip ?? '127.0.0.1'}:$httpPort'
            '$receiverDescriptionPath';
        for (final target in ReceiverSsdp.targets(udn)) {
          try {
            socket.send(utf8.encode(build(target, location)), group, port);
          } catch (_) {}
        }
      }).catchError((Object _) {});
      return;
    }
    for (final (socket, address) in _ifaceSockets) {
      final location = 'http://${address.address}:$httpPort'
          '$receiverDescriptionPath';
      for (final target in ReceiverSsdp.targets(udn)) {
        try {
          socket.send(utf8.encode(build(target, location)), group, port);
        } catch (e, st) {
          ErrorLog.instance.record('DLNA 接收·SSDP 通告发送', e, st);
        }
      }
    }
  }

  Future<String> _locationFor(String remoteIp) async {
    // 到请求者的路由源 IP（Windows 路由表查询，无探测包）；回环目标直接回
    // 127.0.0.1（同机自测）。失败回退主选私网地址。
    final ip = await LocalMediaServer.resolveRouteSourceIp(remoteIp) ??
        await LocalMediaServer.resolveLanIPv4() ??
        remoteIp;
    return 'http://$ip:$httpPort$receiverDescriptionPath';
  }

  /// 候选收发接口：非回环、非虚拟网卡的 IPv4（M0.5 清单口径）。
  static Future<List<(NetworkInterface, InternetAddress)>>
      _candidateInterfaces() async {
    List<NetworkInterface> list;
    try {
      list = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } catch (_) {
      return const [];
    }
    final out = <(NetworkInterface, InternetAddress)>[];
    for (final iface in list) {
      if (LocalMediaServer.isVirtualAdapterName(iface.name)) continue;
      for (final address in iface.addresses) {
        if (address.type != InternetAddressType.IPv4) continue;
        if (address.isLoopback) continue;
        out.add((iface, address));
      }
    }
    return out;
  }
}
