import 'dart:async';

import 'package:flutter/foundation.dart';

import '../error_log.dart';
import 'cast_diagnostics.dart';
import 'cast_media_proxy.dart';
import 'cast_recipe.dart';
import 'cast_target.dart';
import 'didl.dart';
import 'gena_subscriber.dart';
import 'mirror/mirror_controller.dart';
import 'chromecast/chromecast_transport.dart';
import 'dlna_transport.dart';
import 'local_media_server.dart';
import 'mdns_discovery.dart';
import 'ssdp_discovery.dart';

/// 投屏会话状态。
enum CastSessionState { idle, discovering, connecting, casting, stopping }

/// 要投出去的媒体（URL 必须是电视可达的局域网/公网直链，绝不能是 127.0.0.1）。
class CastMedia {
  const CastMedia({
    required this.url,
    required this.title,
    this.coverUrl = '',
    this.position = Duration.zero,
    this.episodeIndex = 1,
    this.episodeCount = 0,
    this.localPath = '',
    this.headers = const {},
    this.subtitleUrl = '',
    this.isMirror = false,
  });

  final String url;
  final String title;
  final String coverUrl;
  final Duration position;
  final int episodeIndex;
  final int episodeCount;

  /// 本机文件路径。非空时由 [LocalMediaServer] 生成局域网 URL，[url] 被忽略。
  final String localPath;

  /// 源站请求头（Referer/UA 等）。非空且为 http(s) 直链时经 [CastMediaProxy]
  /// 包一层再投给电视（电视无法自带这些头）。本地文件路径下被忽略。
  final Map<String, String> headers;

  /// 外挂字幕地址（srt/vtt）。DLNA 走 DIDL `sec:SubtitleUri`；
  /// Chromecast 先转 VTT 再作为 textTrack 投送。空表示无字幕。
  final String subtitleUrl;

  /// 屏幕镜像流（MirrorService 的 /stream.ts）。会话结束（断开/电视端停止）
  /// 时控制器自动停掉镜像服务。
  final bool isMirror;

  bool get isLocalFile => localPath.isNotEmpty;
}

/// 一次轮询到的远端状态。
class CastPoll {
  const CastPoll({
    required this.transportState,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });
  final String transportState; // PLAYING / RUNNING / PAUSED_PLAYBACK / STOPPED / NO_MEDIA_PRESENT…
  final Duration position;
  final Duration duration;

  /// 各厂商状态词不一致：标准 UPnP 是 `PLAYING`，部分设备回 `RUNNING`。
  /// 只认 RUNNING 会让正常播放被当成「未运行」，远程进度插值随之停摆。
  bool get isRunning {
    final state = transportState.trim().toUpperCase();
    return state == 'PLAYING' || state == 'RUNNING';
  }
  bool get isPaused => transportState == 'PAUSED_PLAYBACK';
  bool get isStopped => transportState == 'STOPPED' || transportState == 'NO_MEDIA_PRESENT';
}

/// DLNA 兼容加载所需的全部输入。
///
/// 它是「可选能力」[CastCompatTransport] 的入参：不感知配方的 transport
/// （Chromecast / 测试假件）根本不会收到它，控制器仍走标准三件套。
class CastLoadRequest {
  const CastLoadRequest({
    required this.url,
    required this.didl,
    this.recipes = const <CastRecipe>[],
    this.title = '',
    this.duration,
    this.subtitleUrl,
    this.position = Duration.zero,
    this.protocolInfo = const <String>{},
  });

  final Uri url;
  final DidlRequest didl;
  final List<CastRecipe> recipes;
  final String title;
  final String? duration;
  final Uri? subtitleUrl;
  final Duration position;

  /// GetProtocolInfo 预检拿到的 Sink 条目（控制器预检后回填）。
  final Set<String> protocolInfo;
}

/// 可选能力接口：DLNA 兼容层专用。
///
/// 刻意不往 [CastTransport] 加方法——`implements` 会要求所有既有实现
/// （Chromecast / 各测试假件）补实现；用 `is` 探测才能真正做到向后兼容。
abstract class CastCompatTransport {
  Future<Set<String>> preflight();

  /// 返回实际成功的配方（供控制器记忆）。
  Future<CastRecipe?> load(CastLoadRequest request);
}

