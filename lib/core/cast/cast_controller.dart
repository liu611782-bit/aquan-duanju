import 'dart:async';

import 'package:flutter/foundation.dart';

import '../error_log.dart';
import 'cast_diagnostics.dart';
import 'cast_media_proxy.dart';
import 'cast_media_type.dart';
import 'cast_profile.dart';
import 'cast_recipe.dart';
import 'cast_route.dart';
import 'cast_target.dart';
import 'didl.dart';
import 'gena_subscriber.dart';
import 'mirror/mirror_controller.dart';
import 'airplay/airplay_transport.dart';
import 'chromecast/chromecast_transport.dart';
import 'dlna_transport.dart';
import 'local_media_server.dart';
import 'mdns_discovery.dart';
import 'soap_client.dart';
import 'ssdp_discovery.dart';

/// 投屏会话状态。
enum CastSessionState { idle, discovering, connecting, casting, stopping }

/// 本机转码（Go castrelay，ffmpeg 管道）产物的 mime 提示：hls 档输出恒为
/// HLS（cast_media_fallback.relayMimeHint 同值，产物 URL 已是 .m3u8）。
const String kRelayProductMimeHint = 'application/vnd.apple.mpegurl';

/// 本机转码 ts 档（R2）产物的 mime 提示：产物 URL 为 `…/stream.ts`，
/// 按 URL 扩展名语义判 TS 容器。
const String kRelayProductTsMimeHint = 'video/mp2t';

/// 本机转码产物的 mime 提示按产物 URL 扩展名分流（R2）：`.ts` → TS 档。
String _relayProductMimeHint(String url) =>
    url.toLowerCase().endsWith('.ts')
        ? kRelayProductTsMimeHint
        : kRelayProductMimeHint;

/// 兼容模式选路结果（M5-0）：最终投屏 URL + 已判定的源媒体类型
/// （复用避免二次嗅探）+ 是否经本机转码（产物恒 HLS）。
typedef _PreparedPlayUrl = ({
  String url,
  CastMediaType? sourceType,
  bool viaRelay,
});

/// 本机转码挂点形状：媒体 + 选路决定的输出档位（R2）+ 会话字幕（R3）。
typedef CastTranscodeResolver = Future<String?> Function(
  CastMedia media, {
  String? relayFormat,
  Uri? relaySubtitleUrl,
});

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
    this.mimeHint = '',
    this.duration,
    this.viaRelay = false,
    this.codecHint = '',
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

  /// 调用方已知的媒体 mime（如 `ResolvedPlayback.mimeType`）。作为
  /// [resolveCastMediaType] 的第一级证据（显式 hint）；空 = 无提示，
  /// 由 URL 扩展名/内容嗅探判定。
  final String mimeHint;

  /// 真实时长（播放器手里有时长就传）。null/≤0 = 未知或直播——
  /// DIDL `<res duration>` 只在真实值时写（写错比不写更糟，AC-27）。
  final Duration? duration;

  /// 该 URL 已是本机中继（Go castrelay）产物。兼容模式选路（M5-0）对它恒
  /// 直投，不会再套一层转码：加密分集与 resolvePlay 源在调用方完成中继后
  /// 置位；屏幕镜像（[isMirror]）同理不受选路影响。
  final bool viaRelay;

  /// 视频编码提示（如 `hevc` / `h265` / `av1`，红果 VideoStream.codec）。
  /// 兼容模式 auto 选路据此把 HEVC/AV1 分集路由到本机转码（统一转 H.264）。
  final String codecHint;

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
    case CastProtocol.airplay:
      return AirPlayTransport(target.airplay!);
  }
}

/// 同 IP 降级链协议位次（design §3）：dlna → chromecast → airplay（末位追加）。
int castProtocolFallbackRank(CastProtocol protocol) => switch (protocol) {
      CastProtocol.dlna => 0,
      CastProtocol.chromecast => 1,
      CastProtocol.airplay => 2,
    };

/// 投屏会话控制器：状态机 + 1s 轮询 + 远端主动停止感知 + 多协议路由。
///
/// 本地联动（暂停本地播放器/断开回本地续播）由 UI 层订阅完成——控制器只管远端。
class CastController extends ChangeNotifier {
  CastController({
    CastTransport Function(CastTarget)? transportFactory,
    this.mdnsDiscover,
    this.airplayDiscover,
    this.proxyResolver,
    CastRecipeStore? recipeStore,
    CastProfileStore? profileStore,
  })  : _transportFactory = transportFactory ?? defaultTransportFactory,
        recipes = recipeStore ?? CastRecipeStore(),
        profiles = profileStore;

