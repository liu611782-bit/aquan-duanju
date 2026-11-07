import 'cast_diagnostics.dart';
import 'dlna_device.dart';

/// 内置通用画像 id（design §3.2；**行为驱动**判定，不做厂商名分支——
/// 8 个开源参照项目 0 个有厂商分支，厂商名与固件都会变）。
const String kProfileGeneric = 'generic';

/// 历史上因缺 `dc:title` 被拒（402/崩溃）的设备。
const String kProfileStrictTitle = 'strictTitle';

/// Sink 宣告了 HLS 却曾拒播带 `.m3u8` 扩展名 URL 的设备。
const String kProfileHlsByUrl = 'hlsByUrl';

/// Sink 条目全部带 `DLNA.ORG_PN`（对方按 PN 匹配）的设备。
const String kProfilePnRequired = 'pnRequired';

/// 已知画像 id（JSON 读入时未知值回落 [kProfileGeneric]）。
const Set<String> kKnownProfileIds = {
  kProfileGeneric,
  kProfileStrictTitle,
  kProfileHlsByUrl,
  kProfilePnRequired,
};

/// 能力位（[CastDeviceProfile.capabilities] 的约定键）。
const String kCapGetProtocolInfo = 'getProtocolInfo';
const String kCapRenderingControl = 'renderingControl';
const String kCapEventSub = 'eventSub';
const String kCapRangeSupport = 'rangeSupport';
const String kCapStrictTitle = 'strictTitle';
const String kCapFetchedStream = 'fetchedStream';

/// 设备的「能力画像」，按**观测**而非厂商名构建（design §3.2）。
///
/// 画像回答三个问题：这台设备宣告了什么（serviceType / Sink）、它具备哪些
/// 观测到的能力（capabilities）、它该从哪条内置预设起步（profileId）。
class CastDeviceProfile {
  const CastDeviceProfile({
    required this.udn,
    this.friendlyName = '',
    this.manufacturer = '',
    this.modelName = '',
    this.serviceType = '',
    this.avTransportVersion = 1,
    this.sinkProtocols = const <String>[],
    this.capabilities = const <String>{},
    this.profileId = kProfileGeneric,
  });

  final String udn;
  final String friendlyName;
  final String manufacturer;
  final String modelName;

  /// 设备描述里的真实 AVTransport serviceType（原始串含版本）。
  final String serviceType;

  /// AVTransport 版本号（`…:AVTransport:2` → 2；非标/缺失 → 1）。
  final int avTransportVersion;

  /// GetProtocolInfo 的 Sink 逐条（预检结果快照）。
  final List<String> sinkProtocols;

  /// 观测到的能力位（[kCapGetProtocolInfo] 等约定键）。
  final Set<String> capabilities;

  /// 内置通用画像 id（[kProfileGeneric] 等）。
  final String profileId;

  /// 共享画像键（design §3.2）：同型号同厂的设备共享观测结论。
  String get modelKey => '$modelName|$manufacturer';