/// 传输抽象：DLNA 是 SOAP 实现，Chromecast 是 CASTv2 实现；测试注入假实现驱动状态机。
abstract class CastTransport {
  Future<void> setUri(
    Uri url, {
    required String title,
    String? duration,
    Uri? subtitleUrl,
  });
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seekTo(Duration position);
  Future<void> setVolume(int percent);
  Future<void> setMute(bool muted);
  Future<CastPoll> poll();

  /// 释放底层连接（SOAP 客户端/CASTv2 socket）。会话结束时控制器调用。
  void close() {}
}

/// 默认 transport 工厂：按目标协议分派。
CastTransport defaultTransportFactory(CastTarget target) {
  switch (target.protocol) {
    case CastProtocol.dlna:
      return DlnaTransport(target.dlna!);
    case CastProtocol.chromecast:
      return ChromecastTransport(target.cast!);
  }
}

/// 由 URL 扩展名猜 DIDL `protocolInfo` 的 mime 段；无法判定时按视频处理
/// （预检会从设备 Sink 覆盖成设备真正声明的 mime）。
String _mimeForCast(String url) {
  final path = (Uri.tryParse(url)?.path ?? '').toLowerCase();
  bool has(String ext) => path.endsWith(ext);
  if (has('.m3u8') || has('.ts')) return 'video/mp2t';
  if (has('.mp3')) return 'audio/mpeg';
  if (has('.m4a') || has('.aac')) return 'audio/mp4';
  if (has('.flac')) return 'audio/flac';
  if (has('.wav')) return 'audio/wav';
  if (has('.jpg') || has('.jpeg')) return 'image/jpeg';
  if (has('.png')) return 'image/png';
  if (has('.webp')) return 'image/webp';
  if (has('.mkv')) return 'video/x-matroska';
  if (has('.webm')) return 'video/webm';
  if (has('.avi')) return 'video/x-msvideo';
  return 'video/mp4';
}

/// 投屏会话控制器：状态机 + 1s 轮询 + 远端主动停止感知 + 多协议路由。
///
/// 本地联动（暂停本地播放器/断开回本地续播）由 UI 层订阅完成——控制器只管远端。
class CastController extends ChangeNotifier {
  CastController({
    CastTransport Function(CastTarget)? transportFactory,
    this.mdnsDiscover,
    this.proxyResolver,
    CastRecipeStore? recipeStore,
  })  : _transportFactory = transportFactory ?? defaultTransportFactory,
        recipes = recipeStore ?? CastRecipeStore();

  final CastTransport Function(CastTarget) _transportFactory;

  /// 设备型号 → 成功配方。默认是一张不落盘的内存表；集成时把
  /// `CastStore.recipes`（v3 持久化）注入这里即可跨启动记住配方。
  CastRecipeStore recipes;

  /// mDNS 发现挂点（Chromecast）注入点；null = 用默认 [MdnsDiscovery]。
  final Stream<CastDeviceInfo> Function()? mdnsDiscover;

  /// 受保护流代理挂点。非 null 时带源站头的直链经它包一层；返回 null 表示不代理。
  /// null 时用控制器自带的 [CastMediaProxy]。
  final Future<String?> Function(String url, Map<String, String> headers)?
      proxyResolver;

  CastSessionState _state = CastSessionState.idle;
  final List<CastTarget> _devices = [];
  CastTarget? _currentDevice;
  CastMedia? _currentMedia;
  CastTransport? _transport;
  Timer? _pollTimer;
  bool _userStopping = false;

  /// 电视端主动停止（用户在遥控器上按了停止）时回调，携带最后已知进度。
  void Function(CastTarget device, Duration lastPosition)? onRemoteStopped;

  /// 连续多次轮询失败（电视休眠/换网）时回调，UI 据此提示「连接已断开」。
  void Function(CastTarget device)? onSessionLost;

  /// 连播队列：电视端播完当前集后取下一集；返回 null 表示没有更多。
  /// 由 UI 在发起投屏时注入（捕获当时的集数上下文），会话结束自动清空。
  Future<CastMedia?> Function()? onNextEpisode;

  bool _autoAdvancing = false;

  CastSessionState get state => _state;
  List<CastTarget> get devices => List.unmodifiable(_devices);
  CastTarget? get currentDevice => _currentDevice;
  CastMedia? get currentMedia => _currentMedia;
  Duration get remoteDuration => _lastDuration;
  bool get isCasting => _state == CastSessionState.casting;

