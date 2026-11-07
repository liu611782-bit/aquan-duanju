import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../error_log.dart';
import 'cast_diagnostics.dart';
import 'dlna_device.dart';
import 'local_media_server.dart';

/// SSDP 设备发现（UPnP 1.0）：M-SEARCH 多目标 × 4 轮 + NOTIFY 监听。
///
/// 参数对齐 CineFlow cast.cjs（实测有效）：1.5s 一轮共 4 轮、
/// TTL 4、设备表 TTL 26s；`ssdp:byebye` 置离线；同一 LOCATION 只拉一次描述。
///
/// M8 加固（11-06/11-07）：M-SEARCH 带 USER-AGENT 三连 + ST 扩 AVTransport:1；
/// 多网卡逐接口绑定发 M-SEARCH（Dart 无 IP_MULTICAST_IF，只能多 socket）；
/// 描述拉取失败不永久拉黑（发现期预算：每 URL ≤2 次、全局 24 次，轮询结束
/// 复位）；设备被移出（byebye/TTL/复检失败）时同步清理其 LOCATION 去重表——
/// 复线设备的 alive NOTIFY 才能重新拉到描述；TTL 到期的设备先做描述 URL
/// 轻量复检，连不上立即标记离线，连得上续期（File2TV forget_if_gone 思路）。
const String multicastGroup = '239.255.255.250';
const int multicastPort = 1900;
const Duration deviceTtl = Duration(seconds: 26);
const int discoveryRounds = 4;
const Duration roundInterval = Duration(milliseconds: 1500);
const Duration descriptionTimeout = Duration(milliseconds: 1800);
const int maxDescriptionBytes = 256 * 1024;

/// 发现期描述拉取预算（hongguo 夹具口径）：同一 LOCATION 最多 2 次 GET、
/// 单轮发现窗口全局最多 24 次；503/IO/坏 XML 换下一条 advertisement，
/// 轮询结束（SsdpScanDone）后复位——NOTIFY 驱动的迟到设备不受影响。
const int maxFetchAttemptsPerUrl = 2;
const int maxFetchAttemptsTotal = 24;
sealed class SsdpEvent {
  const SsdpEvent();
}

class SsdpDeviceFound extends SsdpEvent {
  const SsdpDeviceFound(this.device);
  final DlnaDevice device;
}

class SsdpDeviceOffline extends SsdpEvent {
  const SsdpDeviceOffline(this.udn);
  final String udn;
}

class SsdpScanDone extends SsdpEvent {
  /// [warning] 非空表示本轮发现出现过非致命警告（如组播绑定失败）。
  /// 复用已有事件而非新增子类：上层 `switch` 的穷尽匹配保持不变。
  const SsdpScanDone({this.warning = ''});

  final String warning;
}

class SsdpDiscovery {
  SsdpDiscovery({DescriptionFetcherFactory? clientFactory})
      : _clientFactory = clientFactory ?? _defaultFactory;

  /// 最近一次成功绑定的本地端口（0 = 尚未绑定）；供「投屏诊断」读取。
  /// 纯诊断值，不参与发现逻辑，公开读取不改变任何既有签名。
  static int lastBoundPort = 0;

  /// 描述文档拉取器抽象（测试可注入本地 HttpServer）。
  final DescriptionFetcherFactory _clientFactory;

  RawDatagramSocket? _socket;

  /// 多网卡逐接口绑定的发送 socket（M8：Dart 无 IP_MULTICAST_IF，
  /// 每个 IPv4 接口单独 bind + joinMulticast + 发 M-SEARCH）。
  final List<RawDatagramSocket> _interfaceSockets = [];

  /// 实际绑定的本地端口（1900 或回退后的临时端口），诊断用。
  int _boundPort = 0;
  int get boundPort => _boundPort;
  StreamController<SsdpEvent>? _events;
  Timer? _roundTimer;
  Timer? _pruneTimer;
  bool _scanning = false;
  int _roundsLeft = 0;

  /// LOCATION → 描述已请求（去重：同一 location 只拉一次）。
  final Set<String> _pendingLocations = {};

  /// USN → LOCATION 映射（M8 复活路径）：设备被移出时按它清理
  /// [_pendingLocations]，复线设备的 alive NOTIFY 才能重新拉描述。
  final Map<String, String> _usnLocations = {};

