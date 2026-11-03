import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/player/player_engine.dart';
import '../core/cast/cast_controller.dart';
import '../core/aqua_api.dart';
import '../core/bili/api.dart';
import '../core/error_log.dart';
import '../core/next_episode_prompt.dart';
import '../core/player/track_preference.dart';
import '../core/sources/media_proxy.dart';
import '../core/sources/parse_engine.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_import.dart';
import '../store/stores.dart';
import '../widgets/cast_panel.dart';
import '../widgets/player_track_sheet.dart';
import '../widgets/common.dart';
import '../widgets/danmaku_overlay.dart';

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

  /// 下一集提示条（播完前引导；本播放器由 completed 无条件推进，
  /// 提示条取消后拦截该推进，避免「点了取消还自动跳集」）。
  final Set<String> _nextPromptConsumed = {};
  bool _nextPromptVisible = false;
  int _nextPromptRemainingMs = 0;
  Timer? _nextPromptTimer;

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
    _nextPromptTimer?.cancel();
    _tracksSub?.cancel();
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

  Future<void> _open({bool forceDirect = false}) async {
    final epoch = ++_openEpoch;
    _nextPromptConsumed.clear();
    _cancelNextPromptTimer();
    _nextPromptVisible = false;
    final ep = _line.episodes[_index];
    // async 间隙不再读 context：开头一次性取好。
    final jxParses = AppScope.read(context).marketSites.parses;
    final adFilterEnabled = AppScope.read(context).settings.sourcesAdFilter;
    // 去广告代理：CMS 源默认包裹（B 站/红果走 resolvePlay 不经此路径）。
    final wantProxy = !forceDirect &&
        widget.resolvePlay == null &&
        widget.source.kind != SourceKind.spider &&
        adFilterEnabled;
    if (!wantProxy) await _releaseProxy();
    setState(() {
      _loading = true;
      _error = null;
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
          setState(() => _error = resolved.notice);
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
        // 必须先 acquire 才能 wrap：wrap 直接读已监听端口的 server.port。
        await _acquireProxy();
        if (!_isCurrentOpen(epoch)) return;
        url = MediaProxy.instance.wrap(url, headers: _headers());
        _proxyUsed = true;
      }
      // 音轨分离：mpv audio-files 选项在 loadfile 前设置才生效。
      await _engine.initialize();
      if (!_isCurrentOpen(epoch)) return;
      await _engine.setProperty('audio-files', audioUrl ?? '');
      if (!_isCurrentOpen(epoch)) return;
      // jx：非直链地址先走解析接口（配置里的 type=1 parse）。
      if (!ParseEngine.isDirectMedia(url) && jxParses.isNotEmpty) {
        final parsed = await ParseEngine().resolve(url, parses: jxParses);
        if (!_isCurrentOpen(epoch)) return;
        if (parsed != null) url = parsed.url;
      }
      await _engine.open(Media(url, httpHeaders: _headers()));
      if (!_isCurrentOpen(epoch)) return;
      _subscribe();
      _danmaku = danmaku;
      setState(() {
        _loading = false;
        _playing = true;
      });
      _armHideTimer();
      _recordHistory(finished: false);
    } catch (e) {
      ErrorLog.instance.record('源播放', e, StackTrace.current);
      if (!_isCurrentOpen(epoch)) return;
      // 代理路径失败：回退直链重试一次；必须显式绕过代理，否则会再炸一次。
      if (_proxyUsed && !_directRetried) {
        _directRetried = true;
        _proxyUsed = false;
        await _releaseProxy();
        await _open(forceDirect: true);
        return;
      }
      // 自动换线：同源还有下一条线路就切过去重试（xiugou-tv 语义简化版）。
      if (_autoSwitchCount < widget.series.lines.length - 1 &&
          _lineIndex + 1 < widget.series.lines.length) {
        _autoSwitchCount++;
        setState(() {
          _lineIndex++;
          _index = 0;
        });
        await _open(forceDirect: forceDirect);
        return;
      }
      // 终态失败才写健康分：换线优先级与 30 分钟冷却都依赖失败计数。
      await _health.recordFailure(widget.source.id, '$e', playFailure: true);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '播放失败，可回详情页换线路或换源';
      });
    }
  }

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

  Map<String, String> _headers() {
    final h = Map.of(widget.source.headers);
    if (!h.containsKey('User-Agent')) {
      h['User-Agent'] = SourceImporter.defaultUa;
    }
    return h;
  }

  /// 投屏用的「防盗链信号头」：带 Referer 或自定义 UA 的源，电视大概率拉不动，
  /// 经本机代理中转；仅默认 UA 的源直投（保住投屏后手机可离开前台的体验）。
  Map<String, String> _castHeaders() {
    final h = _headers();
    final hasReferer = (h['Referer'] ?? '').trim().isNotEmpty;
    final customUa =
        (h['User-Agent'] ?? '').isNotEmpty && h['User-Agent'] != SourceImporter.defaultUa;
    return (hasReferer || customUa) ? h : const {};
  }

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
      _maybeUpdateNextPrompt(p);
    });
    _durSub = _engine.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _playingSub = _engine.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
    });
    _bufferingSub = _engine.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _buffering = v);
    });
    _completedSub = _engine.stream.completed.listen((completed) {
      if (!mounted || !completed) return;
      _recordHistory(finished: true);
      if (_index < _line.episodes.length - 1) {
        // 提示条被用户取消：本集停在片尾，不再自动跳集。
        if (_nextPromptConsumed.contains('next')) return;
        setState(() => _index++);
        _open();
      }
    });
  }

  /// 下一集提示条：位置事件驱动（出现 / 倒计时 / seek 回退收起）。
  /// 本播放器没有片尾配置，outroConfigured 恒为 false。
  void _maybeUpdateNextPrompt(Duration position) {
    if (!mounted) return;
    if (_nextPromptVisible) {
      final remaining = _duration - position;
      if (remaining <= Duration.zero) return; // 自然播完交给 completed
      if (shouldHideNextPromptOnSeek(
        position: position,
        duration: _duration,
        outroConfigured: false,
      )) {
        _hideNextPrompt(release: true);
      } else {
        setState(() => _nextPromptRemainingMs = remaining.inMilliseconds);
      }
      return;
    }
    final prompt = nextEpisodePrompt(
      position: position,
      duration: _duration,
      hasNext: _index < _line.episodes.length - 1,
      // 本播放器由 completed 无条件推进；提示条仅引导，取消可拦截推进。
      autoNext: false,
      outroConfigured: false,
      consumed: _nextPromptConsumed,
    );
    if (prompt == null) return;
    setState(() {
      _nextPromptVisible = true;
      _nextPromptRemainingMs = prompt.remainingMs;
    });
    _nextPromptTimer = Timer(
      Duration(milliseconds: prompt.remainingMs),
      () {
        if (mounted) _hideNextPrompt();
      },
    );
  }

  void _cancelNextPromptTimer() {
    _nextPromptTimer?.cancel();
    _nextPromptTimer = null;
  }

  void _hideNextPrompt({bool release = false}) {
    _cancelNextPromptTimer();
    if (release) releasePrompt(_nextPromptConsumed);
    _nextPromptVisible = false;
    if (mounted) setState(() {});
  }

  /// 提示条「立即播放」：直接切下一集。
  void _confirmNextPrompt() {
    _cancelNextPromptTimer();
    _nextPromptVisible = false;
    consumePrompt(_nextPromptConsumed);
    _recordHistory(finished: true);
    if (_index < _line.episodes.length - 1) {
      setState(() => _index++);
      _open();
    }
  }

  /// 提示条「取消」：本集不再出现，且自然播完后不再自动跳集。
  void _dismissNextPrompt() {
    consumePrompt(_nextPromptConsumed);
    _hideNextPrompt();
  }

  Future<void> _recordHistory({required bool finished}) async {
    final ep = _line.episodes[_index];
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
    );
  }

  /// 下一集提示条（底部居中；倒计时 + 立即播放 / 取消）。
  Widget _buildNextPromptBar(BuildContext context) {
    final remaining = Duration(milliseconds: _nextPromptRemainingMs);
    final mm = remaining.inMinutes.remainder(60).toString().padLeft(2, '0');
    final ss = remaining.inSeconds.remainder(60).toString().padLeft(2, '0');
    final nextNo = (_index + 2).clamp(1, _line.episodes.length);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: Center(
        child: Material(
          color: Colors.black.withValues(alpha: 0.74),
          borderRadius: BorderRadius.circular(24),
          child: Padding(
            padding: const EdgeInsets.only(left: 14, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.skip_next_rounded,
                    color: Colors.white, size: 18),
                const SizedBox(width: 8),
                Text('即将播放：第 $nextNo 集 · $mm:$ss',
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
                TextButton(
                  onPressed: _confirmNextPrompt,
                  child: const Text('立即播放',
                      style: TextStyle(color: Colors.amberAccent)),
                ),
                TextButton(
                  onPressed: _dismissNextPrompt,
                  child: const Text('取消',
                      style: TextStyle(color: Colors.white70)),
                ),
              ],
            ),
          ),
        ),
      ),
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
  /// （ffmpeg 带 Referer/UA）；普通源直链（防盗链信号头经手机代理）。
  /// [scope] 由调用方捕获（闭包异步内不摸 context）。
  Future<CastMedia?> _resolveCastMedia(UnifiedEpisode ep, int index, AppScope scope) async {
    final title = '${widget.series.title} · ${ep.title}';
    if (widget.resolvePlay != null) {
      try {
        final resolved = await widget.resolvePlay!(ep);
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
        final relay = await scope.api.castRelayStart(
          url: resolved.videoUrl,
          audioUrl: resolved.audioUrl ?? '',
          userAgent: h['User-Agent'] ?? '',
          referer: h['Referer'] ?? '',
        );
        _castRelayApi = scope.api;
        _castRelaySession = relay['session'] as String?;
        return CastMedia(
          url: relay['url'] as String? ?? resolved.videoUrl,
          title: title,
          episodeIndex: ep.index,
          episodeCount: _line.episodes.length,
        );
      } on Exception {
        return null; // 解析/中继失败：本轮连投终止（首次投屏则 UI 报错）。
      }
    }
    return CastMedia(
      url: ep.url,
      title: title,
      position: index == _index ? _position : Duration.zero,
      episodeIndex: ep.index,
      episodeCount: _line.episodes.length,
      headers: _castHeaders(),
    );
  }

  void _stopCastRelay() {
    final session = _castRelaySession;
    _castRelaySession = null;
    final api = _castRelayApi;
    if (session != null && api != null) {
      api.castRelayStop(session).catchError((_) {});
    }
  }

  Future<void> _openCastSheet() async {
    final ep = _line.episodes[_index];
    final scope = AppScope.read(context);
    final media = await _resolveCastMedia(ep, _index, scope);
    if (media == null || !mounted) {
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
    if (!mounted || result == null) return;
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
    setState(() => _index = index.clamp(0, widget.line.episodes.length - 1));
    await _open();
  }

  @override
  Widget build(BuildContext context) {
    final ep = _line.episodes[_index];
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
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        style:
                            const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: _open,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (_nextPromptVisible) _buildNextPromptBar(context),
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
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white70),
                              ),
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