  /// 远端进度：两次轮询之间按本地时钟插值，进度条不再「一秒一跳」。
  ///
  /// 上限 5s：轮询卡住时不至于把进度条推到离谱的位置。
  Duration get remotePosition {
    if (_state != CastSessionState.casting || !_lastRunning) {
      return _lastPosition;
    }
    final at = _polledAt;
    if (at == null) return _lastPosition;
    var extra = DateTime.now().difference(at);
    if (extra > const Duration(seconds: 5)) {
      extra = const Duration(seconds: 5);
    }
    if (extra.isNegative) extra = Duration.zero;
    return _lastPosition + extra;
  }

  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  DateTime? _polledAt;
  bool _lastRunning = false;
  int _pollFailures = 0;
  SsdpDiscovery? _discovery;
  StreamSubscription<SsdpEvent>? _discoverySub;
  StreamSubscription<CastDeviceInfo>? _mdnsSub;
  GenaSubscriber? _gena;
  StreamSubscription<CastPoll>? _genaSub;
  DateTime? _lastGenaAt;
  int _pollTick = 0;

  /// 诊断时间线去重：只记录电视状态变化（M0 纯采集）。
  String _lastTimelineState = '';

  // ---------- 扫描 ----------

  void startScan() {
    if (_state == CastSessionState.discovering) return;
    _devices.clear();
    _state = CastSessionState.discovering;
    notifyListeners();
    final discovery = _discovery = SsdpDiscovery();
    _discoverySub?.cancel();
    // P0 崩溃护栏：组播绑定失败等异常只写 ErrorLog，不中断扫描。
    // cancelOnError: false 保证单次错误不会把发现流整个关掉。
    _discoverySub = discovery.start().listen((event) {
      switch (event) {
        case SsdpDeviceFound(:final device):
          _upsertDevice(CastTarget.dlna(device));
        case SsdpDeviceOffline(:final udn):
          final i = _devices.indexWhere((d) => d.id == udn);
          if (i >= 0) {
            _devices[i].online = false;
            if (_devices[i].dlna != null) _devices[i].dlna!.online = false;
            notifyListeners();
          }
        case SsdpScanDone():
          break;
      }
    }, onError: (Object error, StackTrace stack) {
      ErrorLog.instance.record('投屏扫描', error, stack);
    }, cancelOnError: false);
    _startMdnsScan();
  }

  /// Chromecast mDNS 扫描：多轮查询由 [MdnsDiscovery] 内部完成，这里只收流。
  void _startMdnsScan() {
    final discover = mdnsDiscover ?? _defaultMdnsDiscover;
    _mdnsSub?.cancel();
    _mdnsSub = discover().listen((info) {
      _upsertDevice(CastTarget.chromecast(info));
    }, onError: (_) {
      // mDNS 失败不影响 DLNA 扫描（老机型/权限缺失场景）。
    });
  }

  static Stream<CastDeviceInfo> _defaultMdnsDiscover() =>
      MdnsDiscovery.discover(MdnsDiscovery.chromecastServiceType);

  void _upsertDevice(CastTarget target) {
    final i = _devices.indexWhere((d) => d.id == target.id);
    if (i >= 0) {
      _devices[i] = target;
    } else {
      _devices.add(target);
    }
    notifyListeners();
  }

  void stopScan() {
    if (_state == CastSessionState.discovering) {
      _state = CastSessionState.idle;
    }
    _discoverySub?.cancel();
    _discoverySub = null;
    _mdnsSub?.cancel();
    _mdnsSub = null;
    unawaited(_discovery?.stop());
    _discovery = null;
    notifyListeners();
  }

  /// 手动按 IP 添加 DLNA 设备（AP 隔离/组播被滤时的兜底）。
  Future<CastTarget?> addByIp(String host, {int port = 49152}) async {
    final discovery = _discovery ??= SsdpDiscovery();
    _discoverySub ??= discovery.start().listen((event) {
      if (event is SsdpDeviceFound) _upsertDevice(CastTarget.dlna(event.device));
    }, onError: (Object error, StackTrace stack) {
      ErrorLog.instance.record('投屏扫描', error, stack);
    }, cancelOnError: false);
    final device = await discovery.addByIp(host, port: port);
    return device == null ? null : CastTarget.dlna(device);
  }

