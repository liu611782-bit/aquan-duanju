/// 接收端播放页（全屏路由）：来投时由 `CastReceiverService.openSessionPage`
/// 打开。画面用独立 media_kit 实例出画（不与本地播放页共用），顶栏显示
/// 「正在接收投屏」+ 投送方 IP/UA，常规控件（播放/暂停/进度/音量）直用引擎。
///
/// 生命周期（R3.4）：
/// - 关闭按钮 / 系统返回 → 引擎 stop（DLNA Stop 语义，状态 STOPPED）→ pop；
///   接收端与 SSDP 广播继续（发端随后会轮询到 STOPPED）；
/// - 新投替换 → `service.session` 通知刷新顶栏，引擎已被渲染器 load 换源，
///   不关页。
///
/// 投送封面（11-07-cast-receiver-advanced §2）：DIDL `upnp:albumArtURI` 提取的
/// [ReceiverSession.albumArtUrl]——视频首帧前（TRANSITIONING/已加载待播）作
/// backdrop（视频起播后被画面自然盖住）；音频投送显示大图 + 标题/投送方信息。
/// 图片加载失败静默（errorBuilder 收起，回现状黑底），不落 ErrorLog。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/castd/receiver_controller.dart';
import '../core/castd/receiver_player_adapter.dart';
import '../core/castd/receiver_player_mediakit.dart';
import '../core/castd/receiver_service.dart';
import '../core/error_log.dart';

export '../core/castd/receiver_controller.dart'
    show receiverCastIsAudio;

/// 全屏路由壳：仅投送会话信息 + 画面 + 控件，无系统栏。
class ReceiverPlayerScreen extends StatefulWidget {
  const ReceiverPlayerScreen({super.key, this.service});

  /// null → 全局单例（widget 测试注入替身）。
  final CastReceiverService? service;

  /// 路由名（main 的 closeSessionPage 用 popUntil 精确关本页）。
  static const String routeName = 'receiver-player';

  @override
  State<ReceiverPlayerScreen> createState() => _ReceiverPlayerScreenState();
}

class _ReceiverPlayerScreenState extends State<ReceiverPlayerScreen> {
  late final CastReceiverService _service =
      widget.service ?? CastReceiverService.instance;

  StreamSubscription<ReceiverPlayerStatus>? _statusSub;
  ReceiverPlayerStatus _status =
      const ReceiverPlayerStatus(transportState: kTransportNoMedia);
  bool _showControls = true;

  /// 引擎只在来投（start 之后）才存在；页面未就绪时给占位状态。
  ReceiverPlayer? get _engineOrNull => _service.controller.playerOrNull;

  /// 仅 media_kit 引擎有画面控制器；stub（测试/异常兜底）为黑底。
  VideoController? get _videoController {
    final engine = _engineOrNull;
    return engine is MediaKitReceiverPlayer ? engine.videoController : null;
  }

  @override
  void initState() {
    super.initState();
    final engine = _engineOrNull;
    if (engine != null) {
      try {
        _status = engine.status();
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·读取引擎状态', e, st);
      }
      _statusSub = engine.statusStream.listen((status) {
        if (!mounted) return;
        setState(() => _status = status);
      });
    }
    _service.session.addListener(_onSessionChanged);
    // 接收端播放页屏幕常亮（R1.5）：与本地播放页同口径（WakelockPlus），
    // 页开着即常亮（接收状态本身就是「正在播放」语义）。
    unawaited(WakelockPlus.enable());
  }

  @override
  void dispose() {
    _service.session.removeListener(_onSessionChanged);
    unawaited(_statusSub?.cancel());
    unawaited(WakelockPlus.disable());
    // 手动关闭（X / 返回）→ Stop 语义：引擎 stop + 状态 STOPPED；
    // SSDP 继续广播（接收开关不动）。异常只进 ErrorLog。
    unawaited(_stopEngineQuietly());
    _service.notifyPageClosed();
    super.dispose();
  }

  void _onSessionChanged() {
    if (!mounted) return;
    // 新投替换：换源由渲染器 load 完成，这里只刷新顶栏并唤出控件。
    setState(() => _showControls = true);
  }

  Future<void> _stopEngineQuietly() async {
    final engine = _engineOrNull;
    if (engine == null) return;
    try {
      await engine.stop();
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·停止引擎', e, st);
    }
  }