  final CastTransport Function(CastTarget) _transportFactory;

  /// 设备 → 成功配方（v4 双层键）。默认是一张不落盘的内存表；集成时把
  /// `CastStore.recipes`（v4 持久化）注入这里即可跨启动记住配方
  /// （`CastService.attachStores`，M3-4）。
  CastRecipeStore recipes;

  /// 设备画像（可选）：非 null 时投屏成功/会话收尾同步更新画像并落盘。
  /// 未接线（测试/独立使用）时为 null，不影响任何投屏行为。
  CastProfileStore? profiles;

  /// mDNS 发现挂点（Chromecast）注入点；null = 用默认 [MdnsDiscovery]。
  final Stream<CastDeviceInfo> Function()? mdnsDiscover;

  /// mDNS 发现挂点（AirPlay `_airplay._tcp`）注入点；null = 用默认实现。
  final Stream<AirPlayDeviceInfo> Function()? airplayDiscover;

  /// 受保护流代理挂点。非 null 时带源站头的直链经它包一层；返回 null 表示不代理。
  /// null 时用控制器自带的 [CastMediaProxy]。
  final Future<String?> Function(String url, Map<String, String> headers)?
      proxyResolver;

  /// 兼容模式（本机转码）挂点（M5-0）：选路判定为「走中继」时由控制器调用，
  /// UI 层在发起投屏时注入 Go `castRelayStart` 适配器（闭包内停旧会话、挂
  /// 取流探针，与 [onNextEpisode] 同一注入模式；断开/收尾由 [_finishSession]
  /// 清引用）。返回中继产物 URL；null = 中继不可用（选路回退直投/代理）。
  /// 未注入 = 本机转码路由不可用，auto/always 一律回退。
  ///
  /// [relayFormat] 是选路决定的输出档位（R2：Sink 含 HLS → hls；无 HLS 有
  /// TS → ts；证据缺失 → hls）。[relaySubtitleUrl] 是已按目标设备登记的
  /// 会话字幕（R3：Go 侧借此给媒体响应补 `CaptionInfo.sec` 第三通道）。
  CastTranscodeResolver? transcodeResolver;

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

  /// 跳集队列（遥控器上一集/手动跳集）：与 [onNextEpisode] 同一注入模式。
  /// [delta] 语义由 UI 队列决定（-1 = 上一集）；0 或越界返回 null。
  /// 会话结束自动清空。未注入时 UI 按钮置灰（直播/无队列场景）。
  Future<CastMedia?> Function(int delta)? onEpisodeJump;

  bool _autoAdvancing = false;

  CastSessionState get state => _state;
  List<CastTarget> get devices => List.unmodifiable(_devices);
  CastTarget? get currentDevice => _currentDevice;
  CastMedia? get currentMedia => _currentMedia;
  Duration get remoteDuration => _lastDuration;
  bool get isCasting => _state == CastSessionState.casting;

  /// 最近一次轮询到的远端 transportState（原始 UPnP/CASTv2 词汇，未映射）。
  /// 空串 = 尚未轮询到（UI 据此隐藏状态徽标）。
  String get remoteTransportState => _lastTransportState;

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
  String _lastTransportState = '';
  int _pollFailures = 0;
  SsdpDiscovery? _discovery;
  StreamSubscription<SsdpEvent>? _discoverySub;
  StreamSubscription<CastDeviceInfo>? _mdnsSub;
  StreamSubscription<AirPlayDeviceInfo>? _airplaySub;
  GenaSubscriber? _gena;
  StreamSubscription<CastPoll>? _genaSub;
  DateTime? _lastGenaAt;
  int _pollTick = 0;

  /// 诊断时间线去重：只记录电视状态变化（M0 纯采集）。
  String _lastTimelineState = '';

