import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/player/player_engine.dart';
import '../core/player/mpv_headers.dart';
import '../core/player/playback_failure_gate.dart';
import '../core/cast/cast_controller.dart';
import '../core/cast/cast_media_fallback.dart';
import '../core/cast/cast_relay_probe.dart';
import '../core/aqua_api.dart';
import '../core/bili/api.dart';
import '../core/error_log.dart';
import '../core/player/track_preference.dart';
import '../core/sources/media_proxy.dart';
import '../core/sources/resolved_playback.dart';
import '../core/sources/parse_engine.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_import.dart';
import '../store/stores.dart';
import '../widgets/cast_panel.dart';
import '../widgets/player_track_sheet.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';
import '../widgets/loading.dart';

/// 分集播放地址解析钩子：bili:// 协议等需要播放时现解析的源提供。
class ResolvedPlay {
  const ResolvedPlay({required this.videoUrl, this.audioUrl, this.notice});
  final String videoUrl;
  final String? audioUrl;
  final String? notice;
}

typedef EpisodePlayResolver = Future<ResolvedPlay> Function(
    UnifiedEpisode episode);

/// 第三方源轻量播放器：mpv 直链播放（Media httpHeaders 支持 Referer/UA），
/// 每 5 秒回写历史（sourceKey 区分来源），失败自动换线（先线路后源由上层处理）。
/// [resolvePlay] 提供时支持 DASH 音视频双轨（mpv audio-files，BiliSail 同方案）
/// 与弹幕（[loadDanmaku]）。
class SourcePlayerScreen extends StatefulWidget {
  const SourcePlayerScreen({
    super.key,
    required this.source,
    required this.series,
    required this.line,
    required this.startIndex,
    required this.adapter,
    this.resolvePlay,
    this.loadDanmaku,
    this.onSendDanmaku,
  });

  final SourceConfig source;
  final UnifiedSeries series;
  final PlayLine line;
  final int startIndex;
  final SourceAdapter adapter;
  final EpisodePlayResolver? resolvePlay;
  final Future<List<DanmakuItem>> Function(UnifiedEpisode episode)? loadDanmaku;

  /// 发送弹幕钩子（B 站源提供；null = 不显示发送入口）。返回当前分集 URL。
  final Future<void> Function(UnifiedEpisode episode, String msg)? onSendDanmaku;

  @override
  State<SourcePlayerScreen> createState() => _SourcePlayerScreenState();
}

class _SourcePlayerScreenState extends State<SourcePlayerScreen> {
  late final PlayerEngine _engine;
  int _index = 0;

  /// 当前线路（失败自动换线：先线路后交还上层换源）。
  int _lineIndex = 0;
  int _autoSwitchCount = 0;
  bool _proxyUsed = false;
  bool _directRetried = false;
  String? _error;

  /// 解析接口的提示（如「高清需登录」）：只做轻提示，复用失败面板会误报。
  String? _notice;
  bool _loading = true;

  /// 本次播放请求代号：切集/换线后，旧请求的 await 结果一律丢弃。
  int _openEpoch = 0;

  /// 是否持有 MediaProxy 引用；成对 acquire/release，最多持有 1 份。
  bool _proxyRef = false;

  /// dispose 里不能再查 context，store 引用在首次使用时缓存。
  late final HistoryStore _history = AppScope.read(context).history;
  late final SourceHealthStore _health = AppScope.read(context).sourceHealth;

  PlayLine get _line {
    final lines = widget.series.lines;
    return lines[_lineIndex.clamp(0, lines.length - 1)];
  }

  /// 换线后线路长度可能不同：所有取集的地方一律走这里，避免用已过期的
  /// `widget.line.episodes.length` 造成 RangeError。
  UnifiedEpisode get _episode {
    final eps = _line.episodes;
    if (eps.isEmpty) return UnifiedEpisode(title: '', url: '', index: 0);
    return eps[_index.clamp(0, eps.length - 1)];
  }

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  List<DanmakuItem> _danmaku = const [];
  bool _danmakuEnabled = true;
  bool _playing = false;
  bool _buffering = false;
  bool _showControls = true;
  Timer? _hideTimer;
  Timer? _historyTimer;

  /// 字幕时差（秒）。按剧记忆（historyKey），面板调整后持久化。
  double _subDelay = 0;

  /// 音轨/字幕选择按剧记忆（面板展示序；字幕 -1=关闭）。
  int? _prefAudioIndex;
  int? _prefSubtitleIndex;
  String? _prefAudioKey;
  String? _prefSubtitleKey;
  bool _trackPrefApplied = false;
  StreamSubscription? _tracksSub;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _completedSub;
  StreamSubscription<bool>? _bufferingSub;

  /// mpv 的 403 / 404 / 协议不支持 / 解码失败不会让 `open()` 抛异常，只走
  /// error stream。不订阅就会「黑屏转圈但 UI 显示播放中」，失败链永不触发。
  StreamSubscription<String>? _errorSub;

