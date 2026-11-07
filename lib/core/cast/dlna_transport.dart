import 'dart:async';
import 'dart:io' show SocketException;

import 'cast_controller.dart';
import 'cast_diagnostics.dart';
import 'cast_recipe.dart';
import 'didl.dart';
import 'dlna_device.dart';
import 'soap_client.dart';

/// DLNA SOAP 传输实现（AVTransport 控制 + RenderingControl 音量）。
///
/// 自 cast_controller.dart 迁出（P0 多协议改造），行为契约不变；
/// 额外实现 [CastCompatTransport] 的预检 / 分类重试 / Play 门控能力。
/// v2（M2）：AVTransport 用设备宣告的真实 serviceType（多版本取最高）、
/// DIDL 走配方模板旋钮、Play 门控支持配方化双确认。
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
  ///
  /// 最坏耗时公式（playbridge dlna_tests.rs:399 先例——公式写成常量并在
  /// 测试中断言，新增变体/调大延迟前先重估，防止无声突破预算）：
  /// - 确定性失败变体最坏耗时 ≤ soapTimeout（4s；fault 恰 1 次请求，AC-26）
  ///   + maxPlayDelayMs（500ms）；
  /// - Play 门控受 [retryBudget] 钳制（`_earlier`），不独立突破预算。
  /// - 12s 不承诺跑完全部梯度变体（deadline 逐变体截断，有界不悬挂），
  ///   但保证 ≥ 2 个满配变体完整尝试 + ≥ 2s 门控窗口。
  final Duration retryBudget;

  /// 配方 `playDelayMs` 的合法上限（合法值 0/300/500；公式断言引用）。
  static const int maxPlayDelayMs = 500;

  static const _rcs = 'urn:schemas-upnp-org:service:RenderingControl:1';
  static const _cm = 'urn:schemas-upnp-org:service:ConnectionManager:1';

  /// AVTransport 真实 serviceType：设备描述里宣告的原始 URN（含版本，
  /// 多版本时解析层已取最高）；缺省回落 `AVTransport:1`。
  ///
  /// SOAP 信封 `xmlns:u` 与 SOAPACTION 头都必须精确等于它——严格接收端
  /// 校验两者 == 设备宣告值（puppy-store-cast HttpServer 实证）。
  String get _avtServiceType {
    final st = device.serviceType.trim();
    return st.isEmpty ? kDefaultAvtServiceType : st;
  }

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
      await _send(device.controlUrl, _avtServiceType, 'SetAVTransportURI', args);
    } on SoapException catch (e) {
      // 设备拒绝 metadata（DIDL 校验严格的盒子会报 SOAP fault）：去掉
      // metadata 重试——但只对「设备返回 fault」且通过三重门控的请求
      // （playbridge session.rs:98-104）。超时不重试（SoapClient 已有一层
      // 收窄后的瞬态重试，再叠会把 4s 超时拖成 12s）。
      if (e.faultCode == null) rethrow;
      if (!_allowsEmptyMetadataRetry(url)) rethrow;
      await _send(device.controlUrl, _avtServiceType, 'SetAVTransportURI', {
        'InstanceID': '0',
        'CurrentURI': url.toString(),
        'CurrentURIMetaData': '',
      });
    }
  }

  /// 空 metadata 重试的三重门控：`generated && !live && !hls && !mirror`。
  ///
  /// 本方法的 metadata 恒为自生成（generated 恒真，没有显式 metadata 入参）；
  /// live 与 mirror 从 URL 特征推导——HLS 扩展名、镜像服务的固定
  /// `/stream.ts` 路径。空 metadata 对 DroidDLNA（崩）与 puppy-store-cast
  /// （402）是致命动作，宁可不重试也不能对这类流发空 metadata。
  bool _allowsEmptyMetadataRetry(Uri url) {
    final path = url.path.toLowerCase();
    final isHls = path.endsWith('.m3u8') || path.endsWith('.m3u');
    final isMirrorStream = path.endsWith('/stream.ts');
    return !isHls && !isMirrorStream;
  }

  @override
  Future<void> play() => _send(device.controlUrl, _avtServiceType, 'Play', {
        'InstanceID': '0',
        'Speed': '1',
      });

  @override
  Future<void> pause() => _send(device.controlUrl, _avtServiceType, 'Pause', {
        'InstanceID': '0',
      });

  @override
  Future<void> stop() => _send(device.controlUrl, _avtServiceType, 'Stop', {
        'InstanceID': '0',
      });

  @override
  Future<void> seekTo(Duration position) =>
      _send(device.controlUrl, _avtServiceType, 'Seek', {
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
      safe(_send(device.controlUrl, _avtServiceType, 'GetTransportInfo', {
        'InstanceID': '0',
      })),
      safe(_send(device.controlUrl, _avtServiceType, 'GetPositionInfo', {
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
    final out = await _send(device.controlUrl, _avtServiceType, 'GetTransportInfo', {
      'InstanceID': '0',
    });
    return out['CurrentTransportState'] ?? '';
  }

  /// 按配方链加载：预检 → SetAVTransportURI → 延迟 → Play（状态门控）→
  /// Seek（容错）。
  ///
  /// 返回实际成功的配方（供控制器记忆）。有界性纪律：
  /// - 超时 / SocketException 一律不重试、不换变体（守 cast-contract.md
  ///   「4s 超时不放大成 12s」）；
  /// - 701/705 只做一次 Stop → 延迟 → 重设 URI → 延迟 → 重 Play；
  /// - 714/716/501 / 无 fault 的明确 HTTP 错误 → 进入下一变体；
  /// - `withPn` 模板仅当 Sink 显示按 PN 匹配才尝试；
  /// - 全局 [retryBudget] 截断整条链（含 Play 门控的 10s 上限）。
  @override
  Future<CastRecipe?> load(CastLoadRequest request) async {
    final deadline = DateTime.now().add(retryBudget);
    final chain = List<CastRecipe>.of(
      request.recipes.isEmpty ? CastRecipeStore.gradient : request.recipes,
    );

    // 预检（M1-5 / AC-13）：Sink 只做大类校验，**不再用它覆盖 mime**。
    // go2tv 明确注释禁止（设备 Sink 常缺条目、或拼写更差，覆盖只会把
    // 本来判对的容器改错——旧实现 `_pickProtocolMime` 会把 HLS 盖成
    // video/mp4/video/mpeg 等）。Sink 里连同大类 mime 都没有 → 记
    // warning 不阻断，仍按媒体自身 mime 投送。
    final sink = request.protocolInfo.isNotEmpty
        ? request.protocolInfo
        : await _safeProtocolInfo();
    if (sink.isNotEmpty && !_sinkHasCategory(sink, request.didl.mimeType)) {
      _trace('警告：设备 Sink 未宣告 ${request.didl.mimeType.split('/').first}'
          ' 类 mime（${sink.length} 条），仍按媒体自身 mime 投送');
    }

    // withPn 模板只对「Sink 条目全部带 DLNA.ORG_PN」的设备有意义
    // （design §3.2 pnRequired）；其余设备跳过该变体，省一次必败往返。
    final pnRequired = _sinkRequiresPn(sink);
    if (!pnRequired) {
      chain.removeWhere((r) =>
          r.protocolInfoTemplate == DidlProtocolInfoTemplate.withPn);
    }

    SoapException? lastFailure;
    for (final recipe in chain) {
      if (!DateTime.now().isBefore(deadline)) break;
      _activeRecipe = recipe;
      try {
        await _attempt(request, recipe, deadline);
        _trace('配方命中：didl=${recipe.didl.name}'
            ' template=${recipe.protocolInfoTemplate.name}');
        return recipe;
      } on TimeoutException {
        _trace('配方未命中（超时）：didl=${recipe.didl.name}');
        _activeRecipe = null;
        rethrow;
      } on SocketException {
        _trace('配方未命中（连接失败）：didl=${recipe.didl.name}');
        _activeRecipe = null;
        rethrow;
      } on SoapException catch (e) {
        _trace('配方未命中：didl=${recipe.didl.name} → '
            '${e.faultCode == null ? e.message : 'fault ${e.faultCode}'}');
        _activeRecipe = null;
        if (_isTimeoutLike(e)) rethrow;
        lastFailure = e;
      }
    }
    throw lastFailure ?? SoapException('SetAVTransportURI 失败');
  }

  /// 状态时间线埋点（M0 纯采集；recordTimeline 自身吞异常）。
  void _trace(String message) => CastDiagnostics.instance.recordTimeline(message);

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
      await _delayFor(recipe.playDelayMs, deadline);
      await _playGated(deadline, recipe: recipe, uri: req.url);
    } on SoapException catch (e) {
      if (!_isStateConflict(e) ||
          _isTimeoutLike(e) ||
          !DateTime.now().isBefore(deadline)) {
        rethrow;
      }
      // 701 / 705：状态机未就绪 → Stop → 延迟 300ms → 重设 URI（一次）→
      // 延迟 → 重 Play（design §4.6 降级链补全）。
      _trace('状态冲突（701/705）→ Stop → 重设 URI → 重 Play');
      try {
        await stop();
      } on Exception {
        // 状态冲突时 Stop 也可能 501：不阻断后续重设。
      }
      await _delayFor(retryDelay.inMilliseconds, deadline);
      await _setUriWithRecipe(req, recipe);
      await _delayFor(recipe.playDelayMs, deadline);
      await _playGated(deadline, recipe: recipe, uri: req.url);
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

  /// 有界延迟：超预算就不等（下一步的 deadline 检查会截断链条）。
  Future<void> _delayFor(int ms, DateTime deadline) async {
    if (ms <= 0) return;
    if (!DateTime.now().add(Duration(milliseconds: ms)).isBefore(deadline)) {
      return;
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
  }

  Future<void> _setUriWithRecipe(
    CastLoadRequest req,
    CastRecipe recipe,
  ) async {
    // M1-5（AC-13）：不再用 recipe.protocolMime 覆盖媒体 mime——旧 JSON
    // 里持久化的覆盖值同样失效（「Sink 不覆盖 mime」是不变式）。
    // sinkEntry 模板：原样复用设备 Sink 同容器条目的第 4 段（castor
    // didl.go）；无同容器条目时 buildDidl 内部回落 standard。
    final sinkFourth =
        recipe.protocolInfoTemplate == DidlProtocolInfoTemplate.sinkEntry
            ? sinkEntryFourthSegment(req.protocolInfo, req.didl.mimeType)
            : null;
    await _send(device.controlUrl, _avtServiceType, 'SetAVTransportURI',
        <String, String>{
      'InstanceID': '0',
      'CurrentURI': req.url.toString(),
      'CurrentURIMetaData': buildDidlMetadata(
        req.didl,
        recipe.didl,
        template: recipe.protocolInfoTemplate,
        sinkFourth: sinkFourth,
        subtitleMode: recipe.subtitleMode,
        sendDcDescription: recipe.sendDcDescription,
      ),
    });
  }

  /// Play 后轮询状态，等到 PLAYING/RUNNING 才返回。
  ///
  /// - `requirePlayConfirmation = false`（默认，现状行为 / AC-23）：门控
  ///   超时**仍视为成功**——不误伤 AirPin / 央视频这类状态上报非标准的设备；
  /// - `true`（配方显式打开）：双确认——状态 PLAYING 且 GetPositionInfo 的
  ///   TrackURI 与本次投送的 URI 一致才算命中；门控超时后再用
  ///   GetMediaInfo.CurrentURI 做归属仲裁（castor session.go：URI 不是我们
  ///   的 = 电视还在播旧片，本次投屏未被接受 → 进下一变体）。
  Future<void> _playGated(
    DateTime deadline, {
    required CastRecipe recipe,
    required Uri uri,
  }) async {
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
      if (upper == 'PLAYING' || upper == 'RUNNING') {
        if (!recipe.requirePlayConfirmation) return;
        if (await _reportUriMatches(uri, 'GetPositionInfo', 'TrackURI')) {
          return;
        }
        // PLAYING 但放的不是我们投的 URI：继续轮询到门控超时再仲裁。
      }
      if (!DateTime.now().isBefore(gateDeadline)) {
        if (!recipe.requirePlayConfirmation) return;
        if (await _reportUriMatches(uri, 'GetMediaInfo', 'CurrentURI')) {
          // 是我们的流，只是设备起播慢：归属成立，不算失败。
          return;
        }
        throw SoapException('播放未被设备确认（设备未在播本次投送的 URI）');
      }
    }
  }

  /// 设备上报的 URI 是否与本次投送一致（GetPositionInfo.TrackURI /
  /// GetMediaInfo.CurrentURI）。查询失败按「不一致」处理（严格门控语义）。
  Future<bool> _reportUriMatches(Uri uri, String action, String field) async {
    try {
      final out = await _send(
          device.controlUrl, _avtServiceType, action, <String, String>{
        'InstanceID': '0',
      });
      final remote = (out[field] ?? '').trim();
      return remote.isNotEmpty && remote == uri.toString();
    } on Exception {
      return false;
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

/// Sink 条目里是否存在同大类（video/audio/image）mime（M1-5 大类校验）。
bool _sinkHasCategory(Set<String> sink, String wanted) {
  final category = wanted.split('/').first.toLowerCase();
  for (final entry in sink) {
    final parts = entry.split(':');
    if (parts.length < 3) continue;
    final mime = parts[2].trim().toLowerCase();
    if (mime.isEmpty || mime == '*/*') continue;
    if (mime.startsWith('$category/')) return true;
  }
  return false;
}

/// Sink 是否显示「按 PN 匹配」（design §3.2 pnRequired：条目全部带
/// DLNA.ORG_PN）。空 Sink / 无可解析条目返回 false。
bool _sinkRequiresPn(Set<String> sink) {
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
