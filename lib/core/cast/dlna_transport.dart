import 'dart:async';
import 'dart:io' show SocketException;

import 'cast_controller.dart';
import 'cast_recipe.dart';
import 'didl.dart';
import 'dlna_device.dart';
import 'soap_client.dart';

/// DLNA SOAP 传输实现（AVTransport 控制 + RenderingControl 音量）。
///
/// 自 cast_controller.dart 迁出（P0 多协议改造），行为契约不变；
/// 额外实现 [CastCompatTransport] 的预检 / 分类重试 / Play 门控能力。
class DlnaTransport implements CastTransport, CastCompatTransport {
  DlnaTransport(
    this.device, {
    SoapClient? client,
    this.playPollInterval = const Duration(milliseconds: 500),
    this.playGateTimeout = const Duration(seconds: 10),
    this.retryDelay = const Duration(milliseconds: 300),
    this.retryBudget = const Duration(seconds: 12),
  }) : _client = client ?? SoapClient();

  final DlnaDevice device;
  final SoapClient _client;

  /// Play 后轮询 GetTransportInfo 的间隔（默认 500ms；测试可注入更小值）。
  final Duration playPollInterval;

  /// Play 门控最长等待（默认 10s，且始终受 [retryBudget] 截断）。
  final Duration playGateTimeout;

  /// 701/705 后 Stop → 重设 URI → 重 Play 之间的延迟（默认 300ms）。
  final Duration retryDelay;

  /// 整条分类重试链的总预算（默认 12s）。
  final Duration retryBudget;

  static const _avt = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const _rcs = 'urn:schemas-upnp-org:service:RenderingControl:1';
  static const _cm = 'urn:schemas-upnp-org:service:ConnectionManager:1';

  /// 当前生效配方（load 成功后保留到 close，让 poll/音量也走同一套头形态）。
  CastRecipe? _activeRecipe;

  Future<Map<String, String>> _send(
    String url,
    String service,
    String action,
    Map<String, String> args,
  ) {
    final r = _activeRecipe;
    return _client.sendAction(
      url,
      service,
      action,
      args,
      quotedSoapAction: r?.quotedSoapAction ?? true,
      uppercaseSoapAction: r?.quotedSoapAction ?? true,
      mPost: r?.mPost ?? false,
    );
  }

  // ---------- 既有 CastTransport 接口（语义不变） ----------

