import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cast/cast_controller.dart';
import '../core/cast/cast_target.dart';
import '../core/cast/mirror/mirror_controller.dart';
import '../core/cast/cast_service.dart';
import '../core/error_log.dart';
import 'common.dart';

/// 投屏全局控制器（跨页面存活）。
final castController = CastService.instance.controller;

/// Android 组播锁：部分机型不持锁收不到 M-SEARCH 响应。
Future<void> acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('aquan/cast')
        .invokeMethod<void>('acquireMulticastLock');
  } catch (_) {
    // 通道不可用（旧安装包/非 Android）不影响其余发现路径。
  }
}

Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('aquan/cast')
        .invokeMethod<void>('releaseMulticastLock');
  } catch (_) {}
}

/// 播放器顶栏投屏按钮入口。
/// 返回：'started'（已开始投屏，调用方应暂停本地）/'disconnect'（用户要求断开，
/// 调用方应 await castController.disconnect() 取进度并按设置回本地）/null。
/// 加密分集由调用方拦截（M1 不支持中继）。
Future<String?> showCastSheet(
  BuildContext context, {
  required CastMedia media,
  required Future<void> Function() onLocalPause,
  /// 默认勾选「镜像屏幕」：加密分集的中继起不来时，镜像是唯一不依赖 ffmpeg
  /// 的通路（MediaProjection → MediaCodec → MPEG-TS）。
  bool initialMirrorMode = false,
}) async {
  final scope = AppScope.read(context);
  final controller = castController;
  if (controller.isCasting) {
    // 已在投屏：展示当前会话（断开/换设备）。
    return showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => const _CastSessionSheet(),
    );
  }
  await acquireMulticastLock();
  controller.startScan();
  String? result;
  if (context.mounted) {
    await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => _CastDeviceSheet(
        scope: scope,
        media: media,
        initialMirrorMode: initialMirrorMode,
      ),
    );
    result = controller.isCasting ? 'started' : null;
  }
  controller.stopScan();
  await releaseMulticastLock();
  if (result == 'started') {
    await onLocalPause();
  }
  return result;
}

/// 设备选择抽屉。
class _CastDeviceSheet extends StatefulWidget {
  const _CastDeviceSheet({
    required this.scope,
    required this.media,
    this.initialMirrorMode = false,
  });

  final AppScope scope;
  final CastMedia media;
  final bool initialMirrorMode;

  @override
  State<_CastDeviceSheet> createState() => _CastDeviceSheetState();
}

class _CastDeviceSheetState extends State<_CastDeviceSheet> {
  final _ipController = TextEditingController();
  bool _connecting = false;
  bool _mirrorMode = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mirrorMode = widget.initialMirrorMode;
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 设备列表与钉选状态都来自 ChangeNotifier：面板打开期间 SSDP 发现
    // 必须能刷新，否则扫到的设备永远不会出现（手动 IP 是唯一兜底）。
    return ListenableBuilder(
      listenable: Listenable.merge([castController, widget.scope.cast]),
      builder: _buildSheet,
    );
  }

  Widget _buildSheet(BuildContext context, Widget? _) {
    final theme = Theme.of(context);
    final cast = widget.scope.cast;
    final devices = CastService.instance.sortDevices(
      castController.devices,
      pinnedIds: cast.pinnedIds,
      lastId: cast.lastDevice?.id,
    );
    final pinnedOffline = [
      for (final d in cast.pinned)
        if (!devices.any((x) => x.id == d.id)) d,
    ];
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('投屏到设备', style: theme.textTheme.titleMedium),
                const Spacer(),
                if (castController.state == CastSessionState.discovering)
                  const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text('设备与手机需在同一 Wi-Fi；扫描几秒无结果可手动输入 IP',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ),
                FilterChip(
                  selected: _mirrorMode,
                  label: const Text('镜像屏幕', style: TextStyle(fontSize: 12)),
                  avatar: Icon(Icons.phone_android,
                      size: 16,
                      color: _mirrorMode
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline),
                  onSelected: (v) => setState(() => _mirrorMode = v),
                ),
              ],
            ),
            if (_mirrorMode) ...[
              const SizedBox(height: 4),
              Text('镜像模式：把本机屏幕实时投到所选电视（含声音），点设备即开始',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final d in devices)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        d.protocol == CastProtocol.chromecast
                            ? Icons.cast
                            : Icons.tv,
                        color: d.online
                            ? theme.colorScheme.primary
                            : theme.colorScheme.outline,
                      ),
                      title: Text(d.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(
                        [
                          d.protocol == CastProtocol.chromecast
                              ? 'Chromecast'
                              : 'DLNA',
                          if (d.modelName.isNotEmpty) d.modelName,
                          if (!d.online) '离线',
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: cast.isPinned(d.id)
                          ? const Icon(Icons.push_pin, size: 16)
                          : null,
                      onTap: () => _connect(d),
                    ),
                  // 钉选过但本轮没扫到的设备：仍可直连（同一局域网通常可达）。
                  for (final d in pinnedOffline)
                    ListTile(
                      dense: true,
                      leading: Icon(Icons.tv,
                          color: theme.colorScheme.outline),
                      title: Text(d.name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: const Text('未在本次扫描出现，点击尝试直连'),
                      onTap: () => _connect(d),
                    ),
                  if (devices.isEmpty && pinnedOffline.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: Text('同一 Wi-Fi 下还没有发现可投屏的设备',
                            style: TextStyle(
                                color: theme.colorScheme.outline)),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ipController,
                    decoration: const InputDecoration(
                      isDense: true,
                      hintText: '设备 IP（如 192.168.1.23）',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _addByIp,
                  child: const Text('直连'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
            ],
            if (_connecting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _connect(CastTarget device) async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await widget.scope.cast.touchLast(device);
      if (_mirrorMode) {
        final mirror = MirrorController.instance;
        if (!await mirror.requestPermission()) {
          if (mounted) {
            setState(() {
              _connecting = false;
              _error = mirror.lastError ?? '未授权屏幕录制';
            });
          }
          return;
        }
        final url = await mirror.start(api: widget.scope.api);
        if (!mounted) return;
        if (url == null || url.isEmpty) {
          setState(() {
            _connecting = false;
            _error = mirror.lastError ?? '镜像服务启动失败';
          });
          return;
        }
        await castController.castTo(
          device,
          CastMedia(url: url, title: '屏幕镜像', isMirror: true),
        );
      } else {
        await castController.castTo(device, widget.media);
      }
      if (mounted) Navigator.of(context).pop('started');
    } catch (e, stack) {
      // 用户看到的是固定文案；SOAP 动作名/状态码只进诊断日志。
      ErrorLog.instance.record('投屏连接', e, stack);
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = '设备未响应，可重试或换一台设备';
        });
      }
    }
  }

  Future<void> _addByIp() async {
    final host = _ipController.text.trim();
    if (host.isEmpty) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      final device = await castController.addByIp(host);
      if (!mounted) return;
      if (device == null) {
        setState(() {
          _connecting = false;
          _error = '该地址没有响应投屏描述（确认设备已开机且 IP 正确）';
        });
        return;
      }
      await _connect(device);
    } finally {
      if (mounted && _connecting) setState(() => _connecting = false);
    }
  }
}