  bool hasCapability(String capability) => capabilities.contains(capability);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'udn': udn,
        if (friendlyName.isNotEmpty) 'friendlyName': friendlyName,
        if (manufacturer.isNotEmpty) 'manufacturer': manufacturer,
        if (modelName.isNotEmpty) 'modelName': modelName,
        if (serviceType.isNotEmpty) 'serviceType': serviceType,
        'avTransportVersion': avTransportVersion,
        if (sinkProtocols.isNotEmpty) 'sinkProtocols': sinkProtocols,
        if (capabilities.isNotEmpty)
          'capabilities': capabilities.toList()..sort(),
        'profileId': profileId,
      };

  factory CastDeviceProfile.fromJson(Map<String, dynamic> json) {
    final profileId = json['profileId'] as String? ?? kProfileGeneric;
    return CastDeviceProfile(
      udn: json['udn'] as String? ?? '',
      friendlyName: json['friendlyName'] as String? ?? '',
      manufacturer: json['manufacturer'] as String? ?? '',
      modelName: json['modelName'] as String? ?? '',
      serviceType: json['serviceType'] as String? ?? '',
      avTransportVersion: json['avTransportVersion'] as int? ?? 1,
      sinkProtocols: <String>[
        for (final s in (json['sinkProtocols'] as List? ?? const <dynamic>[]))
          if (s is String && s.trim().isNotEmpty) s.trim(),
      ],
      capabilities: <String>{
        for (final s in (json['capabilities'] as List? ?? const <dynamic>[]))
          if (s is String && s.trim().isNotEmpty) s.trim(),
      },
      profileId:
          kKnownProfileIds.contains(profileId) ? profileId : kProfileGeneric,
    );
  }

  @override
  String toString() => 'CastDeviceProfile($udn, $profileId, '
      'capabilities=${capabilities.toList()..sort()})';
}

/// 从设备描述与本次会话观测构建画像（design §4.5 画像构建）。
///
/// - [sink]：预检（GetProtocolInfo）拿到的 Sink 清单；
/// - [preflightOk]：预检请求本身是否成功（Sink 非空且预检成功才记
///   [kCapGetProtocolInfo]）；
/// - [mediaRequests]：电视对本机媒体服务的取流记录（推导
///   [kCapRangeSupport] / [kCapFetchedStream]）；
/// - [soapTraces]：SOAP 记录（推导「因缺 title 被拒」类历史）。
CastDeviceProfile buildProfile(
  DlnaDevice d, {
  List<String> sink = const <String>[],
  bool preflightOk = false,
  Iterable<MediaRequestTrace> mediaRequests = const <MediaRequestTrace>[],
  Iterable<SoapTrace> soapTraces = const <SoapTrace>[],
}) {
  final sinks = <String>[
    for (final s in sink)
      if (s.trim().isNotEmpty) s.trim(),
  ];
  final requests = mediaRequests.toList(growable: false);
  final failedSetUris = soapTraces
      .where((t) => t.action == 'SetAVTransportURI' && t.isFailure)
      .toList(growable: false);

  final caps = <String>{
    // 预检成功且 Sink 非空才算「拿到了对方能力清单」。
    if (preflightOk && sinks.isNotEmpty) kCapGetProtocolInfo,
    // 设备描述里有 RenderingControl service（音量/静音可用）。
    if (d.renderingControlUrl.isNotEmpty) kCapRenderingControl,
    // 有 eventSubURL（GENA 订阅可用）。
    if (d.eventSubUrl.isNotEmpty) kCapEventSub,
    // 电视取流时出现过 Range 头（支持拖动）。
    if (requests.any((m) => (m.range ?? '').isNotEmpty)) kCapRangeSupport,
    // 历史上成功来取过流（2xx）。
    if (requests.any((m) => m.isOk)) kCapFetchedStream,
    // 历史上因缺 dc:title 被拒：失败的 SetAVTransportURI 请求体里没有 title。
    if (failedSetUris
        .any((t) => !t.requestBody.toLowerCase().contains('<dc:title')))
      kCapStrictTitle,
  };

  // profileId 行为驱动判定（design §3.2，优先级 strictTitle > hlsByUrl >
  // pnRequired > generic）。
  final sinkHasHls = sinks.any((s) => s.toLowerCase().contains('mpegurl'));
  final rejectedHlsUrl =
      failedSetUris.any((t) => t.requestBody.toLowerCase().contains('.m3u8'));
  String profileId;
  if (caps.contains(kCapStrictTitle)) {
    profileId = kProfileStrictTitle;
  } else if (sinkHasHls && rejectedHlsUrl) {
    profileId = kProfileHlsByUrl;
  } else if (sinkRequiresPn(sinks.toSet())) {
    profileId = kProfilePnRequired;
  } else {
    profileId = kProfileGeneric;
  }

  return CastDeviceProfile(
    udn: d.udn,
    friendlyName: d.friendlyName,
    manufacturer: d.manufacturer,
    modelName: d.modelName,
    serviceType: d.serviceType,
    avTransportVersion: avTransportVersionOf(d.serviceType),
    sinkProtocols: sinks,
    capabilities: caps,
    profileId: profileId,
  );
}