  /// 发现期描述拉取预算（M8）：LOCATION → 已发 GET 次数 + 全局计数。
  final Map<String, int> _urlFetchAttempts = {};
  int _totalFetchAttempts = 0;

  /// USN → 设备（含 TTL 时间戳）。
  final Map<String, _DeviceEntry> _devices = {};


  Stream<SsdpEvent> start() {
    if (_scanning) return _events!.stream;
    _scanning = true;
    _pendingLocations.clear();
    _usnLocations.clear();
    _urlFetchAttempts.clear();
    _totalFetchAttempts = 0;
    final events = _events = StreamController<SsdpEvent>.broadcast();
    _bind().then((_) async {
      // 多网卡逐接口绑定：失败不影响主 socket（默认路由接口已可用）。
      await _bindInterfaces();
      if (!_scanning) {
        // 绑定期间 stop() 已执行：关掉刚绑定的接口 socket，不再创建定时器。
        for (final socket in _interfaceSockets) {
          socket.close();
        }
        _interfaceSockets.clear();
        return;
      }
      _sendAllTargets();
      _roundsLeft = discoveryRounds - 1;
      _roundTimer = Timer.periodic(roundInterval, (_) {
        if (_roundsLeft <= 0) {
          _roundTimer?.cancel();
          _roundTimer = null;
          // 发现窗口结束：复位描述拉取预算——此后 NOTIFY 驱动的迟到设备
          // 仍可拉描述；窗口内的预算防止 503/坏 XML 设备被反复打。
          _urlFetchAttempts.clear();
          _totalFetchAttempts = 0;
          // 轮询结束不代表发现结束（NOTIFY 仍监听）；只发一次扫描完成信号。
          events.add(const SsdpScanDone());
          return;
        }
        _roundsLeft--;
        _sendAllTargets();
      });
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        _sweepExpired(events);
      });
    }).catchError((Object e, StackTrace stack) {
      // 组播绑定失败是非致命的：不再 addError 终止发现流（R4）。原始异常只进
      // ErrorLog，事件流发一条带 warning 的既有事件；流保持打开，手动 IP 直连
      // 与后续 addByIp 仍可用，NOTIFY 监听降级为 TTL 清理兜底。
      ErrorLog.instance.record('投屏扫描·组播绑定', e, stack);
      if (!events.isClosed) {
        events.add(const SsdpScanDone(warning: '组播绑定失败，可手动输入 IP 直连'));
      }
    });
    return events.stream;
  }

  Future<void> stop() async {
    _scanning = false;
    _roundTimer?.cancel();
    _roundTimer = null;
    _pruneTimer?.cancel();
    _pruneTimer = null;
    _socket?.close();
    _socket = null;
    for (final socket in _interfaceSockets) {
      socket.close();
    }
    _interfaceSockets.clear();
    _devices.clear();
    _pendingLocations.clear();
    _usnLocations.clear();
    await _events?.close();
    _events = null;
  }

  Future<void> _bind() async {
    // 先试 1900（NOTIFY alive/byebye 也发到组播 1900，绑上就能实时感知设备
    // 上下线；M-SEARCH 应答是单播回源端口，同样能收）。1900 被其他应用占用时
    // 回退临时端口——只有 M-SEARCH 应答可用，设备离线靠 TTL 清理兜底
    // （UPnPCast 同款降级）。
    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        multicastPort,
        reuseAddress: true,
      );
      _boundPort = multicastPort;
    } catch (_) {
      socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );
      _boundPort = socket.port;
    }
    try {
      socket.joinMulticast(InternetAddress(multicastGroup));
    } catch (_) {
      // 个别无组播能力的网络仍能收 M-SEARCH 单播应答，不致命。
    }
    socket.multicastLoopback = false;
    // TTL 固定走系统默认：Dart RawDatagramSocket 没有暴露 TTL 设置。
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = socket.receive();
      if (datagram == null) return;
      _handleDatagram(datagram);
    });
    _socket = socket;
    SsdpDiscovery.lastBoundPort = _boundPort;
  }

  /// 多网卡逐接口绑定（M8）：File2TV/dlna-dart 实证——只绑 anyIPv4 时
  /// M-SEARCH 只从默认路由接口出去，WSL/Hyper-V/多网卡场景必漏。
  /// Dart `RawDatagramSocket` 没有 IP_MULTICAST_IF，只能对每个非回环、
  /// 非虚拟的 IPv4 接口单独 bind + joinMulticast + 发送（多 socket）。
  /// 绑定失败的接口静默跳过：主 socket 已覆盖默认路由。
  Future<void> _bindInterfaces() async {
    List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
    } catch (_) {
      return;
    }
    final candidates = multicastBindCandidates([
      for (final interface in interfaces)
        (interface.name, interface.addresses),
    ]);
    for (final (name, address) in candidates) {
      RawDatagramSocket socket;
      try {
        socket = await RawDatagramSocket.bind(address, 0);
      } catch (_) {
        continue;
      }
      try {
        NetworkInterface? iface;
        for (final i in interfaces) {
          if (i.name == name) iface = i;
        }
        if (iface != null) {
          socket.joinMulticast(InternetAddress(multicastGroup), iface);
        }
      } catch (_) {
        // 发送不依赖组成员资格；收不到该接口的 NOTIFY 靠主 socket 兜底。
      }
      socket.multicastLoopback = false;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        _handleDatagram(datagram);
      });
      _interfaceSockets.add(socket);
    }
  }

  /// 多网卡绑定候选（M8 纯函数，表驱动单测）：非回环、非虚拟网卡
  /// （`LocalMediaServer.isVirtualAdapterName`，M0.5 同款清单）的 IPv4 地址。
  static List<(String, InternetAddress)> multicastBindCandidates(
    List<(String name, List<InternetAddress> addresses)> interfaces,
  ) {
    final out = <(String, InternetAddress)>[];
    for (final (name, addresses) in interfaces) {
      if (LocalMediaServer.isVirtualAdapterName(name)) continue;
      for (final address in addresses) {
        if (address.type != InternetAddressType.IPv4) continue;
        if (address.isLoopback) continue;
        out.add((name, address));
      }
    }
    return out;
  }

  void _sendAllTargets() {
    for (final st in ssdpSearchTargets) {
      _sendPacket(buildSearchPacket(st));
    }
  }

  void _sendPacket(String packet) {
    final socket = _socket;
    final data = Uint8List.fromList(utf8.encode(packet));
    if (socket != null) {
      try {
        socket.send(data, InternetAddress(multicastGroup), multicastPort);
      } catch (_) {
        // 发送失败留给下一轮。
      }
    }
    // 每个接口 socket 各发一份：非默认路由接口上的设备才收得到
    // （主 socket 只从默认路由出）。默认路由接口会收到两份——设备重复
    // 应答由 LOCATION/USN 去重吸收。
    for (final ifaceSocket in _interfaceSockets) {
      try {
        ifaceSocket.send(data, InternetAddress(multicastGroup), multicastPort);
      } catch (_) {
        // 发送失败留给下一轮。
      }
    }
  }

  /// 收包入口：回环源不计入设备列表（见 [isIgnoredSource]）。
  void _handleDatagram(Datagram datagram) {
    if (isIgnoredSource(datagram.address)) return;
    _handlePacket(utf8.decode(datagram.data, allowMalformed: true));
  }

  /// 源地址过滤（M8 纯函数）：只过滤回环（127.0.0.0/8）。
  ///
  /// 刻意**不过滤**非回环的本机地址：同机接收端（AirPin / WMP 系接收软件、
  /// 本机 windows-dlna-receiver 集成测试 DMR）的 NOTIFY 源地址就是本机地址，
  /// 按本机地址过滤会把它们从设备列表里抹掉——这是可用设备，不是自环噪声。
  /// 我们自己发出的 M-SEARCH（multicastLoopback=false）本来就不会回环。
  static bool isIgnoredSource(InternetAddress address) => address.isLoopback;

  void _handlePacket(String text) {
    final headers = parseSsdpHeaders(text);
    if (headers == null) return;
    // 诊断埋点（M0）：原始 SSDP 报文（截断 + 去重 + 上限），纯采集。
    CastDiagnostics.instance.recordSsdpResponse(text);
    final location = headers['LOCATION'] ?? headers['Location'];
    final usn = headers['USN'] ?? headers['Usn'] ?? location ?? '';
    final nts = headers['NTS'];

    if (nts != null && nts.toLowerCase() == 'ssdp:byebye') {
      final entry = _devices.remove(usn);
      // M8 复活路径：同步清理该 USN 的 LOCATION 去重，复线的 alive NOTIFY
      // 才能重新拉描述（否则 location 永留 pending，设备再也回不来）。
      _forgetUsn(usn);
      if (entry != null) {
        _events?.add(SsdpDeviceOffline(entry.device.udn));
      }
      return;
    }
    if (location == null || location.isEmpty) return;
    final existing = _devices[usn];
    if (existing != null) {
      existing.seenAt = DateTime.now(); // 心跳刷新
      if (!existing.device.online) existing.device.online = true;
      return;
    }
    // M8 发现期预算：503/IO/坏 XML 的设备换下一条 advertisement，
    // 不在同一个 URL 上反复烧 GET（轮询结束后预算复位）。
    if ((_urlFetchAttempts[location] ?? 0) >= maxFetchAttemptsPerUrl ||
        _totalFetchAttempts >= maxFetchAttemptsTotal) {
      return;
    }
    if (!_pendingLocations.add(location)) return;
    _fetchDescription(location, usn);
  }

  /// 设备移出（byebye/TTL/复检失败）：清理 USN→LOCATION 与该 URL 的
  /// 拉取计数，让设备复线时能走完整的「拉描述 → 入表」流程。
  void _forgetUsn(String usn) {
    final location = _usnLocations.remove(usn);
    if (location != null) {
      _pendingLocations.remove(location);
      _urlFetchAttempts.remove(location);
    }
  }

  Future<void> _fetchDescription(String location, String usn) async {
    _urlFetchAttempts[location] = (_urlFetchAttempts[location] ?? 0) + 1;
    _totalFetchAttempts += 1;
    // 单次使用的 fetcher 用完即关：http.Client 的 keep-alive 连接若不关闭
    // 会以空闲 socket 形式积压（addByIp 的共享 fetcher 仍由其 finally 关闭）。
    final fetcher = _clientFactory();
    try {
      final body = await fetcher.fetchDescription(location);
      final device = parseDeviceDescription(body, location);
      if (device == null) return; // 无 AVTransport：不是投屏目标。
      _traceDeviceSummary(device);
      _usnLocations[usn] = location;
      _devices[usn] = _DeviceEntry(device: device, seenAt: DateTime.now());
      _events?.add(SsdpDeviceFound(device));
    } catch (_) {
      // 描述拉取失败：跳过该设备（下一轮 NOTIFY 或 M-SEARCH 会再触发）。
    } finally {
      // 拉取失败时放行重试；成功则保持去重。
      if (!_devices.containsKey(usn)) {
        _pendingLocations.remove(location);
      }
      if (fetcher is _HttpClientFetcher) fetcher.close();
    }
  }

  /// TTL 清理（5s 周期）。M8 设备保鲜：到期的设备不再立即判离线，而是先
  /// 对其描述 URL 做一次轻量复检（File2TV forget_if_gone 思路）——
  /// 连得上说明设备还活着（只是不发 NOTIFY），刷新在席时间保留；
  /// 连不上立即移除并标记离线，同时走复活路径清理，复线即刻可再入表。
  void _sweepExpired(StreamController<SsdpEvent> events) {
    final now = DateTime.now();
    final expired = _devices.entries
        .where((e) =>
            now.difference(e.value.seenAt) > deviceTtl && !e.value.rechecking)
        .toList();
    for (final e in expired) {
      e.value.rechecking = true;
      unawaited(_recheckDevice(e.key, e.value, events));
    }
  }

  Future<void> _recheckDevice(
    String usn,
    _DeviceEntry entry,
    StreamController<SsdpEvent> events,
  ) async {
    final location = _usnLocations[usn] ?? entry.device.location;
    var alive = false;
    final fetcher = _clientFactory();
    try {
      await fetcher.fetchDescription(location);
      alive = true;
    } catch (_) {
      alive = false;
    } finally {
      if (fetcher is _HttpClientFetcher) fetcher.close();
    }
    entry.rechecking = false;
    if (_devices[usn] != entry) return; // 复检期间已被 byebye/stop 移除。
    if (alive) {
      entry.seenAt = DateTime.now(); // 设备仍在：续期，不产生离线事件。
      return;
    }
    _devices.remove(usn);
    _forgetUsn(usn);
    events.add(SsdpDeviceOffline(entry.device.udn));
  }

  /// 常见 DLNA / 私有接收端描述端口（projection 路线）。
  static const List<int> commonPorts = <int>[
    80, 3000, 5000, 7000, 8000, 8008, 8060, 8080, 8888,
  ];

  /// VIDAA / HappyCast / 乐播等国产接收端常见的动态端口段（闭区间）。
  static const int dynamicPortStart = 49152;
  static const int dynamicPortEnd = 49200;

  /// 手动添加 IP：常见端口 + 国产设备动态端口段，并发探测既有 4 个描述路径。
  ///
  /// [port] 保留旧签名（默认 49152）并作为首选端口，公开调用完全兼容；
  /// [candidatePorts] / [perPortTimeout] / [totalBudget] / [concurrency]
  /// 均带默认值，便于单测注入。每个端口最多 [perPortTimeout]、整体不超过
  /// [totalBudget]，同时最多 [concurrency] 个端口在探测，命中即停。
  Future<DlnaDevice?> addByIp(
    String host, {
    int port = 49152,
    List<int>? candidatePorts,
    Duration perPortTimeout = const Duration(milliseconds: 300),
    Duration totalBudget = const Duration(seconds: 6),
    int concurrency = 8,
  }) async {
    const paths = ['/description.xml', '/DeviceDescription.xml', '/dd.xml', '/'];
    final extra = candidatePorts ??
        <int>[
          ...commonPorts,
          for (var p = dynamicPortStart; p <= dynamicPortEnd; p++) p,
        ];
    final candidates = <int>[if (port > 0) port, ...extra];
    final seen = <int>{};
    final ports = <int>[for (final p in candidates) if (seen.add(p)) p];
    if (ports.isEmpty) return null;

    // 端口候选扩到 ~58 个后复用单个 fetcher：避免每个请求都新建 http.Client
    // （原实现的短生命周期客户端会被放大成大量空闲 socket）。
    final fetcher = _clientFactory();
    final stopwatch = Stopwatch()..start();
    var cursor = 0;
    DlnaDevice? found;

    Future<void> probeWorker() async {
      while (found == null && stopwatch.elapsed < totalBudget) {
        final i = cursor++;
        if (i >= ports.length) return;
        final p = ports[i];
        final portStart = stopwatch.elapsed;
        for (final path in paths) {
          if (found != null || stopwatch.elapsed >= totalBudget) return;
          final remaining = perPortTimeout - (stopwatch.elapsed - portStart);
          if (remaining <= Duration.zero) break;
          final location = 'http://$host:$p$path';
          try {
            final body = await fetcher
                .fetchDescription(location)
                .timeout(remaining);
            final device = parseDeviceDescription(body, location);
            // await 之后的同步区不会交错：只让第一个命中的 worker 写表/发事件。
            if (device != null && found == null) {
              _traceDeviceSummary(device);
              found = device;
              _usnLocations[device.udn] = location;
              _devices[device.udn] =
                  _DeviceEntry(device: device, seenAt: DateTime.now());
              _events?.add(SsdpDeviceFound(device));
              return;
            }
          } catch (_) {
            // 超时 / 连接拒绝 / 非描述 XML：继续下一路径、下一端口。
          }
        }
      }
    }

    final workers = List<Future<void>>.generate(
      concurrency < ports.length ? concurrency : ports.length,
      (_) => probeWorker(),
    );
    try {
      await Future.wait(workers).timeout(
        totalBudget + perPortTimeout,
        onTimeout: () => <void>[],
      );
    } finally {
      // 超时的 in-flight 请求随 client 关闭一起中断；注入的测试 fetcher 不受影响。
      if (fetcher is _HttpClientFetcher) fetcher.close();
    }
    return found;
  }

  List<DlnaDevice> get devices =>
      _devices.values.map((e) => e.device).toList();

  // ---------------------------------------------------------------------------
  // 单测钩子（@visibleForTesting）：SSDP 状态机由 UDP 收包与定时器驱动，
  // 直接打真实组播无法断言；用钩子注入报文/推进时间。
  // ---------------------------------------------------------------------------

  /// 注入一条 SSDP 报文（M-SEARCH 应答 / NOTIFY），[source] 模拟来源地址
  /// （回环过滤断言用，与 [_handleDatagram] 同一判定），缺省视为普通局域网地址。
  @visibleForTesting
  void handlePacketForTest(String text, {InternetAddress? source}) {
    if (source != null && isIgnoredSource(source)) return;
    _handlePacket(text);
  }

  /// 立即执行一次 TTL 清理/复检 sweep（不等 5s 定时器）。
  @visibleForTesting
  void sweepForTest() {
    final events = _events;
    if (events == null) return;
    _sweepExpired(events);
  }

  /// 把指定 UDN 的最后在席时间回拨到 TTL 之外（配合 [sweepForTest]）。
  @visibleForTesting
  void expireDeviceForTest(String udn) {
    for (final e in _devices.values) {
      if (e.device.udn == udn) {
        e.seenAt = DateTime.now().subtract(deviceTtl * 2);
      }
    }
  }

  /// 设备描述摘要埋点（M0 纯采集；关键字段一行一条，不含完整 XML）。
  static void _traceDeviceSummary(DlnaDevice d) {
    CastDiagnostics.instance.recordDeviceSummary(
      'friendlyName=${d.friendlyName} · model=${d.modelName} · '
      'manufacturer=${d.manufacturer} · udn=${d.udn} · controlUrl=${d.controlUrl}',
    );
  }
}

