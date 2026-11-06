import 'dlna_device.dart';

/// 投屏协议。同一物理设备可能同时支持多种（如 Google TV 既是 Chromecast 又是
/// DLNA MediaRenderer）；连接失败时控制器按同 IP 换协议降级一次。
enum CastProtocol { dlna, chromecast }

/// Chromecast 设备端点（mDNS `_googlecast._tcp` 发现结果）。
class CastDeviceInfo {
  const CastDeviceInfo({
    required this.host,
    this.port = 8009,
    this.name = '',
    this.modelName = '',
  });

  final String host;
  final int port;
  final String name;
  final String modelName;

  Map<String, dynamic> toPersistJson() => {
        'host': host,
        'port': port,
        'name': name,
        'model': modelName,
      };

  factory CastDeviceInfo.fromPersistJson(Map<String, dynamic> json) =>
      CastDeviceInfo(
        host: json['host'] as String? ?? '',
        port: json['port'] as int? ?? 8009,
        name: json['name'] as String? ?? '',
        modelName: json['model'] as String? ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is CastDeviceInfo && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);
}

/// 可投屏目标（协议无关视图）。
///
/// - DLNA：包装 [DlnaDevice]，id 用 UDN；
/// - Chromecast：包装 [CastDeviceInfo]，id 用 `cast:<host>:<port>`（稳定可持久化）。
class CastTarget {
  CastTarget.dlna(DlnaDevice this.dlna)
      : id = dlna.udn,
        name = dlna.friendlyName,
        modelName = dlna.modelName,
        manufacturer = dlna.manufacturer,
        protocol = CastProtocol.dlna,
        host = Uri.tryParse(dlna.location.isNotEmpty ? dlna.location : dlna.controlUrl)
                ?.host ??
            '',
        online = dlna.online,
        cast = null;

  CastTarget.chromecast(CastDeviceInfo this.cast, {this.online = true})
      : id = 'cast:${cast.host}:${cast.port}',
        name = cast.name.isEmpty ? cast.host : cast.name,
        modelName = cast.modelName,
        manufacturer = '',
        protocol = CastProtocol.chromecast,
        host = cast.host,
        dlna = null;

  final String id;
  final String name;
  final String modelName;

  /// 设备配方指纹的一段；Chromecast 无 manufacturer 时为空串。
  /// 注意 [id] 语义不变：DLNA = UDN，Chromecast = `cast:<host>:<port>`。
  final String manufacturer;
  final CastProtocol protocol;
  final String host;
  bool online;

  /// 协议专属载体；[protocol] 对应的一方非空。
  final DlnaDevice? dlna;
  final CastDeviceInfo? cast;

  Map<String, dynamic> toPersistJson() {
    switch (protocol) {
      case CastProtocol.dlna:
        return {'protocol': 'dlna', ...?dlna?.toPersistJson()};
      case CastProtocol.chromecast:
        return {'protocol': 'chromecast', ...?cast?.toPersistJson()};
    }
  }

  /// v1 存储（无 protocol 字段）一律按 DLNA 解析，老 json 完全兼容。
  static CastTarget? fromPersistJson(Map<String, dynamic> json) {
    final protocol = json['protocol'] as String? ?? 'dlna';
    switch (protocol) {
      case 'chromecast':
        final info = CastDeviceInfo.fromPersistJson(json);
        return info.host.isEmpty ? null : CastTarget.chromecast(info);
      default:
        final d = DlnaDevice.fromPersistJson(json);
        if (d.udn.isEmpty || d.controlUrl.isEmpty) return null;
        return CastTarget.dlna(d);
    }
  }

  @override
  bool operator ==(Object other) => other is CastTarget && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'CastTarget($protocol, $name, $host)';
}

/// 投屏传输层异常（区别于 SoapException，但控制器同等处理）。
class CastException implements Exception {
  CastException(this.message);
  final String message;

  @override
  String toString() => message;
}