  @override
  Future<void> setUri(
    Uri url, {
    required String title,
    String? duration,
    Uri? subtitleUrl,
  }) async {
    final metadata =
        buildDidlLite(title: title, duration: duration, subtitleUrl: subtitleUrl);
    final args = <String, String>{
      'InstanceID': '0',
      'CurrentURI': url.toString(),
      'CurrentURIMetaData': metadata,
    };
    try {
      await _send(device.controlUrl, _avt, 'SetAVTransportURI', args);
    } on SoapException catch (e) {
      // 设备拒绝 metadata（DIDL 校验严格的盒子会报 SOAP fault）：去掉 metadata 重试。
      // 只对「设备返回 fault」重试——超时不重试（SoapClient 已有一层 504 重试，
      // 再叠会把 4s 超时拖成 12s）。
      if (e.faultCode == null) rethrow;
      await _send(device.controlUrl, _avt, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url.toString(),
        'CurrentURIMetaData': '',
      });
    }
  }

  @override
  Future<void> play() => _send(device.controlUrl, _avt, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  @override
  Future<void> pause() => _send(device.controlUrl, _avt, 'Pause', {
        'InstanceID': '0',
      });

  @override
  Future<void> stop() => _send(device.controlUrl, _avt, 'Stop', {
        'InstanceID': '0',
      });

  @override
  Future<void> seekTo(Duration position) =>
      _send(device.controlUrl, _avt, 'Seek', {
        'InstanceID': '0',
        'Unit': 'REL_TIME',
        'Target': formatUpnpTime(position),
      });

  @override
  Future<void> setVolume(int percent) async {
    if (device.renderingControlUrl.isEmpty) {
      throw SoapException('设备不支持音量控制');
    }
    await _send(device.renderingControlUrl, _rcs, 'SetVolume', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredVolume': '$percent',
    });
  }

  @override
  Future<void> setMute(bool muted) async {
    if (device.renderingControlUrl.isEmpty) {
      throw SoapException('设备不支持静音控制');
    }
    await _send(device.renderingControlUrl, _rcs, 'SetMute', {
      'InstanceID': '0',
      'Channel': 'Master',
      'DesiredMute': muted ? '1' : '0',
    });
  }

  /// 并发取状态与进度：任一路失败不拖累另一路。
  @override
  Future<CastPoll> poll() async {
    Future<Map<String, String>?> safe(Future<Map<String, String>> call) async {
      try {
        return await call;
      } on SoapException {
        return null;
      }
    }

    final both = await Future.wait<Map<String, String>?>([
      safe(_send(device.controlUrl, _avt, 'GetTransportInfo', {
        'InstanceID': '0',
      })),
      safe(_send(device.controlUrl, _avt, 'GetPositionInfo', {
        'InstanceID': '0',
      })),
    ]);
    final info = both[0];
    if (info == null) {
      throw SoapException('GetTransportInfo 失败');
    }
    final pos = both[1];
    return CastPoll(
      transportState: info['CurrentTransportState'] ?? '',
      position: parseUpnpTime(pos?['RelTime'] ?? '') ?? Duration.zero,
      duration: parseUpnpTime(pos?['TrackDuration'] ?? '') ?? Duration.zero,
    );
  }

  @override
  void close() {
    _activeRecipe = null;
    _client.close();
  }

  // ---------- 兼容层：预检 / 分类重试 / Play 门控 ----------

  @override
  Future<Set<String>> preflight() => getProtocolInfo();

  /// ConnectionManager.GetProtocolInfo 的 Sink 条目；无 URL / 失败返回空集。
  Future<Set<String>> getProtocolInfo() async {
    final url = device.connectionManagerUrl;
    if (url.isEmpty) return <String>{};
    try {
      final out = await _send(url, _cm, 'GetProtocolInfo', <String, String>{});
      return _splitProtocolInfo(out['Sink'] ?? '');
    } on Exception {
      return <String>{};
    }
  }

  /// GetTransportInfo 的 CurrentTransportState（失败由调用方决定如何处置）。
  Future<String> getTransportState() async {
    final out = await _send(device.controlUrl, _avt, 'GetTransportInfo', {
      'InstanceID': '0',
    });
    return out['CurrentTransportState'] ?? '';
  }

  /// 按配方链加载：预检 → SetAVTransportURI → Play（状态门控）→ Seek（容错）。
  ///
  /// 返回实际成功的配方（供控制器记忆）。有界性纪律：
  /// - 超时 / SocketException 一律不重试、不换变体（守 cast-contract.md
  ///   「4s 超时不放大成 12s」）；
  /// - 701/705 只做一次 Stop → 重设 URI → 延迟 → 重 Play；
  /// - 714/716/501 / 无 fault 的明确 HTTP 错误 → 进入下一 DIDL 变体；
  /// - 全局 [retryBudget] 截断整条链（含 Play 门控的 10s 上限）。
  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    final deadline = DateTime.now().add(retryBudget);
    var chain = List<CastRecipe>.of(
      request.recipes.isEmpty ? CastRecipeStore.gradient : request.recipes,
    );

    // 预检：设备 Sink 里没有已知视频类型时不阻断，只把首配方降到 minimal
    //（严格设备仍可能接受通配 protocolInfo）。
    final sink = request.protocolInfo.isNotEmpty
        ? request.protocolInfo
        : await _safeProtocolInfo();
    final mime = _pickProtocolMime(sink, request.didl.mimeType);
    if (mime == null &&
        sink.isNotEmpty &&
        request.didl.mimeType.startsWith('video/') &&
        chain.isNotEmpty) {
      chain = <CastRecipe>[
        chain.first.copyWith(didl: DidlVariant.minimal),
        ...chain.skip(1),
      ];
    }

    SoapException? lastFailure;
    for (final base in chain) {
      if (!DateTime.now().isBefore(deadline)) break;
      final recipe =
          base.copyWith(protocolMime: mime ?? base.protocolMime);
      _activeRecipe = recipe;
      try {
        await _attempt(request, recipe, deadline);
        return recipe;
      } on TimeoutException {
        _activeRecipe = null;
        rethrow;
      } on SocketException {
        _activeRecipe = null;
        rethrow;
      } on SoapException catch (e) {
        _activeRecipe = null;
        if (_isTimeoutLike(e)) rethrow;
        lastFailure = e;
      }
    }
    throw lastFailure ?? SoapException('SetAVTransportURI 失败');
  }

  Future<void> _attempt(
    CastLoadRequest req,
    CastRecipe recipe,
    DateTime deadline,
  ) async {
    if (recipe.stopBeforeSet) {
      try {
        await stop();
      } on Exception {
        // Stop 失败不阻断（设备可能处于 NO_MEDIA_PRESENT）。
      }
    }
    try {
      await _setUriWithRecipe(req, recipe);
      await _playGated(deadline);
    } on SoapException catch (e) {
      if (!_isStateConflict(e) ||
          _isTimeoutLike(e) ||
          !DateTime.now().isBefore(deadline)) {
        rethrow;
      }
      // 701 / 705：状态机未就绪 → Stop → 重设 URI（一次）→ 延迟 300ms → 重 Play。
      try {
        await stop();
      } on Exception {
        // 状态冲突时 Stop 也可能 501：不阻断后续重设。
      }
      await _setUriWithRecipe(req, recipe);
      if (retryDelay > Duration.zero) {
        await Future<void>.delayed(retryDelay);
      }
      await _playGated(deadline);
    }
    // Seek 失败吞掉：Load 已经成功，不能因设备不支持 Seek 让整次投屏失败。
    if (req.position > const Duration(seconds: 3)) {
      try {
        await seekTo(req.position);
      } on Exception {
        // 从头播。
      }
    }
  }

  Future<void> _setUriWithRecipe(
    CastLoadRequest req,
    CastRecipe recipe,
  ) async {
    final didlReq = req.didl.copyWith(
      mimeType: recipe.protocolMime.isNotEmpty
          ? recipe.protocolMime
          : req.didl.mimeType,
    );
    await _send(device.controlUrl, _avt, 'SetAVTransportURI', <String, String>{
      'InstanceID': '0',
      'CurrentURI': req.url.toString(),
      'CurrentURIMetaData': buildDidlMetadata(didlReq, recipe.didl),
    });
  }

  /// Play 后 500ms 轮询状态，等到 PLAYING/RUNNING 才返回；超时不使 Load 失败。
  Future<void> _playGated(DateTime deadline) async {
    await play();
    final gateDeadline = _earlier(
      DateTime.now().add(playGateTimeout),
      deadline,
    );
    while (true) {
      if (playPollInterval > Duration.zero) {
        await Future<void>.delayed(playPollInterval);
      }
      String state;
      try {
        state = await getTransportState()
            .timeout(const Duration(seconds: 2), onTimeout: () => '');
      } on Exception {
        state = '';
      }
      final upper = state.trim().toUpperCase();
      if (upper == 'PLAYING' || upper == 'RUNNING') return;
      if (!DateTime.now().isBefore(gateDeadline)) return;
    }
  }

  Future<Set<String>> _safeProtocolInfo() async {
    try {
      return await getProtocolInfo().timeout(const Duration(seconds: 2));
    } on Exception {
      return <String>{};
    }
  }
}