  /// 当前一次打开尝试的上下文：error stream 回调靠它复用同一条失败链。
  ResolvedPlayback? _attemptPlayback;
  bool _attemptForceDirect = false;
  String _attemptStage = '';
  bool _playingConfirmed = false;

  /// 同一 epoch 只处理一次失败（catch 与 error stream 可能同时到达）。
  int _failureHandledEpoch = -1;

  /// mpv 在开播阶段常先报一条非致命错误（某个分片 / 音轨 / 广告段失败后
  /// 回退），主画面随后仍能出画。给一个宽限期，期间出画就撤销失败判定，
  /// 避免「正在正常播放却弹播放失败」。
  Timer? _errorGraceTimer;

  /// 是否已经有可见播放进度：区分「真的打不开」与「运行期非致命错误」。
  bool get _isVisiblyPlaying => hasVisiblePlayback(
        playingConfirmed: _playingConfirmed,
        playing: _playing,
        position: _position,
        buffering: _buffering,
      );

  @override
  void initState() {
    super.initState();
    _lineIndex = widget.series.lines.indexOf(widget.line);
    if (_lineIndex < 0) _lineIndex = 0;
    _index = widget.startIndex.clamp(0, _line.episodes.length - 1);
    _engine = MpvPlayerEngine();
    // 字幕时差按剧记忆：开播即注入（面板调整会实时覆盖）。
    _subDelay = (_history
                .entries
                .where((h) => h.seriesId == widget.series.historyKey)
                .firstOrNull
                ?.subtitleDelayMs ??
            0) /
        1000.0;
    if (_subDelay != 0) {
      // ignore: discarded_futures
      _engine.setProperty('sub-delay', '$_subDelay');
    }
    // 轨道偏好：读记忆 + 就绪事件驱动应用。
    final histEntry = _history
        .entries
        .where((h) => h.seriesId == widget.series.historyKey)
        .firstOrNull;
    _prefAudioIndex = histEntry?.audioTrackIndex;
    _prefSubtitleIndex = histEntry?.subtitleTrackIndex;
    _prefAudioKey = (histEntry?.audioTrackKey ?? '').isEmpty
        ? null
        : histEntry!.audioTrackKey;
    _prefSubtitleKey = (histEntry?.subtitleTrackKey ?? '').isEmpty
        ? null
        : histEntry!.subtitleTrackKey;
    _tracksSub = _engine.stream.tracks.listen((_) => _applyTrackPreference());
    _errorSub = _engine.stream.error.listen((message) {
      if (message.isEmpty) return;
      final playback = _attemptPlayback;
      if (playback == null || !_isCurrentOpen(_openEpoch)) return;
      // 已经出画 / 有播放进度 / 正在缓冲 → 只是运行期非致命错误（分片、
      // 字幕、音轨回退等），只留痕，绝不弹失败面板、绝不换线。
      if (_isVisiblyPlaying) {
        ErrorLog.instance.record(
            '源播放运行期错误(${_diagLabel(playback, '运行期')})',
            message,
            StackTrace.current);
        _errorGraceTimer?.cancel();
        _errorGraceTimer = null;
        return;
      }
      // 开播阶段：mpv 可能先报错再自行回退成功。延迟判定，期间出画即撤销。
      final epoch = _openEpoch;
      final forceDirect = _attemptForceDirect;
      final stage = _attemptStage;
      _errorGraceTimer?.cancel();
      _errorGraceTimer = Timer(playbackErrorGrace, () {
        if (!mounted || !_isCurrentOpen(epoch)) return;
        if (_isVisiblyPlaying) return;
        unawaited(_handleFailure(message, StackTrace.current,
            epoch: epoch,
            playback: playback,
            forceDirect: forceDirect,
            stage: stage));
      });
    });
    castController.onRemoteStopped = (device, position) {
      if (!mounted) return;
      final behavior =
          AppScope.read(context).settings.castDisconnectBehavior;
      if (behavior != 'resumeLocal') return;
      if (position > Duration.zero) {
        _engine.seek(position);
      }
      _engine.play();
      setState(() {});
    };
    _open();
    _historyTimer = Timer.periodic(
        const Duration(seconds: 5), (_) => _recordHistory(finished: false));
  }

  @override
  void dispose() {
    castController.onRemoteStopped = null;
    _recordHistory(finished: false);
    _stopCastRelay();
    unawaited(_releaseProxy());
    _historyTimer?.cancel();
    _hideTimer?.cancel();
    _tracksSub?.cancel();
    _errorSub?.cancel();
    _errorGraceTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    _engine.dispose();
    super.dispose();
  }

  /// 这次打开是否仍然有效：页面还在，且没有被更晚的打开顶掉。
  bool _isCurrentOpen(int epoch) => mounted && epoch == _openEpoch;