  // ---------- 会话 ----------

  /// 本地文件投屏用的 HTTP 服务（只有投本地文件时才启动）。
  final LocalMediaServer _mediaServer = LocalMediaServer();

  /// 受保护流/字幕代理（默认实现；proxyResolver 注入可整体替换）。
  final CastMediaProxy _castProxy = CastMediaProxy();

  Future<String?> _defaultProxyResolve(String url, Map<String, String> headers) =>
      _castProxy.register(url, headers: headers);

  /// 字幕投送前的准备：带源站头的字幕必须经代理；Chromecast 的 SRT 转 VTT。
  Future<Uri?> _prepareSubtitle(CastTarget target, CastMedia media) async {
    final raw = media.subtitleUrl;
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final needsProxy = media.headers.isNotEmpty ||
        (target.protocol == CastProtocol.chromecast &&
            raw.toLowerCase().endsWith('.srt'));
    if (!needsProxy) return uri;
    final proxied = await _castProxy.registerSubtitle(raw, headers: media.headers);
    return proxied == null ? uri : Uri.tryParse(proxied);
  }

  LocalMediaServer get mediaServer => _mediaServer;

  /// 投到指定目标。同 IP 存在另一协议目标且首选失败时自动降级重试一次
  /// （如 Chromecast 就绪超时 → 同 IP 的 DLNA MediaRenderer）。
  Future<void> castTo(CastTarget target, CastMedia media) async {
    try {
      await _castWith(target, media);
    } on Exception {
      final alt = _devices
          .where((d) =>
              d.host.isNotEmpty &&
              d.host == target.host &&
              d.protocol != target.protocol)
          .toList();
      if (alt.isEmpty) rethrow;
      // 降级目标再失败则直接抛给 UI（不再继续找）。
      await _castWith(alt.first, media);
    }
  }

  Future<void> _castWith(CastTarget target, CastMedia media) async {
    _pollTimer?.cancel();
    _currentDevice = target;
    _userStopping = false;
    _state = CastSessionState.connecting;
    _lastTimelineState = '';
    // 诊断会话（M0）：重置会话级采集，保留发现阶段证据。纯采集，不影响链路。
    CastDiagnostics.instance.beginSession(
      deviceName: target.name,
      protocol: target.protocol.name,
    );
    CastDiagnostics.instance
        .recordTimeline('connecting → ${target.name}（${target.host}）');
    notifyListeners();

    var playUrl = media.url;
    if (media.isLocalFile) {
      final served = await _mediaServer.urlFor(media.localPath);
      if (served == null) {
        _state = CastSessionState.idle;
        _currentDevice = null;
        notifyListeners();
        throw CastException('本地媒体服务启动失败（检查是否在局域网内）');
      }
      playUrl = served;
    } else if (media.headers.isNotEmpty) {
      // 带源站头的直链：经本机代理中转（电视无法自带 Referer/UA）。
      final resolve = proxyResolver ?? _defaultProxyResolve;
      final proxied = await resolve(media.url, media.headers);
      if (proxied != null) playUrl = proxied;
    }
    final subtitleUri = await _prepareSubtitle(target, media);
    media = CastMedia(
      url: playUrl,
      title: media.title,
      coverUrl: media.coverUrl,
      position: media.position,
      episodeIndex: media.episodeIndex,
      episodeCount: media.episodeCount,
      localPath: media.localPath,
      headers: media.headers,
      subtitleUrl: subtitleUri?.toString() ?? '',
      isMirror: media.isMirror,
    );
    _currentMedia = media;
    _traceTarget(media);

    final transport = _transport = _transportFactory(target);
    // DLNA 走兼容层（预检 → 配方链 → setUri → Play 门控 → Seek 容错）；
    // Chromecast 与所有不实现该能力的 transport 保持既有标准序列。
    final compat =
        transport is CastCompatTransport ? transport as CastCompatTransport : null;
    final remembered = recipes.lookup(target);
    try {
      Set<String> sink = const <String>{};
      if (compat != null) {
        try {
          sink = await compat.preflight().timeout(const Duration(seconds: 2));
          CastDiagnostics.instance.recordSinks(sink);
          CastDiagnostics.instance
              .recordTimeline('能力预检完成：Sink ${sink.length} 条');
        } on Exception catch (e) {
          ErrorLog.instance.record('投屏能力预检', e, StackTrace.current);
        }
      }
      CastRecipe? succeeded;
      if (compat != null) {
        succeeded = await compat.load(CastLoadRequest(
          url: Uri.parse(playUrl),
          title: media.title,
          duration: null, // 时长未知时省略，避免设备较真
          subtitleUrl: media.subtitleUrl.isEmpty
              ? null
              : Uri.tryParse(media.subtitleUrl),
          position: media.position,
          didl: DidlRequest(
            uri: Uri.parse(playUrl),
            title: media.title,
            mimeType: _mimeForCast(playUrl),
            subtitleUri: media.subtitleUrl.isEmpty
                ? null
                : Uri.tryParse(media.subtitleUrl),
            headers: media.headers,
          ),
          recipes: recipes.fallbackChain(target),
          protocolInfo: sink,
        ));
      } else {
        await transport.setUri(
          Uri.parse(playUrl),
          title: media.title,
          duration: null,
          subtitleUrl: media.subtitleUrl.isEmpty
              ? null
              : Uri.tryParse(media.subtitleUrl),
        );
        if (media.position > const Duration(seconds: 3)) {
          // 起播后可能被设备忽略：投完再 seek 一次（部分盒子只认这条顺序）。
          await transport.play();
          try {
            await transport.seekTo(media.position);
          } on Exception {
            // 设备不支持 Seek：从头播。
          }
        } else {
          await transport.play();
        }
      }
      if (succeeded != null) await _rememberRecipe(target, succeeded);
      _state = CastSessionState.casting;
      CastDiagnostics.instance.recordTimeline(
          'casting（投屏命令已接受${succeeded == null ? '' : '，配方 ${succeeded.didl.name}'}）');
      notifyListeners();
      _startPolling();
      unawaited(_startGena(target));
    } on Exception catch (e) {
      // 命中配方失败一次即清空，下次投屏重回梯度扫描。
      if (remembered != null) await _forgetRecipe(target);
      CastDiagnostics.instance.recordTimeline('投屏失败：$e');
      _state = CastSessionState.idle;
      _transport = null;
      _currentDevice = null;
      notifyListeners();
      rethrow;
    }
  }