  Future<void> _close() async {
    await _stopEngineQuietly();
    if (!mounted) return;
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final session = _service.session.value ?? _service.controller.currentSession;
    final controller = _videoController;
    final albumArt = session?.albumArtUrl ?? '';
    final isAudio = session != null &&
        receiverCastIsAudio(mimeType: session.mimeType, url: session.url);
    // 视频首帧前（加载中 / 已加载待播 / 停止态）显示封面 backdrop；
    // 播放/暂停后画面已出帧（或 letterbox 内被视频覆盖），不再回显。
    final showBackdrop = albumArt.isNotEmpty &&
        (isAudio ||
            _status.transportState == kTransportTransitioning ||
            _status.transportState == kTransportStopped ||
            _status.transportState == kTransportNoMedia);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 封面 backdrop（垫在视频下；视频起播后自然盖住）。
          if (showBackdrop)
            Positioned.fill(child: _albumArtImage(albumArt, BoxFit.cover)),
          Positioned.fill(
            child: controller == null
                ? const SizedBox.expand()
                : Video(
                    controller: controller,
                    controls: NoVideoControls,
                    fit: BoxFit.contain,
                  ),
          ),
          // 音频投送：大图 + 标题/投送方信息（无画面可盖，居中常驻）。
          if (session != null && isAudio)
            Positioned.fill(
              child: IgnorePointer(
                child: _buildAudioCard(context, session, albumArt),
              ),
            ),
          // 点画面切换控件显隐。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _showControls = !_showControls),
            ),
          ),
          if (_showControls)
            _buildTopBar(context, session)
          else
            _buildBadge(context),
          if (_showControls)
            Align(alignment: Alignment.bottomCenter, child: _buildControls()),
        ],
      ),
    );
  }

  /// 封面图：150ms 淡入（仓库 CoverImage 同口径），加载失败静默收起。
  Widget _albumArtImage(String url, BoxFit fit) => Image.network(
        url,
        fit: fit,
        frameBuilder: (context, child, frame, wasSyncLoaded) => wasSyncLoaded
            ? child
            : AnimatedOpacity(
                opacity: frame == null ? 0 : 1,
                duration: const Duration(milliseconds: 150),
                child: child,
              ),
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );

  Widget _buildAudioCard(
    BuildContext context,
    ReceiverSession session,
    String albumArt,
  ) {
    final theme = Theme.of(context);
    final userAgent = session.senderUserAgent;
    final sender =
        '投送方 ${session.senderAddress}${userAgent.isEmpty ? '' : ' · $userAgent'}';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: albumArt.isEmpty
                ? const Icon(
                    Icons.music_note_rounded,
                    size: 72,
                    color: Colors.white38,
                  )
                : _albumArtImage(albumArt, BoxFit.cover),
          ),
          const SizedBox(height: 20),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              children: [
                Text(
                  session.title.trim().isEmpty ? '正在接收投屏' : session.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(color: Colors.white),
                ),
                const SizedBox(height: 6),
                Text(
                  sender,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _receivePill(context),
        ),
      ),
    );
  }

  Widget _receivePill(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cast_connected_rounded,
              size: 16, color: theme.colorScheme.primary),
          const SizedBox(width: 6),
          Text(
            '正在接收投屏',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, ReceiverSession? session) {
    final theme = Theme.of(context);
    final title = session?.title.trim() ?? '';
    final userAgent = session?.senderUserAgent ?? '';
    final sender = session == null
        ? ''
        : '投送方 ${session.senderAddress}'
            '${userAgent.isEmpty ? '' : ' · $userAgent'}';
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Container(
          margin: const EdgeInsets.all(8),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              _receivePill(context),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (title.isNotEmpty)
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(color: Colors.white),
                      ),
                    if (sender.isNotEmpty)
                      Text(
                        sender,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: Colors.white70),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '停止接收并关闭',
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: _close,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildControls() {
    final playing = _status.transportState == kTransportPlaying;
    final duration = _status.duration;
    final maxMs = duration.inMilliseconds > 0 ? duration.inMilliseconds : 1;
    // 拖动中本地回显拖拽值，松手才真正 seek（避免拖动过程每帧打引擎）。
    final positionMs =
        (_seekPreviewMs ?? _status.position.inMilliseconds.toDouble())
            .clamp(0, maxMs)
            .toDouble();
    return Container(
      margin: const EdgeInsets.all(8),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: playing ? '暂停' : '播放',
                icon: Icon(
                  playing
                      ? Icons.pause_circle_filled_rounded
                      : Icons.play_circle_fill_rounded,
                  color: Colors.white,
                  size: 32,
                ),
                onPressed: _togglePlay,
              ),
              Text(
                _clock(Duration(milliseconds: positionMs.round())),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              Expanded(
                child: SliderTheme(
                  data: const SliderThemeData(trackHeight: 2),
                  child: Slider(
                    value: positionMs,
                    max: maxMs.toDouble(),
                    onChanged:
                        duration.inMilliseconds > 0 ? _onSeekPreview : null,
                    onChangeEnd: duration.inMilliseconds > 0 ? _onSeek : null,
                  ),
                ),
              ),
              Text(
                _clock(duration),
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: _status.muted ? '取消静音' : '静音',
                icon: Icon(
                  _status.muted
                      ? Icons.volume_off_rounded
                      : Icons.volume_up_rounded,
                  color: Colors.white,
                ),
                onPressed: _toggleMute,
              ),
              SizedBox(
                width: 160,
                child: SliderTheme(
                  data: const SliderThemeData(trackHeight: 2),
                  child: Slider(
                    value: (_volumePreview ?? _status.volume.toDouble())
                        .clamp(0, 100)
                        .toDouble(),
                    max: 100,
                    onChanged: _onVolumePreview,
                    onChangeEnd: _onVolume,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlay() async {
    final engine = _engineOrNull;
    if (engine == null) return;
    try {
      if (_status.transportState == kTransportPlaying) {
        await engine.pause();
      } else {
        await engine.play();
      }
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·播放控制', e, st);
    }
  }

  /// 拖动中只刷 UI（本地回显），松手才真正 seek（onChangeEnd）。
  double? _seekPreviewMs;

  void _onSeekPreview(double value) => setState(() => _seekPreviewMs = value);

  Future<void> _onSeek(double value) async {
    _seekPreviewMs = null;
    final engine = _engineOrNull;
    if (engine == null) return;
    try {
      await engine.seek(Duration(milliseconds: value.round()));
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·拖动进度', e, st);
    }
  }

  double? _volumePreview;

  void _onVolumePreview(double value) => setState(() => _volumePreview = value);

  Future<void> _onVolume(double value) async {
    _volumePreview = null;
    final engine = _engineOrNull;
    if (engine == null) return;
    try {
      await engine.setVolume(value.round());
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·音量', e, st);
    }
  }

  Future<void> _toggleMute() async {
    final engine = _engineOrNull;
    if (engine == null) return;
    try {
      await engine.setMuted(!_status.muted);
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·静音', e, st);
    }
  }

  String _clock(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${total ~/ 60}:${two(total % 60)}';
  }
}