  /// 本地播放与投屏共用同一份解析结果，杜绝「APP 内 403、投屏却能播」的
  /// 链路分叉。两条路径都必须从这里取 url 与 headers。
  ResolvedPlayback _playback(UnifiedEpisode ep,
          {required bool adFilterEnabled}) =>
      resolvePlayback(
        rawUrl: ep.url,
        sourceHeaders: widget.source.headers,
        adFilterEnabled: adFilterEnabled,
        baseUrl: widget.source.api,
      );

  /// 去广告代理启用前的轻量探测：只取前 16 字节，任何失败都直接走直链。
  /// 探测本身绝不能阻断播放。
  Future<bool> _probeProxy(ResolvedPlayback playback) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      final req = await client.getUrl(Uri.parse(playback.url));
      playback.headers.forEach((k, v) => req.headers.set(k, v));
      req.headers.set('Range', 'bytes=0-16');
      final res = await req.close().timeout(const Duration(seconds: 3));
      await res.drain();
      return res.statusCode >= 200 && res.statusCode < 400;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// [fresh] = 一次全新的播放请求（换集 / 重试 / 用户主动换线路）。
  /// 递归回退（代理→直链、换线）必须传 false，否则会把回退额度重置成死循环。
  Future<void> _open({bool forceDirect = false, bool fresh = true}) async {
    if (fresh) {
      // 旧实现从不复位这三个状态：第一集代理失败后，后续每集仍走代理却
      // 不再回退直链，换线额度耗尽后任何失败直接终态 —— 表现为「第一集能播，
      // 之后全播不出来」。
      _directRetried = false;
      _autoSwitchCount = 0;
      _proxyUsed = false;
      _failureHandledEpoch = -1;
    }
    _errorGraceTimer?.cancel();
    _errorGraceTimer = null;
    final epoch = ++_openEpoch;
    _playingConfirmed = false;
    _attemptForceDirect = forceDirect;
    _attemptStage = '探测';
    final ep = _episode;
    if (ep.url.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '该分集没有播放地址，请换线路或换源';
        });
      }
      return;
    }
    // async 间隙不再读 context：开头一次性取好。
    final scope = AppScope.read(context);
    final jxParses = scope.marketSites.parses;
    final playback =
        _playback(ep, adFilterEnabled: scope.settings.sourcesAdFilter);
    _attemptPlayback = playback;
    // 默认路径 = 直链 + mpv 双保险头注入。去广告代理只在「用户开启 + 是 HLS
    // + 上游探测通过 + 本集还没试过直链回退」时启用。
    var wantProxy = !forceDirect &&
        !_directRetried &&
        widget.resolvePlay == null &&
        widget.source.kind != SourceKind.spider &&
        playback.needsProxy;
    if (wantProxy && !await _probeProxy(playback)) wantProxy = false;
    if (!_isCurrentOpen(epoch)) return;
    if (!wantProxy) {
      _proxyUsed = false;
      await _releaseProxy();
    }
    setState(() {
      _loading = true;
      _error = null;
      _notice = null;
    });
    try {
      var url = ep.url;
      String? audioUrl;
      List<DanmakuItem> danmaku = const [];
      // 播放时解析钩子（B 站等 DASH 双轨源）。
      if (widget.resolvePlay != null) {
        final resolved = await widget.resolvePlay!(ep);
        if (!_isCurrentOpen(epoch)) return;
        // resolved 携带的提示只进状态条，无需 context。
        url = resolved.videoUrl;
        audioUrl = resolved.audioUrl;
        if (resolved.notice != null) {
          // 解析提示（如「高清需登录」）不是播放失败，只走轻提示条。
          setState(() => _notice = resolved.notice);
        }
        if (widget.loadDanmaku != null) {
          try {
            danmaku = await widget.loadDanmaku!(ep);
          } catch (_) {
            danmaku = const [];
          }
          if (!_isCurrentOpen(epoch)) return;
        }
      }
      if (wantProxy) {
        _attemptStage = '代理';
        // 必须先 acquire 才能 wrap：wrap 直接读已监听端口的 server.port。
        await _acquireProxy();
        if (!_isCurrentOpen(epoch)) return;
        url = MediaProxy.instance.wrap(url, headers: playback.headers);
        _proxyUsed = true;
      }
      // 音轨分离：mpv audio-files 选项在 loadfile 前设置才生效。
      _attemptStage = '初始化';
      await _engine.initialize();
      if (!_isCurrentOpen(epoch)) return;
      // Media(httpHeaders:) 在部分平台不落到 libmpv 请求上（防盗链源全 403），
      // 补 http-header-fields / user-agent 原生属性做双保险。
      _attemptStage = '头注入';
      await MpvHeaders.install(_engine, playback.headers);
      if (!_isCurrentOpen(epoch)) return;
      await _engine.setProperty('audio-files', audioUrl ?? '');
      if (!_isCurrentOpen(epoch)) return;
      // jx：非直链地址先走解析接口（配置里的 type=1 parse）。
      if (!ParseEngine.isDirectMedia(url)) {
        _attemptStage = '解析';
        if (jxParses.isEmpty) {
          ErrorLog.instance.record(
              _diagLabel(playback, '无解析接口'),
              '该地址不是媒体直链且没有配置 jx 解析接口，请到源市场扫描或粘贴带 parses 的配置',
              StackTrace.current);
        } else {
          final parsed = await ParseEngine().resolve(url, parses: jxParses);
          if (!_isCurrentOpen(epoch)) return;
          if (parsed != null) {
            url = parsed.url;
          } else {
            ErrorLog.instance.record(
                _diagLabel(playback, '解析失败'),
                '全部 ${jxParses.length} 个解析接口均失败，仍尝试原地址',
                StackTrace.current);
          }
        }
      }
      _attemptStage = '打开';
      await _engine.open(Media(url, httpHeaders: playback.headers));
      if (!_isCurrentOpen(epoch)) return;
      _subscribe();
      _danmaku = danmaku;
      setState(() {
        _loading = false;
        _error = null;
      });
      _armHideTimer();
      _recordHistory(finished: false);
    } catch (e, stack) {
      await _handleFailure(e, stack,
          epoch: epoch,
          playback: playback,
          forceDirect: forceDirect,
          stage: _attemptStage);
    }
  }

  /// 播放失败的单一入口：catch 与 mpv error stream 共用，保证任何失败都会
  /// 走「代理→直链→换线→终态」的完整恢复链并落盘诊断。
  Future<void> _handleFailure(
    Object error,
    StackTrace stack, {
    required int epoch,
    required ResolvedPlayback playback,
    required bool forceDirect,
    required String stage,
  }) async {
    if (!_isCurrentOpen(epoch)) return;
    if (_failureHandledEpoch == epoch) return;
    _failureHandledEpoch = epoch;
    ErrorLog.instance.record(_diagLabel(playback, stage), error, stack);
    // 已经在出画（有进度 / playing / 缓冲中）：把画面换成失败面板是错的，
    // 这类错误只留日志。真正的「打不开」在宽限期结束时仍无进度才走到这里。
    if (_isVisiblyPlaying) return;
    // 代理路径失败：回退直链重试一次；必须显式绕过代理，否则会再炸一次。
    if (_proxyUsed && !_directRetried) {
      _directRetried = true;
      _proxyUsed = false;
      await _releaseProxy();
      await _open(forceDirect: true, fresh: false);
      return;
    }
    // 自动换线：同源还有下一条线路就切过去重试。
    final lines = widget.series.lines;
    if (_autoSwitchCount < lines.length - 1 && _lineIndex + 1 < lines.length) {
      _autoSwitchCount++;
      setState(() {
        _lineIndex++;
        _index = 0;
      });
      await _open(forceDirect: forceDirect, fresh: false);
      return;
    }
    // 终态失败才写健康分：换线优先级与冷却都依赖失败计数。
    await _health.recordFailure(widget.source.id, '$error', playFailure: true);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _playing = false;
      _error = '播放失败（$stage）。可点「重试」或「换线路」；'
          '若仍失败请到「我的 → 关于」复制错误日志';
      _notice = null;
    });
  }

  /// 出画后撤销宽限期内的待定失败，并清掉可能已显示的误报面板。
  void _clearPendingFailure() {
    _errorGraceTimer?.cancel();
    _errorGraceTimer = null;
    if (_error != null && mounted) {
      setState(() => _error = null);
    }
  }

  String _diagLabel(ResolvedPlayback playback, String stage) =>
      '源播放[${widget.source.name}/${widget.series.title}/${_line.name}/'
      '${_episode.title}/$stage/${playback.diagnostic}/'
      '${_proxyUsed ? 'proxy' : 'direct'}]';

  Future<void> _acquireProxy() async {
    if (_proxyRef) return;
    await MediaProxy.instance.acquire();
    _proxyRef = true;
  }

  Future<void> _releaseProxy() async {
    if (!_proxyRef) return;
    _proxyRef = false;
    await MediaProxy.instance.release();
  }

  /// B 站等 resolvePlay 分支仍用源级头（不经过 resolvePlayback 的 HLS 判定）。
  Map<String, String> _headers() {
    final h = Map.of(widget.source.headers);
    if (headerOf(h, 'user-agent') == null) {
      h['User-Agent'] = SourceImporter.defaultUa;
    }
    return h;
  }

  /// 投屏用的「防盗链信号头」：与本地播放共用同一份 [ResolvedPlayback]。
  Map<String, String> _castHeaders(ResolvedPlayback playback) =>
      castHeadersOf(playback);

  /// 应用按剧轨道偏好（stream.tracks 驱动，每集一次；序号越界保持默认）。
  void _applyTrackPreference() {
    if (_trackPrefApplied || !mounted) return;
    final tracks = _engine.state.tracks;
    final audio =
        tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
    final subs =
        tracks.subtitle.where((t) => t.id != 'auto' && t.id != 'no').toList();
    if (_prefAudioIndex == null &&
        _prefSubtitleIndex == null &&
        (_prefAudioKey ?? '').isEmpty &&
        (_prefSubtitleKey ?? '').isEmpty) {
      _trackPrefApplied = true;
      return;
    }
    if (audio.isEmpty && subs.isEmpty) return; // 轨道事件未到
    _trackPrefApplied = true;
    final audioTarget = _resolveTrackTarget(
        _prefAudioIndex, _prefAudioKey, audio, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    final subTarget = _resolveTrackTarget(
        _prefSubtitleIndex, _prefSubtitleKey, subs, (t) => TrackPreference.stableTrackKey(
            language: t.language, title: t.title));
    if (audioTarget != null) {
      unawaited(_engine.setAudioTrack(audio[audioTarget]));
    }
    if (_prefSubtitleIndex == TrackPreference.subtitleOff) {
      unawaited(_engine.setSubtitleTrack(SubtitleTrack.no()));
    } else if (subTarget != null) {
      unawaited(_engine.setSubtitleTrack(subs[subTarget]));
    }
  }

  /// 轨道目标解析（Pathfin 语义）：稳定身份键**唯一命中**优先——命中多条
  /// 宁可保持默认（不错配语言）；键缺失/失配时序号在界内兜底。
  static int? _resolveTrackTarget(
    int? index,
    String? key,
    List<dynamic> tracks,
    String? Function(dynamic track) keyOf,
  ) {
    final keys = [for (final t in tracks) keyOf(t)];
    if (key != null && key.isNotEmpty) {
      final unique = TrackPreference.uniqueMatchIndex(key, keys);
      if (unique != null) return unique;
    }
    if (index != null && index >= 0 && index < tracks.length) return index;
    return null;
  }

  void _subscribe() {
    _trackPrefApplied = false;
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _completedSub?.cancel();
    _bufferingSub?.cancel();
    _posSub = _engine.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
      // 有播放进度 = 已经出画：撤销待定的失败判定与已误报的面板。
      if (p > Duration.zero) _clearPendingFailure();
    });
    _durSub = _engine.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _playingSub = _engine.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() {
        _playing = v;
        if (v) {
          _loading = false;
          // 出画即撤销失败面板（非致命错误曾被误报成「播放失败」）。
          _error = null;
        }
      });
      if (v) _clearPendingFailure();
      if (v && !_playingConfirmed) {
        _playingConfirmed = true;
        // 真正出画才记成功，对冲终态 recordFailure 造成的健康分单调下降。
        unawaited(_health.recordSuccess(widget.source.id, 0).catchError((_) {}));
      }
    });
    _bufferingSub = _engine.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _buffering = v);
    });
    _completedSub = _engine.stream.completed.listen((completed) {
      if (!mounted || !completed) return;
      _recordHistory(finished: true);
      if (_index < _line.episodes.length - 1) {
        setState(() => _index++);
        _open();
      }
    });
  }

  Future<void> _recordHistory({required bool finished}) async {
    final ep = _episode;
    await _history.record(
      seriesId: widget.series.historyKey,
      title: widget.series.title,
      coverUrl: widget.series.coverUrl,
      episode: ep.index,
      episodes: _line.episodes.length,
      episodeId: ep.url,
      // HistoryStore 的 position 单位是秒（resumable 阈值 15），不是毫秒。
      position: _position.inMilliseconds / 1000.0,
      finished: finished,
      sourceKey: widget.source.id,
      // 详情接口挂掉时的兜底直链（spider 源这里是令牌，仍按原样存）。
      playUrl: ep.url,
    );
  }

  Future<void> _showDanmakuBlockDialog() async {
    final scope = AppScope.read(context);
    final controller =
        TextEditingController(text: scope.settings.biliDanmakuBlock);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('弹幕屏蔽词'),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: '逗号分隔；re: 前缀按正则（如 re:广告|剧透）',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消')),
          FilledButton(
              onPressed: () {
                scope.settings.biliDanmakuBlock = controller.text.trim();
                Navigator.pop(context);
              },
              child: const Text('保存')),
        ],
      ),
    );
  }

  Future<void> _showDanmakuSender(UnifiedEpisode ep) async {
    final controller = TextEditingController();
    final sent = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('发弹幕 · ${ep.title}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 100,
          decoration: const InputDecoration(hintText: '说点什么…', border: OutlineInputBorder()),
          onSubmitted: (v) => Navigator.pop(context, v.trim().isNotEmpty),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text.trim().isNotEmpty),
              child: const Text('发送')),
        ],
      ),
    );
    if (sent != true || !mounted) return;
    try {
      await widget.onSendDanmaku!(ep, controller.text.trim());
      if (!mounted) return;
      setState(() => _osdMessage('弹幕已发送'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _osdMessage('发送失败：$e'));
    }
  }

  void _osdMessage(String text) {
    setState(() => _error = null);
    ScaffoldMessenger.maybeOf(context)
        ?.showSnackBar(SnackBar(content: Text(text), duration: const Duration(seconds: 2)));
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showControls = false);
    });
  }

  // ---------- 投屏（DLNA 发送端） ----------

  /// 投屏中继会话（B 站等 DASH 双轨源：castrelay 合流音视频转 HLS）。
  /// [_castRelayApi] 随会话存引用：dispose 里读不到 context 也能回收。
  String? _castRelaySession;
  AquaApi? _castRelayApi;

  /// 解析某一集的可投媒体：resolvePlay 源（B 站 DASH 双轨）→ castRelay 合流
  /// （ffmpeg 带 Referer/UA），中继失败回退直投原始 URL（M1-6 / AC-21，
  /// 不再让「该集没有可投的流」终结投屏）；普通源直链（防盗链信号头经手机代理）。
  /// [scope] 由调用方捕获（闭包异步内不摸 context）。
  Future<CastMedia?> _resolveCastMedia(UnifiedEpisode ep, int index, AppScope scope) async {
    final title = '${widget.series.title} · ${ep.title}';
    if (widget.resolvePlay != null) {
      final ResolvedPlay resolved;
      try {
        resolved = await widget.resolvePlay!(ep);
      } on Exception {
        return null; // 解析失败：没有可直投的地址（本轮连投终止）。
      }
      if (resolved.videoUrl.isEmpty) return null;
      final h = _headers();
      // 换集连投：停旧中继再起新中继。
      final oldSession = _castRelaySession;
      _castRelaySession = null;
      if (oldSession != null) {
        try {
          await scope.api.castRelayStop(oldSession);
        } catch (_) {}
      }
      final result = await castMediaViaRelayOrDirect(
        title: title,
        directUrl: resolved.videoUrl,
        startRelay: () async {
          final relay = await scope.api.castRelayStart(
            url: resolved.videoUrl,
            audioUrl: resolved.audioUrl ?? '',
            userAgent: headerOf(h, 'user-agent') ?? '',
            referer: headerOf(h, 'referer') ?? '',
          );
          _castRelayApi = scope.api;
          _castRelaySession = relay['session'] as String?;
          // M0-5：跟随中继取流日志进诊断（探针在会话回收时自停）。
          final session = _castRelaySession;
          if (session != null) {
            CastRelayProbe.instance.watch(scope.api.castRelayStatus, session);
          }
          return relay['url'] as String?;
        },
        episodeIndex: ep.index,
        episodeCount: _line.episodes.length,
        // 播放器手里有时长才传真实值（AC-27）；换集连投拿不到下一集时长。
        duration: index == _index && _duration > Duration.zero
            ? _duration
            : null,
        onRelayError: (e, st) =>
            ErrorLog.instance.record('投屏中继回退直投', e, st),
      );
      if (result == null) return null;
      final (media, viaRelay) = result;
      if (!viaRelay && mounted) {
        _osdMessage('已改为直投，部分格式电视可能不支持');
      }
      return media;
    }
    // 与 _open 共用同一份解析结果：URL 与 headers 口径完全一致。
    final playback =
        _playback(ep, adFilterEnabled: scope.settings.sourcesAdFilter);
    return CastMedia(
      url: playback.url,
      title: title,
      position: index == _index ? _position : Duration.zero,
      episodeIndex: ep.index,
      episodeCount: _line.episodes.length,
      headers: _castHeaders(playback),
      mimeHint: playback.mimeType,
      duration:
          index == _index && _duration > Duration.zero ? _duration : null,
      // M5-2 字幕接线点：CMS/spider 源目前不提供外挂字幕 URL，源无字幕就
      // 不传（DIDL 不写字幕标签、不制造噪声）；源补齐外挂字幕数据后在此
      // 传入 CastMedia.subtitleUrl 即全链路生效。
    );
  }

  void _stopCastRelay() {
    final session = _castRelaySession;
    _castRelaySession = null;
    CastRelayProbe.instance.unwatch();
    final api = _castRelayApi;
    if (session != null && api != null) {
      api.castRelayStop(session).catchError((_) {});
    }
  }

  Future<void> _openCastSheet() async {
    final ep = _episode;
    final scope = AppScope.read(context);
    // M4-1（安卓低风险确定项）：发起投屏前先暂停本地解码——resolvePlay 源
    // 在下方就会 castRelayStart（ffmpeg 起解），libmpv 不再同时解码同一路流，
    // 避免双解码叠加内存峰值。原实现是投屏成功（面板 'started'）后才 pause。
    // 解析失败或用户取消投屏时在下方恢复播放。
    _engine.pause();
    final media = await _resolveCastMedia(ep, _index, scope);
    if (media == null || !mounted) {
      if (mounted && media == null) {
        // 没有进入投屏面板：恢复发起前暂停的本地播放（M4-1）。
        await _engine.play();
        if (mounted) setState(() {});
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('该集没有可投屏的流（解析或中继失败）'),
          duration: Duration(seconds: 2),
        ));
      }
      return;
    }
    // 连播：电视端播完自动投下一集（捕获发起时的集数下标）。
    final castIndex = _index;
    // M5-0：兼容模式选路的本机转码执行体（Go castRelayStart 适配器）。
    // 中继会话沿用 _castRelaySession 生命周期（停旧 → 起新 → 断开回收）。
    castController.transcodeResolver = (m) async {
      final oldSession = _castRelaySession;
      _castRelaySession = null;
      if (oldSession != null) {
        try {
          await scope.api.castRelayStop(oldSession);
        } catch (_) {}
      }
      final relay = await scope.api.castRelayStart(
        url: m.url,
        userAgent: headerOf(m.headers, 'user-agent') ?? '',
        referer: headerOf(m.headers, 'referer') ?? '',
      );
      _castRelayApi = scope.api;
      _castRelaySession = relay['session'] as String?;
      // M0-5：跟随中继取流日志进诊断（探针在会话回收时自停）。
      final session = _castRelaySession;
      if (session != null) {
        CastRelayProbe.instance.watch(scope.api.castRelayStatus, session);
      }
      return relay['url'] as String?;
    };
    castController.onNextEpisode = () async {
      final n = castIndex + 1;
      if (n >= _line.episodes.length) return null;
      return _resolveCastMedia(_line.episodes[n], n, scope);
    };
    final result = await showCastSheet(
      context,
      media: media,
      onLocalPause: () => _engine.pause(),
    );
    if (!mounted || result == null) {
      // 发起前暂停了本地解码（M4-1）：取消投屏即恢复本地播放。
      if (mounted && result == null) {
        await _engine.play();
        if (mounted) setState(() {});
      }
      return;
    }
    if (result == 'disconnect') {
      final position = await castController.disconnect();
      _stopCastRelay();
      if (!mounted) return;
      final behavior =
          AppScope.read(context).settings.castDisconnectBehavior;
      if (behavior == 'resumeLocal' && position > Duration.zero) {
        await _engine.seek(position);
        await _engine.play();
        if (mounted) setState(() {});
      }
    }
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _armHideTimer();
  }

  Future<void> _switchEpisode(int index) async {
    final eps = _line.episodes;
    final maxIndex = eps.isEmpty ? 0 : eps.length - 1;
    setState(() => _index = index.clamp(0, maxIndex));
    await _open();
  }

  /// 用户主动换线路：不占用自动换线额度，且按 fresh 复位所有回退状态。
  Future<void> _retryNextLine() async {
    final lines = widget.series.lines;
    if (lines.isEmpty) return;
    setState(() {
      _lineIndex = (_lineIndex + 1) % lines.length;
      _index = 0;
    });
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    final ep = _episode;
    // 桌面端 Esc/Backspace 返回：AppBar 只在控件条显示时可见，
    // 没有键盘出口的话全屏播 B 站视频就"退不出来"。
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.escape ||
                event.logicalKey == LogicalKeyboardKey.backspace)) {
          Navigator.maybePop(context);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
      backgroundColor: Colors.black,
      appBar: _showControls
          ? AppBar(
              backgroundColor: Colors.black54,
              foregroundColor: Colors.white,
              title: Text('${widget.series.title} · ${ep.title}',
                  style: const TextStyle(fontSize: 16)),
              actions: [
                IconButton(
                  tooltip: '音轨 / 字幕',
                  icon: const Icon(Icons.subtitles_outlined),
                  onPressed: () {
                    showPlayerTracksSheet(context, _engine,
                      initialSubtitleDelay: _subDelay,
                      onAudioTrackSelected: (idx, key) async {
                        setState(() {
                          _prefAudioIndex = idx;
                          _prefAudioKey = key.isEmpty ? null : key;
                        });
                        try {
                          await _history.setPlaybackPrefs(
                            seriesId: widget.series.historyKey,
                            audioTrackIndex: idx,
                            audioTrackKey: key,
                          );
                        } catch (_) {}
                      },
                      onSubtitleTrackSelected: (idx, key) async {
                        setState(() {
                          _prefSubtitleIndex = idx;
                          _prefSubtitleKey = key.isEmpty ? null : key;
                        });
                        try {
                          await _history.setPlaybackPrefs(
                            seriesId: widget.series.historyKey,
                            subtitleTrackIndex: idx,
                            subtitleTrackKey: key,
                          );
                        } catch (_) {}
                      },
                      onSubtitleDelayChanged: (delayMs) async {
                        setState(() => _subDelay = delayMs / 1000.0);
                        try {
                          await _history.setPlaybackPrefs(
                            seriesId: widget.series.historyKey,
                            subtitleDelayMs: delayMs.round(),
                          );
                        } catch (_) {}
                      });
                  },
                ),
                ListenableBuilder(
                  listenable: castController,
                  builder: (context, _) => IconButton(
                    tooltip: '投屏',
                    icon: Icon(castController.isCasting
                        ? Icons.cast_connected
                        : Icons.cast_outlined),
                    onPressed: _openCastSheet,
                  ),
                ),
              ],
            )
          : null,
      body: GestureDetector(
        onTap: _toggleControls,
        child: Stack(
          children: [
            Center(
              child: Video(controller: _engine.videoController),
            ),
            Positioned.fill(
              child: DanmakuOverlay(
                items: _danmaku,
                position: _position,
                enabled: _danmakuEnabled && _playing,
              ),
            ),
            // 常驻悬浮返回：AppBar 只在控件条显示时出现，控件条 4 秒自动隐藏
            // 后用户找不到返回（B站播放退不出的主诉）。这个按钮不随控件隐藏。
            Positioned(
              top: 10,
              left: 10,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => Navigator.of(context).maybePop(),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.arrow_back,
                        color: Colors.white, size: 22),
                  ),
                ),
              ),
            ),
            // 常驻悬浮投屏：控件条隐藏后顶栏的投屏按钮会一起消失（实测主诉），
            // 这里补一个不随控件隐藏的入口；控件显示时由顶栏那个负责，不重复。
            if (!_showControls)
              Positioned(
                top: 10,
                right: 10,
                child: CastFabButton(onPressed: _openCastSheet),
              ),
            if (_loading)
              const Center(child: AppLoading()),
            // 解析提示只是信息条，不用失败面板；可手动关闭。
            if (_notice != null)
              Positioned(
                top: 56,
                left: 16,
                right: 16,
                child: SafeArea(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(_notice!,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12)),
                        ),
                        InkWell(
                          onTap: () => setState(() => _notice = null),
                          child: const Icon(Icons.close,
                              size: 16, color: Colors.white54),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            // 双保险：只要已经出画，就不再把失败面板盖到画面上。
            if (_error != null && !_isVisiblyPlaying)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        FilledButton.tonal(
                          onPressed: _open,
                          child: const Text('重试'),
                        ),
                        OutlinedButton(
                          onPressed: _retryNextLine,
                          child: const Text('换线路'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            if (_showControls) ...[
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  color: Colors.black54,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              icon: Icon(_playing
                                  ? Icons.pause
                                  : Icons.play_arrow),
                              color: Colors.white,
                              tooltip: _playing ? '暂停' : '播放',
                              onPressed: () => _engine.playOrPause(),
                            ),
                            Text(
                              '${_format(_position)} / ${_format(_duration)}',
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 12),
                            ),
                            const Spacer(),
                            if (_buffering)
                              const AppLoading.inline(),
                            if (widget.onSendDanmaku != null)
                              IconButton(
                                tooltip: '发弹幕',
                                icon: const Icon(Icons.edit_note,
                                    color: Colors.white),
                                onPressed: () => _showDanmakuSender(ep),
                              ),
                            GestureDetector(
                              onLongPress: _showDanmakuBlockDialog,
                              child: ListenableBuilder(
                                listenable: castController,
                                builder: (context, _) => IconButton(
                                  tooltip:
                                      '关闭/开启弹幕（长按设置屏蔽词）',
                                  icon: Icon(
                                    Icons.subtitles_outlined,
                                    color: _danmakuEnabled
                                        ? Colors.white
                                        : Colors.white38,
                                  ),
                                  onPressed: () => setState(
                                      () => _danmakuEnabled = !_danmakuEnabled),
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: '上一集',
                              icon: const Icon(Icons.skip_previous,
                                  color: Colors.white),
                              onPressed: _index > 0
                                  ? () => _switchEpisode(_index - 1)
                                  : null,
                            ),
                            IconButton(
                              tooltip: '下一集',
                              icon: const Icon(Icons.skip_next,
                                  color: Colors.white),
                              onPressed:
                                  _index < _line.episodes.length - 1
                                      ? () => _switchEpisode(_index + 1)
                                      : null,
                            ),
                          ],
                        ),
                        SizedBox(
                          height: 28,
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 3,
                              thumbShape: const RoundSliderThumbShape(
                                  enabledThumbRadius: 6),
                            ),
                            child: Slider(
                              value: _duration.inMilliseconds <= 0
                                  ? 0
                                  : _position.inMilliseconds
                                      .clamp(0, _duration.inMilliseconds)
                                      .toDouble(),
                              max: _duration.inMilliseconds
                                      .toDouble()
                                      .clamp(1, double.maxFinite),
                              onChanged: (v) {
                                _engine.seek(Duration(milliseconds: v.toInt()));
                              },
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 36,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (final e in _line.episodes)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: e.index == ep.index
                                      ? FilledButton.tonal(
                                          onPressed: () {},
                                          child: Text(e.title,
                                              style: const TextStyle(
                                                  fontSize: 12)))
                                      : OutlinedButton(
                                          onPressed: () =>
                                              _switchEpisode(e.index - 1),
                                          child: Text(e.title,
                                              style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.white70)),
                                        ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }

  String _format(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
