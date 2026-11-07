import 'package:xml/xml.dart';

import 'didl.dart';

/// 缺省 AVTransport serviceType（设备描述缺失/旧持久化时的回落值）。
const String kDefaultAvtServiceType =
    'urn:schemas-upnp-org:service:AVTransport:1';

/// DLNA 设备模型与描述 XML 解析。
///
/// 描述文档语义（UPnP Device Architecture 1.0）：
/// `LOCATION` 指向设备描述 XML；`URLBase`（可选）是相对地址的解析基址；
/// AVTransport 服务的 `controlURL` 是投屏控制端点——没有 AVTransport 的
/// 设备不是投屏目标（如打印机/灯泡也会响应 SSDP）。
class DlnaDevice {
  DlnaDevice({
    required this.udn,
    required this.friendlyName,
    this.modelName = '',
    this.manufacturer = '',
    this.serviceType = kDefaultAvtServiceType,
    required this.controlUrl,
    this.renderingControlUrl = '',
    this.connectionManagerUrl = '',
    this.eventSubUrl = '',
    this.location = '',
    DateTime? discoveredAt,
    this.online = true,
  }) : discoveredAt = discoveredAt ?? DateTime.now();

  final String udn;
  final String friendlyName;
  final String modelName;

  /// 厂商名（设备配方指纹的一段）；旧描述/旧持久化缺省空串。
  final String manufacturer;

  /// AVTransport **真实 serviceType**（原始串含版本，如 `…:AVTransport:2`）。
  ///
  /// SOAP 信封的 `xmlns:u` 与 SOAPACTION 头都必须精确等于它——严格接收端
  /// （puppy-store-cast HttpServer）校验两者 == 设备宣告值，硬编码 `:1` 的
  /// 设备会报 401。设备宣告多个版本时取最高（castor family.go：many
  /// implement :3, not just :1）。缺省回落 [kDefaultAvtServiceType]。
  final String serviceType;

  /// AVTransport controlURL（绝对地址）。
  final String controlUrl;
  final String renderingControlUrl;

  /// ConnectionManager controlURL（GetProtocolInfo 预检）；空 = 无预检能力。
  final String connectionManagerUrl;

  /// AVTransport 事件订阅地址（GENA）；空 = 不支持，纯轮询。
  final String eventSubUrl;
  final String location;
  DateTime discoveredAt;
  bool online;

  Map<String, dynamic> toPersistJson() => {
        'udn': udn,
        'name': friendlyName,
        'model': modelName,
        'manufacturer': manufacturer,
        'service_type': serviceType,
        'control_url': controlUrl,
        'rendering_control_url': renderingControlUrl,
        'connection_manager_url': connectionManagerUrl,
        'event_sub_url': eventSubUrl,
        'location': location,
      };