  /// 诊断目标字段（M0）：本机服务 base 与监听端口来自会话字段；
  /// 直投公网 URL 时两者为空态（M0.5 接线路由源 IP）。纯采集。
  void _traceTarget(CastMedia media) {
    String? servingBase;
    int? servingPort;
    if (media.isLocalFile) {
      servingBase = _mediaServer.baseUrl;
      servingPort = _mediaServer.port;
    } else if (media.headers.isNotEmpty) {
      servingBase = _castProxy.baseUrl;
      servingPort = _castProxy.port;
    }
    CastDiagnostics.instance.recordTimeline(
        '媒体地址：${media.isLocalFile ? '本地文件' : (media.headers.isNotEmpty ? '本机代理' : '直投')}');
    CastDiagnostics.instance.setTarget(
      selectedIp:
          servingBase == null ? null : Uri.tryParse(servingBase)?.host,
      mediaPort: servingPort,
      mediaUrl: media.url,
    );
  }

  /// 配方记忆是尽力而为：写盘失败只进日志，绝不让已成功的投屏失败。
  Future<void> _rememberRecipe(CastTarget target, CastRecipe recipe) async {
    try {
      await recipes.remember(target, recipe);
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏配方记忆', e, StackTrace.current);
    }
  }

  Future<void> _forgetRecipe(CastTarget target) async {
    try {
      await recipes.forget(target);
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏配方重置', e, StackTrace.current);
    }
  }

