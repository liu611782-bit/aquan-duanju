import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import 'cast_target.dart';

/// mDNS 设备发现（Chromecast `_googlecast._tcp` + AirPlay `_airplay._tcp`）。
///
/// 移植自 dart_cast（MIT）并适配本仓 CastDeviceInfo / AirPlayDeviceInfo：
/// PTR→SRV→A→TXT 逐级解析，多轮查询兜底慢应答设备；TXT `fn`（友好名）/
/// `id`（设备 id）/`md`（型号）；AirPlay TXT `deviceid`（MAC）/`am`（型号）。
class MdnsDiscovery {
  MdnsDiscovery._();

  static const chromecastServiceType = '_googlecast._tcp.local';

  /// AirPlay 视频接收端服务类型。一期只收 `_airplay._tcp`——`_raop._tcp`
  /// 是纯音频（AirPlay 音频/镜像）设备，不进视频投送列表。
  static const airplayServiceType = '_airplay._tcp.local';

  /// 发现指定服务类型的设备；流在解析完本轮 PTR 后自然结束。
  /// [rounds] 轮询次数、[roundGap] 轮间隔（测试可收紧）。
  static Stream<CastDeviceInfo> discover(
    String serviceType, {
    int rounds = 3,
    Duration roundGap = const Duration(seconds: 2),
    Duration resolveTimeout = const Duration(seconds: 3),
    MDnsClient? clientOverride,
  }) async* {
    await for (final r in _browse(
      serviceType,
      rounds: rounds,
      roundGap: roundGap,
      resolveTimeout: resolveTimeout,
      clientOverride: clientOverride,
    )) {
      yield CastDeviceInfo(
        host: r.host,
        port: r.port,
        name: r.txt['fn'] ?? stripServiceSuffix(r.domainName),
        modelName: r.txt['md'] ?? '',
      );
    }
  }

  /// 发现 AirPlay 接收端（`_airplay._tcp`）。
  ///
  /// 兼容过滤：PTR 应答必须仍带 `_airplay._tcp`（组播流偶发串入其它类型记录时
  /// 跳过，宁缺勿错）；TXT `deviceid` 缺失时设备 id 由 CastTarget 回落 host:port。
  static Stream<AirPlayDeviceInfo> discoverAirplay({
    int rounds = 3,
    Duration roundGap = const Duration(seconds: 2),
    Duration resolveTimeout = const Duration(seconds: 3),
    MDnsClient? clientOverride,
  }) async* {
    await for (final r in _browse(
      airplayServiceType,
      rounds: rounds,
      roundGap: roundGap,
      resolveTimeout: resolveTimeout,
      clientOverride: clientOverride,
    )) {
      // 类型过滤容错：只认仍指向 _airplay._tcp 的服务实例。
      if (!r.domainName.contains('._airplay._tcp')) continue;
      yield AirPlayDeviceInfo(
        host: r.host,
        port: r.port,
        name: stripServiceSuffix(r.domainName),
        deviceId: r.txt['deviceid'] ?? '',
        modelName: r.txt['am'] ?? r.txt['model'] ?? '',
      );
    }
  }

  /// PTR→SRV→A→TXT 逐级解析（Chromecast / AirPlay 共用；口径同移植蓝本）。
  static Stream<_ResolvedService> _browse(
    String serviceType, {
    required int rounds,
    required Duration roundGap,
    required Duration resolveTimeout,
    required MDnsClient? clientOverride,
  }) async* {
    final client = clientOverride ?? MDnsClient();
    var owned = clientOverride == null;
    try {
      if (owned) await client.start();
    } catch (_) {
      // mDNS 起不来（权限/网络）不影响其他发现路径。
      return;
    }
    try {
      final seen = <String>{};
      for (var round = 0; round < rounds; round++) {
        if (round > 0) await Future<void>.delayed(roundGap);
        await for (final ptr in client
            .lookup<PtrResourceRecord>(
              ResourceRecordQuery.serverPointer(serviceType),
            )
            .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
          if (seen.contains(ptr.domainName)) continue;
          seen.add(ptr.domainName);
          try {
            await for (final srv in client
                .lookup<SrvResourceRecord>(
                  ResourceRecordQuery.service(ptr.domainName),
                )
                .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
              try {
                await for (final ip in client
                    .lookup<IPAddressResourceRecord>(
                      ResourceRecordQuery.addressIPv4(srv.target),
                    )
                    .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
                  final txt = <String, String>{};
                  try {
                    await for (final t in client
                        .lookup<TxtResourceRecord>(
                          ResourceRecordQuery.text(ptr.domainName),
                        )
                        .timeout(resolveTimeout, onTimeout: (sink) => sink.close())) {
                      txt.addAll(parseTxt(t.text));
                    }
                  } catch (_) {
                    // TXT 超时：空记录继续。
                  }
                  yield _ResolvedService(
                    domainName: ptr.domainName,
                    host: ip.address.address,
                    port: srv.port,
                    txt: txt,
                  );
                }
              } catch (_) {
                // A 记录超时：跳过该设备。
              }
            }
          } catch (_) {
            // SRV 超时：跳过该服务。
          }
        }
      }
    } finally {
      if (owned) client.stop();
    }
  }

  /// `客厅电视._googlecast._tcp.local` → `客厅电视`。
  static String stripServiceSuffix(String name) {
    final dot = name.indexOf('._');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// TXT 记录文本 → 键值表（multicast_dns 包把条目以换行连接）。
  static Map<String, String> parseTxt(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      final eq = trimmed.indexOf('=');
      if (eq > 0) {
        out[trimmed.substring(0, eq)] = trimmed.substring(eq + 1);
      }
    }
    return out;
  }
}

/// 一条解析完成的 mDNS 服务实例（协议映射前）。
class _ResolvedService {
  const _ResolvedService({
    required this.domainName,
    required this.host,
    required this.port,
    required this.txt,
  });

  final String domainName;
  final String host;
  final int port;
  final Map<String, String> txt;
}