/// 投屏会话抽屉：设备名 + 进度 + 静音 + 断开。
class _CastSessionSheet extends StatefulWidget {
  const _CastSessionSheet();

  @override
  State<_CastSessionSheet> createState() => _CastSessionSheetState();
}

class _CastSessionSheetState extends State<_CastSessionSheet> {
  bool _muted = false;
  // 远端音量乐观维护（各厂商 GetVolume 差异大，不做轮询对齐）。
  double _volume = 0.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: castController,
        builder: (context, _) {
          final device = castController.currentDevice;
          final media = castController.currentMedia;
          final position = castController.remotePosition;
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('正在投屏', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.tv),
                  title: Text(device?.name ?? '设备'),
                  subtitle: Text(
                    [
                      if (media != null) media.title,
                      if (position > Duration.zero) _fmt(position),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: () => castController.resume(),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('播放'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: () => castController.pause(),
                      icon: const Icon(Icons.pause),
                      label: const Text('暂停'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: () {
                        // 静音状态本地乐观维护（RCS GetMute 各厂商差异大，不做轮询对齐）。
                        final next = !_muted;
                        castController.setMute(next).then((_) {
                          if (mounted) setState(() => _muted = next);
                        }).catchError((_) {});
                      },
                      child: Icon(
                          _muted ? Icons.volume_off : Icons.volume_up),
                    ),
                    const Spacer(),
                    FilledButton.tonalIcon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      label: const Text('关闭面板'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(Icons.volume_down,
                        size: 18, color: theme.colorScheme.outline),
                    Expanded(
                      child: Slider(
                        value: _volume,
                        onChanged: (v) {
                          setState(() => _volume = v);
                          castController
                              .setVolume((v * 100).round())
                              .catchError((_) {});
                        },
                      ),
                    ),
                    Icon(Icons.volume_up,
                        size: 18, color: theme.colorScheme.outline),
                  ],
                ),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.cast),
                    label: const Text('断开投屏'),
                    onPressed: () => Navigator.of(context).pop('disconnect'),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

/// 播放器常驻投屏按钮：控件条 3–4 秒自动隐藏后，投屏入口不能跟着消失。
///
/// 与播放器左上角的「常驻返回」同一套视觉（半透明黑底 + 圆形 + 白色图标）；
/// 只在控件条隐藏时由调用方显示，避免与顶栏投屏按钮重复。
class CastFabButton extends StatelessWidget {
  const CastFabButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: ListenableBuilder(
        listenable: castController,
        builder: (context, _) => Tooltip(
          message: castController.isCasting ? '投屏管理' : '投屏到电视',
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(
                castController.isCasting
                    ? Icons.cast_connected
                    : Icons.cast_outlined,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 投屏状态条：投屏中叠在播放器顶部下方（设备名 + 断开按钮）。
class CastStatusBar extends StatelessWidget {
  const CastStatusBar({
    super.key,
    required this.deviceName,
    required this.onOpenSession,
  });

  final String deviceName;
  final VoidCallback onOpenSession;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.primaryContainer,
      child: InkWell(
        onTap: onOpenSession,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            children: [
              Icon(Icons.cast,
                  size: 16, color: theme.colorScheme.onPrimaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '已投屏到「$deviceName」· 点击管理',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onPrimaryContainer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