  /// 尝试在当前会话上连投下一集（不回 idle，避免状态闪烁）。
  /// 失败（无下一集/推送出错）返回 false，由调用方走 onRemoteStopped。
  Future<bool> _tryAdvance() async {
    final provider = onNextEpisode;
    final device = _currentDevice;
    final transport = _transport;
    if (provider == null || device == null || transport == null) return false;
    _autoAdvancing = true;
    try {
      // 注意：不要写 provider().timeout(..., onTimeout: () => null)——
      // async 闭包的运行时类型是 Future<CastMedia> Function()，timeout 的
      // onTimeout 会被校验为 FutureOr<CastMedia>，返回 null 触发 TypeError。
      // 超时直接抛 TimeoutException，由下面的 catch 归一为「连投失败」。
      final next = await provider().timeout(const Duration(seconds: 10));
      if (next == null) return false;
      var playUrl = next.url;
      if (next.isLocalFile) {
        final served = await _mediaServer.urlFor(next.localPath);
        if (served == null) return false;
        playUrl = served;
      } else if (next.headers.isNotEmpty) {
        final resolve = proxyResolver ?? _defaultProxyResolve;
        final proxied = await resolve(next.url, next.headers);
        if (proxied != null) playUrl = proxied;
      }
      final subtitleUri = await _prepareSubtitle(device, next);
      // 连播换集：诊断目标只换 URL（IP/端口仍是本会话的服务）。
      CastDiagnostics.instance.setTarget(mediaUrl: playUrl);
      CastDiagnostics.instance.recordTimeline('连播下一集：${next.title}');
      await transport.setUri(
        Uri.parse(playUrl),
        title: next.title,
        subtitleUrl: subtitleUri,
      );
      await transport.play();
      _currentMedia = CastMedia(
        url: playUrl,
        title: next.title,
        coverUrl: next.coverUrl,
        episodeIndex: next.episodeIndex,
        episodeCount: next.episodeCount,
        localPath: next.localPath,
        headers: next.headers,
        subtitleUrl: subtitleUri?.toString() ?? '',
        isMirror: next.isMirror,
      );
      _lastPosition = Duration.zero;
      _lastDuration = Duration.zero;
      _polledAt = DateTime.now();
      _lastRunning = true;
      notifyListeners();
      return true;
    } on Exception {
      // 提供器超时/推送失败：按「没有下一集」处理，走远端停止路径。
      return false;
    } finally {
      _autoAdvancing = false;
    }
  }

  Future<void> setMute(bool muted) async => _transport?.setMute(muted);