  /// 本会话预检到的 Sink 清单与预检结果（画像构建用，M3）。
  /// 连播期间沿用会话内的 Sink 记忆（预检失败也不阻断连播）。
  Set<String> _sessionSink = const <String>{};
  bool _sessionPreflightOk = false;

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
    // AirPlay `_airplay._tcp` 同一扫描周期并行收流（失败同样静默，不影响
    // DLNA/Chromecast；`_raop._tcp` 纯音频设备不进列表——见 MdnsDiscovery）。
    final discoverAirplay = airplayDiscover ?? _defaultAirplayDiscover;
    _airplaySub?.cancel();
    _airplaySub = discoverAirplay().listen((info) {
      _upsertDevice(CastTarget.airplay(info));
    }, onError: (_) {});
  }

  static Stream<CastDeviceInfo> _defaultMdnsDiscover() =>
      MdnsDiscovery.discover(MdnsDiscovery.chromecastServiceType);

  static Stream<AirPlayDeviceInfo> _defaultAirplayDiscover() =>
      MdnsDiscovery.discoverAirplay();

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
    _airplaySub?.cancel();
    _airplaySub = null;
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

  /// 受保护流代理登记：默认走 [CastMediaProxy.register] 并按目标设备取
  /// 路由源 IP（M0.5 per-device IP）；注入的 [proxyResolver] 不感知目标
  /// 设备（测试/替代实现），行为保持不变。
  /// [urlSuffixMode] 是目标设备配方里的 URL 形态旋钮（M1，默认带扩展名）。
  /// [subtitleUrl] 是已登记的字幕地址（M5-1）：代理媒体响应借此附加
  /// `CaptionInfo.sec` 第三通道。
  Future<String?> _proxyResolve(
    String url,
    Map<String, String> headers, {
    String? targetHost,
    String? hintMime,
    bool live = false,
    CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension,
    String? subtitleUrl,
  }) =>
      proxyResolver != null
          ? proxyResolver!(url, headers)
          : _castProxy.register(
              url,
              headers: headers,
              targetHost: targetHost,
              hintMime: hintMime,
              live: live,
              urlSuffixMode: urlSuffixMode,
              subtitleUrl: subtitleUrl,
            );

  /// 兼容模式选路（M5-0/M5-3，design §4.10 判定表）：按配方三态 +
  /// 媒体类型三级判定 + 预检 Sink 决定「直投 / 本机代理 / 本机转码」。
  /// 首投（[_castWith]）与连播（[_tryAdvance]）共用同一段选路代码。
  ///
  /// - 本地文件：恒走 [LocalMediaServer]（选路不涉及）；
  /// - 镜像流 / Chromecast：保持现状（镜像已是本机产物；Chromecast 播放
  ///   路径按 P0 契约不动，只允许字幕转换开关影响它）；
  /// - 转码执行体是 [transcodeResolver]（UI 注入的 Go `castRelayStart`
  ///   适配器，中继会话生命周期由闭包管理）；未注入或启动失败回退
  ///   代理/直投，不让转码失败堵死投屏（M1-6 / AC-21 同语义）。
  Future<_PreparedPlayUrl> _preparePlayUrl(
    CastTarget target,
    CastMedia media, {
    required Set<String> sink,
    required CastTranscodeMode transcodeMode,
    required CastUrlSuffixMode urlSuffixMode,
    Uri? subtitleUrl,
  }) async {
    if (media.isLocalFile) {
      // M0.5：按目标设备取路由源 IP 生成对外 URL（电视拉得到流的地址）。
      final served = await _mediaServer.urlFor(media.localPath,
          targetHost: target.host,
          urlSuffixMode: urlSuffixMode,
          subtitleUrl: subtitleUrl?.toString());
      if (served == null) {
        throw CastException('本地媒体服务启动失败（检查是否在局域网内）');
      }
      return (url: served, sourceType: null, viaRelay: false);
    }
    if (target.protocol != CastProtocol.dlna || media.isMirror) {
      return _proxyOrDirect(
        media,
        target: target,
        urlSuffixMode: urlSuffixMode,
        hintMime: media.mimeHint,
      );
    }
    // 源媒体类型三级判定（显式 hint → URL 扩展名 → 内容嗅探；嗅探到
    // HTML/JSON 抛 CastException，把「错误页不喂电视」前移到投屏前）。
    final sourceType = await resolveCastMediaType(
      url: Uri.parse(media.url),
      hintMime: media.mimeHint,
      sinkMimes: sink,
      sniffHead: defaultSniffHead,
    );
    final route = resolveCastRoute(
      mode: transcodeMode,
      mediaType: sourceType,
      sinkMimes: sink,
      viaRelay: media.viaRelay,
      needsProxy: media.headers.isNotEmpty,
      // 编码提示合并口径（R1）：红果显式 stream.codec 优先，内容嗅探其次
      // （MP4 ftyp brand / HLS 主清单 CODECS）；嗅探只影响选路。
      codecHint: mergeCodecHint(media.codecHint, sourceType.codecHint),
    );
    CastDiagnostics.instance.recordTimeline(
        '选路：${_routeLabel(route)}（模式 ${transcodeMode.name}，${sourceType.mime}）');
    switch (route) {
      case CastRoute.relay:
        // 输出档位（R2）：Sink 含 HLS → hls；无 HLS 有 TS → ts；
        // Sink 缺失/未知 → hls（relayFormatFor 证据缺失回落现状）。
        final relayed = await _transcodeResolve(
          media,
          relayFormat: relayFormatFor(sink),
          relaySubtitleUrl: subtitleUrl,
        );
        if (relayed != null && relayed.isNotEmpty) {
          return (url: relayed, sourceType: sourceType, viaRelay: true);
        }
        // 中继不可用：回退代理/直投（记时间线，不算投屏失败）。
        CastDiagnostics.instance.recordTimeline(
            '本机转码不可用，回退${media.headers.isNotEmpty ? '代理' : '直投'}');
        return _proxyOrDirect(
          media,
          target: target,
          urlSuffixMode: urlSuffixMode,
          sourceType: sourceType,
          subtitleUrl: subtitleUrl,
        );
      case CastRoute.proxy:
        return _proxyOrDirect(
          media,
          target: target,
          urlSuffixMode: urlSuffixMode,
          sourceType: sourceType,
          subtitleUrl: subtitleUrl,
        );
      case CastRoute.direct:
        return (url: media.url, sourceType: sourceType, viaRelay: false);
    }
  }

  /// 防盗链直链经本机代理中转（电视无法自带 Referer/UA）；代理不可用回退
  /// 直投。[sourceType] 给定时作登记 hint，上游不再重复嗅探。
  Future<_PreparedPlayUrl> _proxyOrDirect(
    CastMedia media, {
    required CastTarget target,
    required CastUrlSuffixMode urlSuffixMode,
    CastMediaType? sourceType,
    Uri? subtitleUrl,
    String? hintMime,
  }) async {
    final proxied = media.headers.isEmpty
        ? null
        : await _proxyResolve(
            media.url,
            media.headers,
            targetHost: target.host,
            hintMime: sourceType?.mime ?? hintMime,
            urlSuffixMode: urlSuffixMode,
            subtitleUrl: subtitleUrl?.toString(),
          );
    return (url: proxied ?? media.url, sourceType: sourceType, viaRelay: false);
  }

  /// 调用本机转码挂点（M5-0）。任何失败只进 ErrorLog 并返回 null——
  /// 转码失败走选路回退，不算投屏失败（原始异常不与用户见面）。
  Future<String?> _transcodeResolve(
    CastMedia media, {
    String? relayFormat,
    Uri? relaySubtitleUrl,
  }) async {
    final resolver = transcodeResolver;
    if (resolver == null) return null;
    try {
      return await resolver(
        media,
        relayFormat: relayFormat,
        relaySubtitleUrl: relaySubtitleUrl,
      );
    } on Exception catch (e, stack) {
      ErrorLog.instance.record('投屏兼容模式转码', e, stack);
      return null;
    }
  }

  String _routeLabel(CastRoute route) => switch (route) {
        CastRoute.direct => '直投',
        CastRoute.proxy => '本机代理',
        CastRoute.relay => '本机转码',
      };

  /// 配方链按产物形态调整（R2 DIDL 对齐）：中继 TS 档产物把默认 standard
  /// 模板升级为 sinkEntry——Sink 有 TS 条目时照抄设备第 4 段（WMP 族对
  /// protocolInfo 第 4 段敏感），无条目时模板自身回落 standard。其余产物
  /// 形态走 [CastRecipeStore.fallbackChain] 原样。
  List<CastRecipe> _recipeChainFor(
    CastTarget target,
    Set<String> sink, {
    required bool viaRelay,
    required String productMime,
  }) {
    final chain = recipes.fallbackChain(target,
        sink: sink.toList(), profile: profiles?.lookup(target.id));
    if (viaRelay && isTsMime(productMime)) {
      return upgradeChainForTsProduct(chain);
    }
    return chain;
  }

  /// 字幕投送前的准备：带源站头的字幕必须经代理；SRT 是否转 VTT 按协议
  /// 分流（M5-1）——DLNA 保持 SRT 原样（修正「转 VTT 却在 DIDL 声明
  /// text/srt」的错配），Chromecast 转 VTT（Chromecast 只认 VTT）。
  Future<Uri?> _prepareSubtitle(CastTarget target, CastMedia media,
      {CastUrlSuffixMode urlSuffixMode = CastUrlSuffixMode.withExtension}) async {
    final raw = media.subtitleUrl;
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    final isChromecast = target.protocol == CastProtocol.chromecast;
    final needsProxy = media.headers.isNotEmpty ||
        (isChromecast && raw.toLowerCase().endsWith('.srt'));
    if (!needsProxy) return uri;
    final proxied = await _castProxy.registerSubtitle(raw,
        headers: media.headers,
        targetHost: target.host,
        urlSuffixMode: urlSuffixMode,
        convertToVtt: isChromecast);
    return proxied == null ? uri : Uri.tryParse(proxied);
  }

  LocalMediaServer get mediaServer => _mediaServer;

  /// 投到指定目标。同 IP 存在另一协议目标且首选失败时自动降级重试一次
  /// （如 Chromecast 就绪超时 → 同 IP 的 DLNA MediaRenderer）。
  ///
  /// 降级链位次 [castProtocolFallbackRank]：dlna → chromecast → airplay
  /// （AirPlay 一期排末位——经典 `/play` 接收端覆盖面最小，其余协议优先）。
  Future<void> castTo(CastTarget target, CastMedia media) async {
    try {
      await _castWith(target, media);
    } on Exception {
      final alt = _devices
          .where((d) =>
              d.host.isNotEmpty &&
              d.host == target.host &&
              d.protocol != target.protocol)
          .toList()
        ..sort((a, b) => castProtocolFallbackRank(a.protocol)
            .compareTo(castProtocolFallbackRank(b.protocol)));
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
    _lastTransportState = '';
    _sessionSink = const <String>{};
    _sessionPreflightOk = false;
    // 诊断会话（M0）：重置会话级采集，保留发现阶段证据。纯采集，不影响链路。
    CastDiagnostics.instance.beginSession(
      deviceName: target.name,
      protocol: target.protocol.name,
    );
    CastDiagnostics.instance
        .recordTimeline('connecting → ${target.name}（${target.host}）');
    notifyListeners();

    final remembered = recipes.lookup(target);
    // URL 形态旋钮（M1 / 回滚点 R1）与兼容模式三态（M5-0 / AC-22）：都来自
    // 按 UDN 记忆的配方。此时预检未跑（Sink 未知），共享层只能命中 nosink
    // 键——尽力而为；预检后的配方链按真实 Sink 查询（udn 精确层命中则与
    // Sink 无关）。
    final suffixMode =
        remembered?.urlSuffixMode ?? CastUrlSuffixMode.withExtension;
    final transcodeMode = remembered?.transcodeMode ?? CastTranscodeMode.auto;

    // transport 与能力预检提前（M5-0）：兼容模式选路（直投/代理/本机转码）
    // 依赖设备 Sink 的 HLS 支持判定，必须在媒体准备之前完成。
    final transport = _transport = _transportFactory(target);
    // DLNA 走兼容层（预检 → 配方链 → setUri → Play 门控 → Seek 容错）；
    // Chromecast 与所有不实现该能力的 transport 保持既有标准序列。
    final compat =
        transport is CastCompatTransport ? transport as CastCompatTransport : null;
    // Sink 提升到 try 外：失败路径的配方清空也要按同一口径（M3 双层键）。
    var sink = const <String>{};
    try {
      if (compat != null) {
        try {
          sink = await compat.preflight().timeout(const Duration(seconds: 2));
          _sessionSink = sink;
          _sessionPreflightOk = true;
          CastDiagnostics.instance.recordSinks(sink);
          CastDiagnostics.instance
              .recordTimeline('能力预检完成：Sink ${sink.length} 条');
        } on Exception catch (e) {
          ErrorLog.instance.record('投屏能力预检', e, StackTrace.current);
        }
      }

      // 字幕先于媒体登记准备（M5-1）：代理/本地服务的媒体响应要靠登记好的
      // 字幕 URL 补 CaptionInfo.sec 第三通道。
      final subtitleUri =
          await _prepareSubtitle(target, media, urlSuffixMode: suffixMode);

      // M5-0/M5-3 兼容模式选路（直投 / 本机代理 / 本机转码）。
      // 本地文件、镜像流与 Chromecast 路径不受选路影响。
      final prepared = await _preparePlayUrl(
        target,
        media,
        sink: sink,
        transcodeMode: transcodeMode,
        urlSuffixMode: suffixMode,
        subtitleUrl: subtitleUri,
      );
      final playUrl = prepared.url;
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
        mimeHint: media.mimeHint,
        duration: media.duration,
        viaRelay: prepared.viaRelay,
        codecHint: media.codecHint,
      );
      _currentMedia = media;
      _traceTarget(media);

      // M1-1：媒体类型三级判定（显式 hint → URL 扩展名 → 内容嗅探），
      // 替代旧 `_mimeForCast`（.m3u8 判 video/mp2t、无扩展名兜底 video/mp4）。
      // 设备 Sink 只参与「拼写选择」，绝不用它覆盖判定结果（AC-13）。
      // 嗅探到 HTML/JSON 会抛 CastException：投屏前就报「这个地址不是视频」。
      // 选路阶段已判定源类型时直接复用（直投同 URL、代理不改 mime）；
      // 本机转码产物按产物 URL 形态判 hint（hls 档恒 HLS，ts 档 stream.ts）。
      final mediaType = prepared.viaRelay
          ? await resolveCastMediaType(
              url: Uri.parse(playUrl),
              hintMime: _relayProductMimeHint(playUrl),
              sinkMimes: sink,
            )
          : prepared.sourceType ??
              await resolveCastMediaType(
                url: Uri.parse(playUrl),
                hintMime: media.mimeHint,
                sinkMimes: sink,
                sniffHead: defaultSniffHead,
              );
      CastDiagnostics.instance
          .recordTimeline('媒体类型：${mediaType.mime}（${mediaType.fileName}）');
      final durationText =
          media.duration == null ? null : formatUpnpTime(media.duration!);
      CastRecipe? succeeded;
      if (compat != null) {
        succeeded = await compat.load(CastLoadRequest(
          url: Uri.parse(playUrl),
          title: media.title,
          duration: durationText, // 真实时长才有（AC-27）
          subtitleUrl: media.subtitleUrl.isEmpty
              ? null
              : Uri.tryParse(media.subtitleUrl),
          position: media.position,
          didl: DidlRequest(
            uri: Uri.parse(playUrl),
            title: media.title,
            mimeType: mediaType.mime,
            duration: media.duration,
            live: mediaType.live,
            subtitleUri: media.subtitleUrl.isEmpty
                ? null
                : Uri.tryParse(media.subtitleUrl),
            headers: media.headers,
          ),
          // M3 配方链（design §4.5）：udn → model(+sinkHash) → 画像预设 → 梯度；
          // 中继 TS 档产物把默认 standard 模板升级 sinkEntry（R2）。
          recipes: _recipeChainFor(
            target,
            sink,
            viaRelay: prepared.viaRelay,
            productMime: mediaType.mime,
          ),
          protocolInfo: sink,
        ));
      } else {
        await transport.setUri(
          Uri.parse(playUrl),
          title: media.title,
          duration: durationText,
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
      if (succeeded != null) await _rememberRecipe(target, succeeded, sink: sink);
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
      // transport 已提前创建（M5-0）：失败路径同样要释放底层连接。
      _transport?.close();
      _transport = null;
      _currentDevice = null;
      notifyListeners();
      rethrow;
    }
  }

  /// 诊断目标字段（M0.5 接真实值）：本机伺服（本地文件/代理/本机转码）时
  /// 投屏 URL 的 host 就是按目标设备解析出的路由源 IP（per-device IP）；
  /// 直投公网 URL 时 IP/端口为空态。纯采集。
  ///
  /// 中继产物（viaRelay）的 IP/端口随后由 [CastRelayProbe] 按 Go
  /// `castRelayStatus` 回传的监听值转写校正（R3）——这里先按产物 URL
  /// 取值，防盗链源不再误报成代理端口。
  void _traceTarget(CastMedia media) {
    final uri = Uri.tryParse(media.url);
    final servedLocally =
        media.isLocalFile || media.headers.isNotEmpty || media.viaRelay;
    int? servingPort;
    if (media.isLocalFile) {
      servingPort = _mediaServer.port;
    } else if (media.viaRelay) {
      servingPort = uri?.port;
    } else if (media.headers.isNotEmpty) {
      servingPort = _castProxy.port;
    }
    CastDiagnostics.instance.recordTimeline(
        '媒体地址：${media.isLocalFile ? '本地文件' : media.viaRelay ? '本机转码' : (media.headers.isNotEmpty ? '本机代理' : '直投')}');
    CastDiagnostics.instance.setTarget(
      selectedIp: servedLocally ? uri?.host : null,
      mediaPort: servingPort,
      mediaUrl: media.url,
    );
  }

  /// 配方记忆是尽力而为：写盘失败只进日志，绝不让已成功的投屏失败。
  /// 成功后同步更新设备画像并落盘（M3 时序：remember(recipe) → profiles）。
  ///
  /// 兼容模式三态是用户显式偏好（AC-22）：成功配方若来自梯度/共享层
  /// （默认 auto），记忆时沿用设备已有配方里的三态，避免把用户设置的
  /// always/never 冲掉；成功配方本身带非 auto 三态时以它为准。
  Future<void> _rememberRecipe(
    CastTarget target,
    CastRecipe recipe, {
    Set<String> sink = const <String>{},
  }) async {
    final mode = recipe.transcodeMode != CastTranscodeMode.auto
        ? recipe.transcodeMode
        : recipes.lookup(target)?.transcodeMode ?? CastTranscodeMode.auto;
    try {
      await recipes.remember(
          target, recipe.copyWith(transcodeMode: mode), sink: sink.toList());
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏配方记忆', e, StackTrace.current);
    }
    await _rememberProfile(target);
  }

  /// 设备画像同步（尽力而为）：按本会话观测构建画像并落盘。
  ///
  /// 投屏成功时立即记一次（serviceType/Sink/预检证据）；电视取流记录随
  /// 会话推进变全，会话收尾（[CastDiagnostics] 数据仍在）再刷一次
  /// fetchedStream / rangeSupport。
  Future<void> _rememberProfile(CastTarget target) async {
    final store = profiles;
    final dlna = target.dlna;
    if (store == null || dlna == null) return;
    try {
      final diag = CastDiagnostics.instance;
      await store.remember(buildProfile(
        dlna,
        sink: _sessionSink.toList(),
        preflightOk: _sessionPreflightOk,
        mediaRequests: diag.mediaRequests,
        soapTraces: diag.soapTraces,
      ));
    } on Exception catch (e) {
      ErrorLog.instance.record('投屏画像记忆', e, StackTrace.current);
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
  ///
  /// M3-5：DLNA 连播换集走 `compat.load()`（预检 → 配方链 → setUri →
  /// Play 门控），不再用旧 `transport.setUri()` 三件套——恢复 full 变体、
  /// 真实 duration 写入 DIDL 与空 metadata 门控（M2 遗留问题收口，
  /// AC-27/AC-11 在连播路径同样成立）。
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
      return await _pushMedia(device, transport, next);
    } on Exception {
      // 提供器超时/推送失败：按「没有下一集」处理，走远端停止路径。
      return false;
    } finally {
      _autoAdvancing = false;
    }
  }

  /// 遥控器「下一集」：复用连播链路（预取/选路/中继语义与自动连投一致，
  /// 在当前 transport 上换集，不重复起停中继）。
  ///
  /// 与自动连投的差异：手动换集时当前集仍在播，提供器返回 null 或推送
  /// 失败都**不**归一为远端停止路径——会话保持，返回 false 由 UI 给固定文案。
  Future<bool> advanceNextEpisode() {
    if (_autoAdvancing) return Future<bool>.value(false);
    return _tryAdvance();
  }

  /// 遥控器跳集（上一集/任意 delta）：走 [onEpisodeJump] 取目标媒体后
  /// 复用 [_pushMedia]（连播推送链路）。未注入 / delta == 0 / 提供器返回
  /// null（越界）/ 推送失败都返回 false；会话保持，UI 给固定文案。
  Future<bool> jumpEpisode(int delta) async {
    final provider = onEpisodeJump;
    final device = _currentDevice;
    final transport = _transport;
    if (provider == null || device == null || transport == null) return false;
    if (delta == 0) return false;
    if (_autoAdvancing) return false;
    _autoAdvancing = true;
    try {
      // 与 _tryAdvance 同口径：不带 onTimeout（泛型协变坑，见 P1a 契约）。
      final media = await provider(delta).timeout(const Duration(seconds: 10));
      if (media == null) return false;
      return await _pushMedia(device, transport, media);
    } on Exception {
      return false;
    } finally {
      _autoAdvancing = false;
    }
  }

  /// 把 [next] 推到当前会话的 [transport] 上（连播/手动换集共用）：
  /// URL 选路 → compat.load 或标准序列 → 更新会话媒体与进度。推送期间
  /// [_autoAdvancing] 为 true（调用方设置），轮询到 STOPPED 不会误判为
  /// 电视端主动停止。
  Future<bool> _pushMedia(
    CastTarget device,
    CastTransport transport,
    CastMedia next,
  ) async {
    // URL 形态旋钮与兼容模式三态沿用会话配方（连播与首投同选路）。
    final remembered = recipes.lookup(device);
    final suffixMode =
        remembered?.urlSuffixMode ?? CastUrlSuffixMode.withExtension;
    final transcodeMode = remembered?.transcodeMode ?? CastTranscodeMode.auto;
    final compat =
        transport is CastCompatTransport ? transport as CastCompatTransport : null;
    // 预检刷新 Sink（失败沿用会话内记忆，不阻断连播）；提前到媒体准备
    // 之前——兼容模式选路依赖 Sink 判定（M5-3）。
    var sink = _sessionSink;
    if (compat != null) {
      try {
        final probed =
            await compat.preflight().timeout(const Duration(seconds: 2));
        if (probed.isNotEmpty) {
          sink = probed;
          _sessionSink = probed;
        }
      } on Exception {
        // 预检失败不阻断连播。
      }
    }
    final subtitleUri = await _prepareSubtitle(device, next,
        urlSuffixMode: suffixMode);
    // 连播与首投共用同一段选路代码（M5-0/M5-3）。
    final prepared = await _preparePlayUrl(
      device,
      next,
      sink: sink,
      transcodeMode: transcodeMode,
      urlSuffixMode: suffixMode,
      subtitleUrl: subtitleUri,
    );
    final playUrl = prepared.url;
    // 连播换集：诊断目标只换 URL（IP/端口仍是本会话的服务）。
    CastDiagnostics.instance.setTarget(mediaUrl: playUrl);
    CastDiagnostics.instance.recordTimeline('连播下一集：${next.title}');
    if (compat != null) {
      // 媒体类型判定：选路已判定源类型时复用；本机转码产物按产物 URL
      // 形态判 hint（与首投同口径）。
      final mediaType = prepared.viaRelay
          ? await resolveCastMediaType(
              url: Uri.parse(playUrl),
              hintMime: _relayProductMimeHint(playUrl),
              sinkMimes: sink,
            )
          : prepared.sourceType ??
              await resolveCastMediaType(
                url: Uri.parse(playUrl),
                hintMime: next.mimeHint,
                sinkMimes: sink,
                sniffHead: defaultSniffHead,
              );
      CastDiagnostics.instance.recordTimeline(
          '连播媒体类型：${mediaType.mime}（${mediaType.fileName}）');
      final succeeded = await compat.load(CastLoadRequest(
        url: Uri.parse(playUrl),
        title: next.title,
        duration:
            next.duration == null ? null : formatUpnpTime(next.duration!),
        subtitleUrl: subtitleUri,
        position: next.position,
        didl: DidlRequest(
          uri: Uri.parse(playUrl),
          title: next.title,
          mimeType: mediaType.mime,
          duration: next.duration,
          live: mediaType.live,
          subtitleUri: subtitleUri,
          headers: next.headers,
        ),
        recipes: _recipeChainFor(
          device,
          sink,
          viaRelay: prepared.viaRelay,
          productMime: mediaType.mime,
        ),
        protocolInfo: sink,
      ));
      if (succeeded != null) {
        await _rememberRecipe(device, succeeded, sink: sink);
      }
    } else {
      // 非 compat transport（Chromecast / 测试假件）：保持既有标准序列。
      await transport.setUri(
        Uri.parse(playUrl),
        title: next.title,
        duration:
            next.duration == null ? null : formatUpnpTime(next.duration!),
        subtitleUrl: subtitleUri,
      );
      await transport.play();
    }
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
      mimeHint: next.mimeHint,
      duration: next.duration,
      viaRelay: prepared.viaRelay,
      codecHint: next.codecHint,
    );
    _lastPosition = Duration.zero;
    _lastDuration = Duration.zero;
    _polledAt = DateTime.now();
    _lastRunning = true;
    notifyListeners();
    return true;
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
    _lastTransportState = poll.transportState;
    if (poll.transportState != _lastTimelineState) {
      _lastTimelineState = poll.transportState;
      CastDiagnostics.instance.recordTimeline(
          'transportState=${poll.transportState.isEmpty ? '未知' : poll.transportState}');
    }
    // 换集推送进行中（连投/手动跳集）设备可能短暂上报 STOPPED：不是电视端
    // 主动停止，不打断会话；推送失败时 _autoAdvancing 已复位，下一次轮询
    // 照常走远端停止路径。
    if (poll.isStopped && !_userStopping && !_autoAdvancing) {
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
    final finishedDevice = _currentDevice;
    _transport?.close();
    _transport = null;
    final wasLocal = _currentMedia?.isLocalFile ?? false;
    final wasMirror = _currentMedia?.isMirror ?? false;
    // 会话收尾画像刷新：此时电视取流记录最全（fetchedStream/rangeSupport）。
    // 尽力而为，绝不让画像写入拖垮会话清理。
    if (finishedDevice != null) await _rememberProfile(finishedDevice);
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
    _lastTransportState = '';
    _pollFailures = 0;
    _userStopping = false;
    onNextEpisode = null;
    onEpisodeJump = null;
    transcodeResolver = null;
    _state = CastSessionState.idle;
    notifyListeners();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _discoverySub?.cancel();
    _mdnsSub?.cancel();
    _airplaySub?.cancel();
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
