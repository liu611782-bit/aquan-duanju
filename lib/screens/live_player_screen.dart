import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/error_log.dart';
import '../core/live/epg.dart';
import '../core/live/live_parser.dart';
import '../core/player/player_engine.dart';
import '../core/player/mpv_headers.dart';
import '../core/cast/cast_controller.dart';
import '../core/sources/source_probe.dart';
import '../store/stores.dart';
import '../widgets/cast_panel.dart';
import '../widgets/common.dart';

/// 直播播放页：频道抽屉 + 备用地址自动切换 + 键盘换台（桌面）。
/// 直播不写观看历史；只记忆「上次直播源 + 频道」。
class LivePlayerScreen extends StatefulWidget {
  const LivePlayerScreen({
    super.key,
    required this.live,
    required this.groups,
    required this.initialGroup,
    required this.channel,
    this.latency = const {},
    this.epg,
  });

  final LiveEntry live;
  final List<LiveGroup> groups;
  final int initialGroup;
  final LiveChannel channel;
  final Map<String, ProbeOutcome> latency;
  final EpgGuide? epg;

  @override
  State<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<LivePlayerScreen> {
  late final PlayerEngine _engine;
  late int _groupIndex;
  late LiveChannel _channel;

  int _urlIndex = 0;
  String? _error;
  bool _loading = true;
  bool _showDrawer = false;
  bool _showBar = true;
  Timer? _hideTimer;

  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _playingSub;
  final FocusNode _focusNode = FocusNode();

  LiveGroup get _group => widget.groups[_groupIndex.clamp(0, widget.groups.length - 1)];

  @override
  void initState() {
    super.initState();
    _groupIndex = widget.initialGroup;
    _channel = widget.channel;
    _engine = MpvPlayerEngine();
    _play();
    _errorSub = _engine.stream.error.listen((message) {
    if (message.isNotEmpty) _onPlaybackFailed();
  });
    _playingSub = _engine.stream.playing.listen((playing) {
      if (mounted && playing) setState(() => _loading = false);
    });
    // 恢复上次频道记忆。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppScope.read(context)
          .lives
          .setLastWatched(widget.live.id, _channel.name);
    });
  }

  @override
  void dispose() {
    _errorSub?.cancel();
    _playingSub?.cancel();
    _hideTimer?.cancel();
    _engine.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  LiveUrl get _currentUrl =>
      _channel.urls[_urlIndex.clamp(0, _channel.urls.length - 1)];

  /// 每次打开频道的代号：切台后旧的 await 结果（含失败）必须丢弃。
  int _playEpoch = 0;

  // ---------- 投屏（DLNA 发送端：直播 HLS/FLV 直链，带源头经手机代理） ----------

  Future<void> _openCastSheet() async {
    final url = _currentUrl;
    final result = await showCastSheet(
      context,
      media: CastMedia(url: url.url, title: _channel.name, headers: url.headers),
      onLocalPause: () => _engine.pause(),
    );
    if (!mounted || result == null) return;
    if (result == 'disconnect') {
      await castController.disconnect();
      // 直播回本地：重新对台到实时边缘（mpv 暂停恢复会停在缓冲时间线）。
      await _play();
    }
  }

  Future<void> _play() async {
    final epoch = ++_playEpoch;
    final url = _currentUrl;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _engine.initialize();
      if (!mounted || epoch != _playEpoch) return;
      // 直播频道同样常有 Referer/UA 防盗链：只靠 Media(httpHeaders:) 不够。
      await MpvHeaders.install(_engine, url.headers);
      if (!mounted || epoch != _playEpoch) return;
      await _engine.open(
        Media(url.url, httpHeaders: url.headers),
        play: true,
      );
      if (!mounted || epoch != _playEpoch) return;
      setState(() {
        _loading = false;
        _showBar = true;
      });
      _armHideTimer();
    } catch (e) {
      ErrorLog.instance.record('直播播放', e, StackTrace.current);
      if (!mounted || epoch != _playEpoch) return;
      await _onPlaybackFailed(epoch);
    }
  }

  /// 播放失败：切同频道下一个地址；地址尽则提示并高亮下一频道。
  ///
  /// [epoch] 由 [_play] 传入：切台后旧请求的失败不允许推进新频道的地址下标。
  Future<void> _onPlaybackFailed([int? epoch]) async {
    if (!mounted) return;
    if (epoch != null && epoch != _playEpoch) return;
    if (_urlIndex < _channel.urls.length - 1) {
      _urlIndex++;
      await _play();
      return;
    }
    setState(() {
      _loading = false;
      _error = '「${_channel.name}」所有地址都不可用，试试下一频道';
    });
  }

  Future<void> _switchChannel(LiveChannel channel) async {
    setState(() {
      _channel = channel;
      _urlIndex = 0;
      _showDrawer = false;
    });
    AppScope.read(context).lives.setLastWatched(widget.live.id, channel.name);
    await _play();
  }

  void _nextChannel(int delta) {
    final channels = _group.channels;
    if (channels.isEmpty) return;
    final i = channels.indexOf(_channel);
    final next = (i + delta) % channels.length;
    _switchChannel(channels[next < 0 ? next + channels.length : next]);
  }

  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showBar = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: KeyboardListener(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (event) {
          if (event is KeyDownEvent) {
            if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
              _nextChannel(-1);
            } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _nextChannel(1);
            } else if (event.logicalKey == LogicalKeyboardKey.keyL ||
                event.logicalKey == LogicalKeyboardKey.enter) {
              setState(() => _showDrawer = !_showDrawer);
            }
          }
        },
        child: Stack(
          children: [
            Center(child: Video(controller: _engine.videoController)),
            if (_loading)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      onPressed: () {
                        _urlIndex = 0;
                        _play();
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            // 顶栏
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _showBar ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: SafeArea(
                  bottom: false,
                  child: Container(
                    color: Colors.black54,
                    child: Row(
                      children: [
                        BackButton(color: Colors.white),
                        Expanded(
                          child: Text(
                            [
                              _channel.name,
                              if (widget.epg != null)
                                widget.epg!
                                    .nowFor(
                                        epgKeysFor(
                                            channelName: _channel.name,
                                            tvgId: _channel.tvgId),
                                        DateTime.now().toUtc())
                                    ?.title ??
                                    '',
                            ].where((s) => s.isNotEmpty).join(' · '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 15),
                          ),
                        ),
                        if (widget.latency[_channel.name]?.isOk ?? false)
                          Padding(
                            padding: const EdgeInsets.only(right: 12),
                            child: Text(
                              '${widget.latency[_channel.name]!.latencyMs}ms',
                              style: const TextStyle(
                                  color: Colors.green, fontSize: 12),
                            ),
                          ),
                        ListenableBuilder(
                          listenable: castController,
                          builder: (context, _) => IconButton(
                            tooltip: castController.isCasting
                                ? '投屏管理'
                                : '投屏到电视',
                            icon: Icon(
                              castController.isCasting
                                  ? Icons.cast_connected
                                  : Icons.cast_outlined,
                              color: Colors.white,
                            ),
                            onPressed: _openCastSheet,
                          ),
                        ),
                        IconButton(
                          tooltip: '频道列表',
                          icon:
                              const Icon(Icons.format_list_bulleted, color: Colors.white),
                          onPressed: () =>
                              setState(() => _showDrawer = !_showDrawer),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // 频道抽屉
            if (_showDrawer)
              Positioned(
                top: 0,
                bottom: 0,
                right: 0,
                width: 320,
                child: Container(
                  color: Colors.black87,
                  child: SafeArea(
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(
                            children: [
                              Text('频道列表',
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(color: Colors.white)),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.close, color: Colors.white),
                                onPressed: () =>
                                    setState(() => _showDrawer = false),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          height: 44,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8),
                            children: [
                              for (var i = 0; i < widget.groups.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: ChoiceChip(
                                    label: Text(widget.groups[i].name,
                                        style:
                                            const TextStyle(fontSize: 12)),
                                    selected: i == _groupIndex,
                                    onSelected: (_) =>
                                        setState(() => _groupIndex = i),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.builder(
                            itemCount: _group.channels.length,
                            itemBuilder: (context, index) {
                              final channel = _group.channels[index];
                              final active =
                                  channel.name == _channel.name;
                              return ListTile(
                                dense: true,
                                selected: active,
                                selectedColor: theme.colorScheme.primary,
                                title: Text(channel.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 13)),
                                subtitle: Text(
                                    '${channel.urls.length} 地址',
                                    style: const TextStyle(
                                        color: Colors.white38, fontSize: 11)),
                                onTap: () => _switchChannel(channel),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
