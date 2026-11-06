import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../error_log.dart';
import 'cast_diagnostics.dart';
import 'dlna_device.dart';

/// SSDP 设备发现（UPnP 1.0）：M-SEARCH 三目标 × 4 轮 + NOTIFY 监听。
///
/// 参数对齐 CineFlow cast.cjs（实测有效）：ST 三目标各一轮、1.5s 一轮共 4 轮、
/// TTL 4、设备表 TTL 26s；`ssdp:byebye` 置离线；同一 LOCATION 只拉一次描述。
const String multicastGroup = '239.255.255.250';
const int multicastPort = 1900;
const Duration deviceTtl = Duration(seconds: 26);
const int discoveryRounds = 4;
const Duration roundInterval = Duration(milliseconds: 1500);
const Duration descriptionTimeout = Duration(milliseconds: 1800);
const int maxDescriptionBytes = 256 * 1024;
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

  /// USN → 设备（含 TTL 时间戳）。
  final Map<String, _DeviceEntry> _devices = {};


  Stream<SsdpEvent> start() {
    if (_scanning) return _events!.stream;
    _scanning = true;
    _pendingLocations.clear();
    final events = _events = StreamController<SsdpEvent>.broadcast();
    _bind().then((_) {
      _sendAllTargets();
      _roundsLeft = discoveryRounds - 1;
      _roundTimer = Timer.periodic(roundInterval, (_) {
        if (_roundsLeft <= 0) {
          _roundTimer?.cancel();
          _roundTimer = null;
          // 轮询结束不代表发现结束（NOTIFY 仍监听）；只发一次扫描完成信号。
          events.add(const SsdpScanDone());
          return;
        }
        _roundsLeft--;
        _sendAllTargets();
      });
      _pruneTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        final now = DateTime.now();
        final expired = _devices.entries
            .where((e) => now.difference(e.value.seenAt) > deviceTtl)
            .toList();
        for (final e in expired) {
          _devices.remove(e.key);
          events.add(SsdpDeviceOffline(e.value.device.udn));
        }
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
    _devices.clear();
    _pendingLocations.clear();
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
      _handlePacket(utf8.decode(datagram.data, allowMalformed: true));
    });
    _socket = socket;
    SsdpDiscovery.lastBoundPort = _boundPort;
  }

  void _sendAllTargets() {
    const targets = [
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'upnp:rootdevice',
      'ssdp:all',
    ];
    for (final st in targets) {
      _sendPacket(buildSearchPacket(st));
    }
  }

  void _sendPacket(String packet) {
    final socket = _socket;
    if (socket == null) return;
    final data = Uint8List.fromList(utf8.encode(packet));
    try {
      socket.send(data, InternetAddress(multicastGroup), multicastPort);
    } catch (_) {
      // 发送失败留给下一轮。
    }
  }

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
    if (!_pendingLocations.add(location)) return;
    _fetchDescription(location, usn);
  }

  Future<void> _fetchDescription(String location, String usn) async {
    try {
      final body = await _clientFactory().fetchDescription(location);
      final device = parseDeviceDescription(body, location);
      if (device == null) return; // 无 AVTransport：不是投屏目标。
      _traceDeviceSummary(device);
      _devices[usn] = _DeviceEntry(device: device, seenAt: DateTime.now());
      _events?.add(SsdpDeviceFound(device));
    } catch (_) {
      // 描述拉取失败：跳过该设备（下一轮 NOTIFY 或 M-SEARCH 会再触发）。
    } finally {
      // 拉取失败时放行重试；成功则保持去重。
      if (!_devices.containsKey(usn)) {
        _pendingLocations.remove(location);
      }
    }
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

/// 构造 M-SEARCH 报文（CineFlow 同款格式）。
String buildSearchPacket(String st) {
  return 'M-SEARCH * HTTP/1.1\r\n'
      'HOST: $multicastGroup:$multicastPort\r\n'
      'MAN: "ssdp:discover"\r\n'
      'MX: 2\r\n'
      'ST: $st\r\n'
      '\r\n';
}

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