/// `urn:schemas-upnp-org:service:AVTransport:2` → 2；非标形状/缺失 → 1。
int avTransportVersionOf(String serviceType) {
  final m = RegExp(r'AVTransport:(\d+)').firstMatch(serviceType);
  if (m == null) return 1;
  return int.tryParse(m.group(1)!) ?? 1;
}

/// Sink 是否显示「按 PN 匹配」（design §3.2 pnRequired：可解析条目**全部**
/// 带 `DLNA.ORG_PN`）。空 Sink / 无可解析条目返回 false。
bool sinkRequiresPn(Set<String> sink) {
  if (sink.isEmpty) return false;
  var counted = 0;
  for (final entry in sink) {
    final parts = entry.split(':');
    if (parts.length < 3) continue;
    final mime = parts[2].trim().toLowerCase();
    if (mime.isEmpty || mime == '*/*') continue;
    counted++;
    final fourth = parts.length >= 4 ? parts.sublist(3).join(':') : '';
    if (!fourth.contains('DLNA.ORG_PN')) return false;
  }
  return counted > 0;
}

/// 设备画像内存表 + JSON 编解码（`aquan_cast.json` v4 的 `profiles` 字段）。
///
/// 画像是逐设备观测，只按 `udn:<udn>` 精确记忆（共享结论由配方表的
/// `model:` 层承担）；[onChanged] 是可选写盘回调（`CastStore` 注入）。
class CastProfileStore {
  CastProfileStore({this.onChanged});

  final Future<void> Function()? onChanged;
  final Map<String, CastDeviceProfile> _byKey = <String, CastDeviceProfile>{};

  static String keyOf(String udn) => 'udn:${udn.trim().isEmpty ? '-' : udn.trim()}';

  /// v4 键只认 `udn:` 前缀（旧版本无 profiles 字段，防御脏数据）。
  static bool _isValidKey(String key) => key.startsWith('udn:');

  CastDeviceProfile? lookup(String udn) {
    final u = udn.trim();
    if (u.isEmpty) return null;
    return _byKey[keyOf(u)];
  }

  Future<void> remember(CastDeviceProfile p) async {
    if (p.udn.trim().isEmpty) return;
    _byKey[keyOf(p.udn)] = p;
    await _notify();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final e in _byKey.entries) e.key: e.value.toJson(),
      };

  /// 读盘时整体替换（不触发写盘，避免加载即回写）。
  void replaceAll(Map<String, dynamic> json) {
    _byKey.clear();
    for (final e in json.entries) {
      if (!_isValidKey(e.key)) continue;
      final v = e.value;
      if (v is! Map) continue;
      final p = CastDeviceProfile.fromJson(Map<String, dynamic>.from(v));
      if (p.udn.isEmpty) continue;
      _byKey[e.key] = p;
    }
  }

  /// 备份导入：只补当前没有的键，不覆盖本机观测到的画像。
  void absorb(Map<String, dynamic> json) {
    for (final e in json.entries) {
      if (!_isValidKey(e.key)) continue;
      if (_byKey.containsKey(e.key)) continue;
      final v = e.value;
      if (v is! Map) continue;
      final p = CastDeviceProfile.fromJson(Map<String, dynamic>.from(v));
      if (p.udn.isEmpty) continue;
      _byKey[e.key] = p;
    }
  }

  void clear() => _byKey.clear();

  Future<void> _notify() async {
    final cb = onChanged;
    if (cb != null) await cb();
  }
}