Set<String> _splitProtocolInfo(String raw) => raw
    .split(',')
    .map((e) => e.trim())
    .where((e) => e.isNotEmpty)
    .toSet();

/// 从 Sink 里挑一个与请求同大类（video/audio/image）的 protocolInfo mime 段。
String? _pickProtocolMime(Set<String> sink, String wanted) {
  if (sink.isEmpty) return null;
  final category = wanted.split('/').first.toLowerCase();
  for (final entry in sink) {
    final parts = entry.split(':');
    if (parts.length < 3) continue;
    final mime = parts[2].trim();
    if (mime.isEmpty || mime == '*/*') continue;
    if (mime.toLowerCase().startsWith('$category/')) return mime;
  }
  return null;
}

DateTime _earlier(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

/// 从 faultCode / faultDescription / message 里取 UPnP 数字错误码。
int? _errorCode(SoapException e) {
  final text = '${e.faultCode ?? ''} ${e.faultDescription ?? ''} ${e.message}';
  final m = RegExp(r'\b(401|501|701|705|714|715|716|717|718)\b')
      .firstMatch(text);
  return m == null ? null : int.tryParse(m.group(1)!);
}

bool _isStateConflict(SoapException e) {
  final code = _errorCode(e);
  return code == 701 || code == 705;
}

/// SoapClient 把 TimeoutException / SocketException 包装成「无 faultCode 的
/// SoapException」；这类异常绝不能进重试链（4s 超时不放大成 12s）。
bool _isTimeoutLike(SoapException e) =>
    e.faultCode == null &&
    (e.message.contains('超时') || e.message.contains('请求失败'));