  /// v1/v2 没有 `manufacturer` / `connection_manager_url` / `service_type`：
  /// 缺省空串/缺省 URN 即可读。
  factory DlnaDevice.fromPersistJson(Map<String, dynamic> json) {
    final serviceType = json['service_type'] as String? ?? '';
    return DlnaDevice(
      udn: json['udn'] as String? ?? '',
      friendlyName: json['name'] as String? ?? '',
      modelName: json['model'] as String? ?? '',
      manufacturer: json['manufacturer'] as String? ?? '',
      serviceType:
          serviceType.isEmpty ? kDefaultAvtServiceType : serviceType,
      controlUrl: json['control_url'] as String? ?? '',
      renderingControlUrl: json['rendering_control_url'] as String? ?? '',
      connectionManagerUrl: json['connection_manager_url'] as String? ?? '',
      eventSubUrl: json['event_sub_url'] as String? ?? '',
      location: json['location'] as String? ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DlnaDevice && other.udn == udn && other.udn.isNotEmpty;

  @override
  int get hashCode => udn.hashCode;

  @override
  String toString() => 'DlnaDevice($friendlyName, $controlUrl)';
}

/// 设备描述里 `controlURL` 缺失时的惯例路径（按命中率排序）。
const List<String> kAvtControlFallbacks = <String>[
  '/AVTransport/control',
  '/upnp/control/AVTransport',
  '/control/AVTransport',
];

final RegExp _ipv4 = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$');
final RegExp _hasLetter = RegExp(r'[A-Za-z]');

/// 把设备给的 `controlURL` 修成「本机连得上」的地址。
///
/// 国产电视/盒子的描述文件经常写错：
/// - 写成 `http://localhost:8080/...` 或 `127.0.0.1`（设备视角的本机）；
/// - 写成内网域名（DNS 解析不了，但同网段 IP 能通）；
/// - 干脆不写 `controlURL`，只在 `serviceType` 里声明了服务。
///
/// 兜底策略：host 一律取 `LOCATION` 的 host；端口优先用 `controlURL` 自己的，
/// 没写就继承 `LOCATION`；路径为空时按惯例路径猜。
Uri? rebuildControlUrl({
  required String controlUrl,
  required String location,
  List<String> fallbackPaths = kAvtControlFallbacks,
}) {
  final loc = Uri.tryParse(location);
  if (loc == null || loc.host.isEmpty) {
    final raw = Uri.tryParse(controlUrl);
    return raw != null && raw.host.isNotEmpty ? raw : null;
  }

  final ctrl = Uri.tryParse(controlUrl);
  final locIsIp = _ipv4.hasMatch(loc.host);

  var path = ctrl?.path ?? '';
  var query = ctrl?.query ?? '';
  var scheme = ctrl != null && ctrl.scheme.isNotEmpty ? ctrl.scheme : loc.scheme;

  // 决定 host：设备自指地址一律换掉；域名 + LOCATION 是 IP 时也换（局域网 DNS 通常不通）。
  var host = loc.host;
  if (ctrl != null && ctrl.host.isNotEmpty) {
    final selfRef = ctrl.host == 'localhost' ||
        ctrl.host == '127.0.0.1' ||
        ctrl.host == '0.0.0.0' ||
        ctrl.host == '[::1]';
    final domainButIpKnown = locIsIp && _hasLetter.hasMatch(ctrl.host);
    if (!selfRef && !domainButIpKnown) host = ctrl.host;
  }

  // 端口：优先 controlURL 自己的（部分设备控制端口与描述端口不同），没写才继承 LOCATION。
  int? port = ctrl != null && ctrl.hasPort ? ctrl.port : null;
  port ??= loc.hasPort ? loc.port : null;

  if (path.isEmpty || path == '/') {
    path = fallbackPaths.isEmpty ? '/AVTransport/control' : fallbackPaths.first;
    query = '';
  }
  if (scheme.isEmpty) scheme = 'http';

  return Uri(
    scheme: scheme,
    host: host,
    port: port,
    path: path,
    query: query.isEmpty ? null : query,
  );
}

/// 解析设备描述 XML；没有 AVTransport 服务时返回 null（非投屏目标）。
///
/// 遍历**所有** `<device>`（含 embedded device）找 AVTransport /
/// RenderingControl / ConnectionManager；命中 AVTransport 的那个 device
/// 才是 friendlyName / UDN / manufacturer 的归属（国产盒子常把渲染器放在
/// 嵌入设备里，只认根 device 会拿到错误型号甚至丢弃设备）。
DlnaDevice? parseDeviceDescription(String xmlText, String location) {
  XmlDocument doc;
  try {
    doc = XmlDocument.parse(xmlText);
  } catch (_) {
    return null;
  }

  // 先看直接子级，避免 embedded device 的同名节点串到父级；
  // 描述文件偶有不规范嵌套，再退化为全后代搜索。
  String? textOf(XmlElement parent, String localName) {
    for (final e in parent.childElements) {
      if (e.name.local == localName) return e.innerText.trim();
    }
    for (final e in parent.descendantElements) {
      if (e.name.local == localName) return e.innerText.trim();
    }
    return null;
  }

  // 只取「本 device 直属」的 service：embedded device 的服务应由它自己认领，
  // 否则父 device 会通过 descendantElements 把子 device 的 AVTransport 抢走。
  Iterable<XmlElement> servicesOf(XmlElement device) sync* {
    for (final child in device.childElements) {
      if (child.name.local == 'service') yield child;
      if (child.name.local == 'serviceList') {
        for (final s in child.childElements) {
          if (s.name.local == 'service') yield s;
        }
      }
    }
  }

  final root = doc.rootElement;
  // root 可能带命名空间前缀（device/Device）；按 localName 收集全部 device。
  final devices = <XmlElement>[
    if (root.name.local == 'device') root,
    for (final e in root.descendantElements)
      if (e.name.local == 'device') e,
  ];
  if (devices.isEmpty) return null;

  // URLBase：描述内相对地址的基址；缺省用 LOCATION 本身。
  final urlBase = textOf(root, 'URLBase');
  final baseUri =
      Uri.tryParse(urlBase != null && urlBase.isNotEmpty ? urlBase : location) ??
          Uri.parse(location);
  Uri resolve(String ref) {
    final uri = Uri.tryParse(ref);
    if (uri == null) return baseUri;
    if (uri.hasScheme && uri.host.isNotEmpty) return uri;
    try {
      return baseUri.resolve(ref);
    } catch (_) {
      return uri;
    }
  }

  String? avtControl;
  String? rcsControl;
  String? cmControl;
  String? avtEventSub;
  XmlElement? avtDevice;
  // 设备可能宣告多个 AVTransport 版本（:1/:2/:3 并存）——全部收集后取最高。
  final avtServiceTypes = <String>[];
  for (final device in devices) {
    for (final service in servicesOf(device)) {
      final serviceType = textOf(service, 'serviceType') ?? '';
      final isAvt = serviceType.contains('AVTransport');
      final isRcs = serviceType.contains('RenderingControl');
      final isCm = serviceType.contains('ConnectionManager');
      if (!isAvt && !isRcs && !isCm) continue;
      if (isAvt) avtServiceTypes.add(serviceType);
      final rawControl = textOf(service, 'controlURL') ?? '';
      // ConnectionManager 是可选能力；没有 controlURL 时不猜路径，
      // 免得把 AVTransport 的惯例路径当预检地址多发一次请求。
      if (isCm && rawControl.isEmpty) continue;
      // 先按 URLBase/LOCATION 解析相对地址，再按「设备自指 / 域名 vs IP」兜底重建。
      final resolved = rawControl.isEmpty
          ? location
          : resolve(rawControl).toString();
      final rebuilt = rebuildControlUrl(
        controlUrl: rawControl.isEmpty ? '' : resolved,
        location: location,
      );
      if (rebuilt == null) continue;
      if (isAvt) {
        if (avtControl == null) {
          avtControl = rebuilt.toString();
          avtDevice = device;
        }
        final rawEvent = textOf(service, 'eventSubURL') ?? '';
        if (rawEvent.isNotEmpty) {
          avtEventSub ??= rebuildControlUrl(
                  controlUrl: resolve(rawEvent).toString(), location: location)
              ?.toString();
        }
      } else if (isRcs) {
        rcsControl ??= rebuilt.toString();
      } else {
        cmControl ??= rebuilt.toString();
      }
    }
  }
  if (avtControl == null) return null;

  final picked = avtDevice ?? devices.first;
  final udn = textOf(picked, 'UDN') ?? '';
  return DlnaDevice(
    udn: udn.isEmpty ? location : udn,
    friendlyName: textOf(picked, 'friendlyName') ?? '未命名设备',
    modelName: textOf(picked, 'modelName') ?? '',
    manufacturer: textOf(picked, 'manufacturer') ?? '',
    serviceType: bestAvtServiceType(avtServiceTypes),
    controlUrl: avtControl,
    renderingControlUrl: rcsControl ?? '',
    connectionManagerUrl: cmControl ?? '',
    eventSubUrl: avtEventSub ?? '',
    location: location,
  );
}

/// 从设备宣告的 AVTransport serviceType 原始串里挑「最高版本」的那条。
///
/// castor family.go 先例（serviceVersions = [3,2,1]）：很多设备实现的是 :3
/// 而不只是 :1，goupnp 硬编码 :1 是反面教材。规则：
/// - 标准形状 `urn:schemas-upnp-org:service:AVTransport:<n>` → 取 n 最大者；
/// - 只有非标形状（仍含 AVTransport 字样）→ 原样保留第一条；
/// - 全部缺失 → [kDefaultAvtServiceType]。
String bestAvtServiceType(Iterable<String> rawTypes) {
  String? best;
  var bestVersion = -1;
  String? anyAvt;
  for (final raw in rawTypes) {
    final t = raw.trim();
    if (t.isEmpty || !t.contains('AVTransport')) continue;
    anyAvt ??= t;
    final m = RegExp(r'AVTransport:(\d+)\s*$').firstMatch(t);
    final version = m == null ? -1 : int.tryParse(m.group(1)!) ?? -1;
    if (version > bestVersion) {
      bestVersion = version;
      best = t;
    }
  }
  return best ?? anyAvt ?? kDefaultAvtServiceType;
}

/// DIDL-Lite 元数据（SetAVTransportURI 的 CurrentURIMetaData）。
///
/// 保留旧签名（部分盒子校验非空才收，统一带最小 DIDL；[subtitleUrl]
/// 非空时带字幕标签），实现转发到 `didl.dart` 的 [DidlVariant.compact]
/// 变体 + wildcard 模板（旧调用点没有 mime 信息，protocolInfo 保持
/// 容器无关），避免两套生成逻辑漂移。
String buildDidlLite({
  required String title,
  String? duration,
  String itemClass = 'object.item.videoItem',
  Uri? subtitleUrl,
}) =>
    buildDidl(
      DidlRequest(
        // 旧调用点没有媒体 URI，`<res>` 保持空内容；新调用点走 buildDidl。
        uri: Uri(),
        title: title,
        subtitleUri: subtitleUrl,
      ),
      DidlVariant.compact,
      durationText: duration,
      itemClass: itemClass,
      template: DidlProtocolInfoTemplate.wildcard,
    );