class _DeviceEntry {
  _DeviceEntry({required this.device, required this.seenAt});
  final DlnaDevice device;
  DateTime seenAt;

  /// TTL 到期后的描述 URL 复检进行中（防止 5s sweep 堆积重复请求）。
  bool rechecking = false;
}

typedef DescriptionFetcherFactory = DescriptionFetcher Function();

abstract class DescriptionFetcher {
  Future<String> fetchDescription(String url);
}

class _HttpClientFetcher implements DescriptionFetcher {
  final http.Client _client = http.Client();

  void close() => _client.close();

  @override
  Future<String> fetchDescription(String url) async {
    final res = await _client
        .get(Uri.parse(url))
        .timeout(descriptionTimeout);
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode}');
    }
    if (res.bodyBytes.length > maxDescriptionBytes) {
      throw HttpException('描述过大');
    }
    return utf8.decode(res.bodyBytes, allowMalformed: true);
  }
}

DescriptionFetcher _defaultFactory() => _HttpClientFetcher();

/// 构造 M-SEARCH 报文（CineFlow 同款格式 + UA 头）。
///
/// USER-AGENT / HX-USER-AGENT / X-USER-AGENT（MRDLNA 实证）：部分接收端
/// （尤其国产电视/盒子）对不带 UA 的控制点直接不应答，带 UA 更稳；
/// 版本号仅作产品标识，不要求与 pubspec 严格同步。
String buildSearchPacket(String st) {
  return 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $multicastGroup:$multicastPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $st\r\n'
      'USER-AGENT: $ssdpUserAgent\r\n'
      'HX-USER-AGENT: $ssdpUserAgent\r\n'
      'X-USER-AGENT: $ssdpUserAgent\r\n'
      '\r\n';
}