  /// 尝试 GENA 订阅（仅 DLNA 且设备有 eventSubURL）；任何失败都静默回纯轮询。
  Future<void> _startGena(CastTarget target) async {
    final dlna = target.dlna;
    if (dlna == null || dlna.eventSubUrl.isEmpty) return;
    try {
      final gena = _gena = GenaSubscriber(dlna.eventSubUrl);
      final sub = _genaSub = gena.events.listen((poll) {
        if (_state != CastSessionState.casting) return;
        _lastGenaAt = DateTime.now();
        unawaited(_handlePoll(poll, _currentDevice));
      }, onError: (_) {});
      final ok = await gena.subscribe().timeout(const Duration(seconds: 8));
      if (!ok) {
        await sub.cancel();
        if (identical(_gena, gena)) _gena = null;
      }
    } catch (_) {
      // 订阅失败不影响投屏。
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollFailures = 0;
    _pollTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_pollOnce());
    });
  }

  Future<void> _pollOnce() async {
    final transport = _transport;
    if (transport == null || _state != CastSessionState.casting) return;
    // GENA 事件活跃时轮询降为 1/5 兜底（断流 15s 自动恢复高频）。
    if (_genaHealthy) {
      _pollTick++;
      if (_pollTick % 5 != 0) return;
    }
    final device = _currentDevice;
    try {
      final poll = await transport.poll().timeout(const Duration(seconds: 3));
      _pollFailures = 0;
      await _handlePoll(poll, device);
    } catch (_) {
      // 单次轮询失败容忍（Wi-Fi 抖动）；连续 5 次判失联，交 UI 决定是否重连。
      _pollFailures++;
      if (_pollFailures >= 5) {
        _pollFailures = 0;
        if (device != null) onSessionLost?.call(device);
      }
    }
  }

  /// GENA 事件是否健康（15s 内有推送）。
  bool get _genaHealthy =>
      _gena != null &&
      _gena!.active &&
      _lastGenaAt != null &&
      DateTime.now().difference(_lastGenaAt!) < const Duration(seconds: 15);

  /// 轮询与 GENA 事件共用的状态处理（含播完连投判定）。
  Future<void> _handlePoll(CastPoll poll, CastTarget? device) async {
    // 设备报告 STOPPED 时常不带位置：保留最后一次已知进度（回本地续播语义依赖它）。
    if (poll.isStopped && poll.position == Duration.zero && _lastPosition > Duration.zero) {
      poll = CastPoll(
        transportState: poll.transportState,
        position: _lastPosition,
        duration: poll.duration,
      );
    }
    _lastPosition = poll.position;
    _lastDuration = poll.duration;
    _polledAt = DateTime.now();
    _lastRunning = poll.isRunning;
    if (poll.transportState != _lastTimelineState) {
      _lastTimelineState = poll.transportState;
      CastDiagnostics.instance.recordTimeline(
          'transportState=${poll.transportState.isEmpty ? '未知' : poll.transportState}');
    }
    if (poll.isStopped && !_userStopping) {
      final position = _lastPosition;
      // 播完自动连投：停在时长结尾（±5s）且注入了下一集提供器；
      // 停在中途视为遥控器手动停止，不连投。
      final ended = _lastDuration > Duration.zero &&
          position >= _lastDuration - const Duration(seconds: 5);
      if (ended && !_autoAdvancing && await _tryAdvance()) return;
      // 电视端主动停止：感知并交还本地（UI 通过 onRemoteStopped 决定续播）。
      CastDiagnostics.instance.recordTimeline('电视端停止投屏');
      await _finishSession();
      if (device != null) onRemoteStopped?.call(device, position);
      return;
    }
    notifyListeners();
  }

  /// 用户拖动进度条后立刻对齐远端，不等下一次轮询。
  Future<void> forceRefresh() => _pollOnce();

  Future<void> pause() async => _transport?.pause();
  Future<void> resume() async => _transport?.play();

  Future<void> seekTo(Duration position) async {
    await _transport?.seekTo(position);
    // 先本地对齐，下一次轮询再用远端真值校正，避免进度条回跳。
    _lastPosition = position;
    _polledAt = DateTime.now();
    notifyListeners();
  }

  Future<void> setVolume(int percent) async => _transport?.setVolume(percent);

  /// 主动断开：返回电视端最后进度（供本地续播）。
  Future<Duration> disconnect() async {
    final device = _currentDevice;
    _userStopping = true;
    _state = CastSessionState.stopping;
    CastDiagnostics.instance.recordTimeline('用户断开投屏');
    notifyListeners();
    var position = _lastPosition;
    try {
      final transport = _transport;
      if (transport != null) {
        try {
          final poll =
              await transport.poll().timeout(const Duration(seconds: 2));
          if (poll.position > Duration.zero) position = poll.position;
        } catch (_) {}
        try {
          await transport.stop();
        } on Exception {
          // Stop 失败回退 Pause（CineFlow 做法：有的盒子 Stop 501）。
          try {
            await transport.pause();
          } catch (_) {}
        }
      }
    } finally {
      await _finishSession();
    }
    if (device != null) {
      // 断开后保留设备记忆（由 CastStore 持久化，控制器不碰盘）。
    }
    return position;
  }

  Future<void> _finishSession() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _transport?.close();
    _transport = null;
    final wasLocal = _currentMedia?.isLocalFile ?? false;
    final wasMirror = _currentMedia?.isMirror ?? false;
    _currentDevice = null;
    _currentMedia = null;
    // 本地文件投屏结束后关掉 HTTP 服务，别让端口一直开着。
    if (wasLocal) await _mediaServer.stop();
    // 镜像会话结束（断开/电视端停止）→ 停掉采集服务。
    if (wasMirror) await MirrorController.instance.stop();
    // 退订 GENA（事件流关闭 + UNSUBSCRIBE）。
    _genaSub?.cancel();
    _genaSub = null;
    final gena = _gena;
    _gena = null;
    _lastGenaAt = null;
    _pollTick = 0;
    if (gena != null) await gena.stop();
    // 代理条目随会话结束清空（下次投屏重新登记）。
    await _castProxy.stop();
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _polledAt = null;
    _lastRunning = false;
    _pollFailures = 0;
    _userStopping = false;
    onNextEpisode = null;
    _state = CastSessionState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _discoverySub?.cancel();
    _mdnsSub?.cancel();
    unawaited(_discovery?.stop());
    unawaited(_mediaServer.stop());
    unawaited(_castProxy.stop());
    _genaSub?.cancel();
    unawaited(_gena?.stop());
    _gena = null;
    if (_currentMedia?.isMirror ?? false) {
      unawaited(MirrorController.instance.stop());
    }
    _transport = null;
    super.dispose();
  }
}