/// M-SEARCH 的 USER-AGENT 值（三处 UA 头共用）。
const String ssdpUserAgent = 'aquan-duanju/1.6 UPnP/1.1';

/// M-SEARCH 的 ST 目标集合（M8 加固：在 MediaRenderer/rootdevice/ssdp:all
/// 基础上追加 AVTransport:1——部分设备只应答服务类型检索，不删既有项）。
const List<String> ssdpSearchTargets = <String>[
  'urn:schemas-upnp-org:device:MediaRenderer:1',
  'upnp:rootdevice',
  'ssdp:all',
  'urn:schemas-upnp-org:service:AVTransport:1',
];

/// 解析 SSDP 响应/NOTIFY 头（键大小写不敏感，保留原样大写键）；
/// 非 SSDP 报文（无 HTTP 头）返回 null。
Map<String, String>? parseSsdpHeaders(String text) {
  final headEnd = text.indexOf('\r\n\r\n');
  final headerBlock =
      headEnd >= 0 ? text.substring(0, headEnd) : text.split('\n\n').first;
  final lines = headerBlock.split(RegExp(r'\r?\n'));
  if (lines.isEmpty) return null;
  final first = lines.first.trim();
  if (!first.startsWith('HTTP/1.') &&
      !first.startsWith('NOTIFY') &&
      !first.startsWith('M-SEARCH')) {
    return null;
  }
  final out = <String, String>{};
  for (var i = 1; i < lines.length; i++) {
    final colon = lines[i].indexOf(':');
    if (colon <= 0) continue;
    final key = lines[i].substring(0, colon).trim().toUpperCase();
    out[key] = lines[i].substring(colon + 1).trim();
  }
  return out;
}
