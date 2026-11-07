import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../core/cast/cast_controller.dart';
import '../core/cast/cast_diagnostics.dart';
import '../core/cast/cast_recipe.dart';
import '../core/cast/cast_target.dart';
import '../core/cast/didl.dart';
import '../core/cast/web_cast.dart';
import '../core/cast/mirror/mirror_controller.dart';
import '../core/cast/cast_service.dart';
import '../core/cast/soap_client.dart';
import '../core/cast/ssdp_discovery.dart';
import '../core/error_log.dart';
import '../store/stores.dart';
import 'cast_receiver_tile.dart';
import 'common.dart';
import 'loading.dart';
import 'tv_focusable.dart';
import 'tv_scope.dart';

/// 投屏全局控制器（跨页面存活）。
final castController = CastService.instance.controller;

/// Android 组播锁：部分机型不持锁收不到 M-SEARCH 响应。
Future<void> acquireMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('aquan/cast')
        .invokeMethod<void>('acquireMulticastLock');
  } catch (_) {
    // 通道不可用/无 Wi-Fi 硬件：仅退化为 NOTIFY/单播发现，不阻断面板。
  }
}

Future<void> releaseMulticastLock() async {
  if (!Platform.isAndroid) return;
  try {
    await const MethodChannel('aquan/cast')
        .invokeMethod<void>('releaseMulticastLock');
  } catch (_) {}
}

/// R5：面板设备显示顺序。
///
/// 未连接时走既有 [CastService.sortDevices]（钉选 > 最近使用 > 在线 > 名称）。
/// 连接期间传入 [frozen] 快照：顺序严格按快照，只用最新扫描结果同步在线状态，
/// 不重排、不插入新设备；[lastId] 由调用方固定为连接开始时的值。
List<CastTarget> orderedDevices({
  required Iterable<CastTarget> live,
  required Set<String> pinnedIds,
  required String? lastId,
  List<CastTarget>? frozen,
}) {
  final liveList = live.toList();
  if (frozen == null) {
    return CastService.instance.sortDevices(
      liveList,
      pinnedIds: pinnedIds,
      lastId: lastId,
    );
  }
  final byId = <String, CastTarget>{for (final d in liveList) d.id: d};
  return <CastTarget>[
    for (final f in frozen) byId[f.id] ?? f,
  ];
}

/// R5：只有投屏成功才刷新「最近使用」；失败不写，避免失败设备被顶到前面。
/// [cast] 的异常原样上抛，由 UI 显示固定文案并把 stage/异常写 ErrorLog。
Future<void> castAndRemember({
  required Future<void> Function() cast,
  required Future<void> Function() remember,
}) async {
  await cast();
  await remember();
}

/// transportState → 会话抽屉状态徽标固定文案（五态映射）：
/// PLAYING/RUNNING → 播放中、PAUSED_PLAYBACK → 已暂停、
/// TRANSITIONING/BUFFERING → 缓冲中、STOPPED/NO_MEDIA_PRESENT → 已停止；
/// 未知/空串（尚未轮询到）返回 null，UI 不显示徽标。
String? castTransportStateLabel(String transportState) {
  switch (transportState.trim().toUpperCase()) {
    case 'PLAYING':
    case 'RUNNING':
      return '播放中';
    case 'PAUSED_PLAYBACK':
      return '已暂停';
    case 'TRANSITIONING':
    case 'BUFFERING':
      return '缓冲中';
    case 'STOPPED':
    case 'NO_MEDIA_PRESENT':
      return '已停止';
    default:
      return null;
  }
}

/// 会话抽屉取流指示文案（R1）。
///
/// - [requests] 里有 ≥1 条 2xx（[MediaRequestTrace.isOk]）→
///   「电视已来取流（n 次 · x.x MB，最近 HH:MM:SS）」；非 2xx 记录不计数
///   （404/416 等失败尝试属于诊断明细，不进这一行）；
/// - 0 次 2xx 且 [playing]（播放中状态）→ 「电视尚未取流」——只在播放中
///   显示，避免连接瞬间误报「没取流」；
/// - 其余（0 次且未播放）返回 null：UI 不显示该行。
String? castFetchIndicatorText(
  Iterable<MediaRequestTrace> requests, {
  bool playing = false,
}) {
  final ok = requests.where((m) => m.isOk).toList(growable: false);
  if (ok.isEmpty) {
    return playing ? '电视尚未取流' : null;
  }
  final last = ok.last.at;
  String two(int v) => v.toString().padLeft(2, '0');
  final clock = '${two(last.hour)}:${two(last.minute)}:${two(last.second)}';
  final mb = ok.fold<int>(0, (sum, m) => sum + m.bytesServed) / (1024 * 1024);
  return '电视已来取流（${ok.length} 次 · ${mb.toStringAsFixed(1)} MB，最近 $clock）';
}

/// 恢复卡片可见性（R1.2 / AC-4）：无活动会话（idle/discovering 都算空闲
/// ——面板打开期间扫描使 state 停在 discovering）且记录与目标都能重建时
/// 才显示；记录损坏返回 false（调用方负责静默清理存储键）。
bool castResumeCardVisible({
  required CastSessionRecord? record,
  required bool sessionIdle,
}) {
  if (!sessionIdle || record == null) return false;
  return record.resolveTarget() != null;
}

/// 恢复卡片整行文案（R1.2）：「上次投到 <设备名>：<标题>（HH:mm）· 恢复」。
/// HH:mm 取记录的 endedAt（会话最后结束/收尾时刻）。
String castResumeCardText({
  required CastSessionRecord record,
  required CastTarget target,
}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final at = record.endedAt;
  return '上次投到 ${target.name}：${record.title}'
      '（${two(at.hour)}:${two(at.minute)}）· 恢复';
}

/// R3：配方字段的中文标签（诊断面板「当前配方」行；固定文案）。
const Map<DidlVariant, String> _kDidlLabels = {
  DidlVariant.full: '完整',
  DidlVariant.compact: '精简',
  DidlVariant.compatEscaped: '兼容转义',
};

const Map<DidlProtocolInfoTemplate, String> _kTemplateLabels = {
  DidlProtocolInfoTemplate.standard: '标准',
  DidlProtocolInfoTemplate.bare: '裸',
  DidlProtocolInfoTemplate.wildcard: '通配',
  DidlProtocolInfoTemplate.withPn: '带PN',
  DidlProtocolInfoTemplate.sinkEntry: '设备同款',
  DidlProtocolInfoTemplate.op11: 'OP11',
};

/// 诊断面板「当前配方」行文案（R3.1）。
///
/// - 命中（[recipe] 非 null，即配方表 udn → model 双层已记忆）→ 展示
///   didl / protocolInfo 模板 / Play 延迟 / URL 形态 / 兼容模式；
/// - 未命中 → 「未记忆（将自动尝试 7 步梯度）」。
String castRecipeDisplayText(CastRecipe? recipe) {
  if (recipe == null) return '未记忆（将自动尝试 7 步梯度）';
  return [
    'DIDL ${_kDidlLabels[recipe.didl] ?? recipe.didl.name}',
    '模板 ${_kTemplateLabels[recipe.protocolInfoTemplate] ?? recipe.protocolInfoTemplate.name}',
    '延迟 ${recipe.playDelayMs}ms',
    'URL ${recipe.urlSuffixMode == CastUrlSuffixMode.withExtension ? '带扩展名' : '裸形态'}',
    '兼容 ${switch (recipe.transcodeMode) {
      CastTranscodeMode.auto => '自动',
      CastTranscodeMode.always => '始终',
      CastTranscodeMode.never => '从不',
    }}',
  ].join(' · ');
}

/// 失败重试后已试变体行（R3.2）：从诊断时间线抽出配方尝试记录（
/// `配方命中：…` / `配方未命中：…`，dlna_transport 埋点），取最近
/// [max] 条（旧→新）；无记录返回空列表。
List<String> castRecipeAttemptLines(List<String> timeline, {int max = 3}) {
  final attempts = timeline.where((l) => l.contains('配方')).toList();
  if (attempts.length <= max) return attempts;
  return attempts.sublist(attempts.length - max);
}

/// TRANSITIONING 状态抖动消抖（800ms）：设备起播/换集瞬间 PLAYING ↔
/// TRANSITIONING 快速抖动，窗口内维持上一状态显示，抖回就不闪「缓冲中」。
class CastTransitionDebouncer {
  CastTransitionDebouncer({this.window = const Duration(milliseconds: 800)});

  /// 消抖窗口（默认 800ms）。
  final Duration window;

  Timer? _timer;
  bool _elapsed = false;
  bool _holding = false;

  /// 窗口过后由内部 [Timer] 触发（UI 侧据此刷新显示）。
  void Function()? onElapsed;

  /// 输入原始 transportState；返回 true = 处于消抖窗口，UI 维持上一状态。
  bool shouldHold(String transportState) {
    if (transportState.trim().toUpperCase() != 'TRANSITIONING') {
      _timer?.cancel();
      _timer = null;
      _elapsed = false;
      _holding = false;
      return false;
    }
    if (!_elapsed && _timer == null) {
      _holding = true;
      _timer = Timer(window, () {
        _timer = null;
        _elapsed = true;
        _holding = false;
        onElapsed?.call();
      });
    }
    return _holding;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
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
    // 已在投屏：展示当前会话（断开/换设备）。scope 传入供「取流指示」行
    // 跳转诊断弹窗（配方表查询用）。
    return showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => _CastSessionSheet(scope: scope),
    );
  }
  // 组播锁获取失败已在 acquireMulticastLock 内吞掉，面板照常弹出。
  await acquireMulticastLock();
  try {
    controller.startScan();
  } catch (e, stack) {
    // 扫描启动失败同样不阻断面板（R4）：原始异常只进 ErrorLog。
    ErrorLog.instance.record('投屏扫描启动', e, stack);
  }
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
  bool _webCastBusy = false;
  bool _webCastSuggested = false;
  String? _error;

  /// 兼容模式（本机转码后投屏）三态（M5-0 / AC-22）：初始值取最近使用
  /// 设备按 UDN 记忆的配方；连接时写入目标设备配方（跨启动生效）。
  CastTranscodeMode _transcodeMode = CastTranscodeMode.auto;

  /// 中继转码画质档位（R2）：初始值取设置（默认均衡）；三选即时写入
  /// SettingsStore 持久化（备份白名单键 cast.relayQuality），两处播放器的
  /// relay 调用按当前值透传给 Go。
  String _quality = 'balanced';

  /// R5：连接开始时的设备顺序快照与固定 lastId（连接期间不重排）。
  List<CastTarget>? _frozenDevices;
  String? _connectingLastId;

  /// 诊断信息（不含 URL/凭据）：最近连接目标、最近一次 SOAP 状态、当前阶段。
  CastTarget? _diagDevice;
  String _diagSoap = '暂无';
  String _stage = '扫描';

  @override
  void initState() {
    super.initState();
    _mirrorMode = widget.initialMirrorMode;
    _quality = widget.scope.settings.castRelayQuality;
    final last = widget.scope.cast.lastDevice;
    if (last != null) {
      _transcodeMode = widget.scope.cast.recipes.lookup(last)?.transcodeMode ??
          CastTranscodeMode.auto;
    }
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
    final devices = orderedDevices(
      live: castController.devices,
      pinnedIds: cast.pinnedIds,
      // 连接期间固定为开始时的值，扫描刷新不重排。
      lastId: _frozenDevices != null ? _connectingLastId : cast.lastDevice?.id,
      frozen: _frozenDevices,
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
                  const AppLoading.inline(),
                const SizedBox(width: 4),
                // 低调的「投屏诊断」入口：绑定端口 / 设备指纹 / SOAP 状态 /
                // 镜像服务 / 当前配方，只展示不含 URL 与凭据的诊断信息。
                _tvItem(
                  context,
                  label: '投屏诊断',
                  onTap: () => _showDiagnostics(context, devices),
                  child: Icon(Icons.bug_report_outlined,
                      size: 18, color: theme.colorScheme.outline),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // DLNA 接收端入口：与设置页同一开关状态，本机也能成为投屏
            // 目标（桌面 + Android；iOS 等其余平台整块隐藏）。
            CastReceiverTile(
              compact: true,
              onPersistEnabled: (v) =>
                  widget.scope.settings.castReceiverEnabled = v,
              receiverName: widget.scope.settings.castReceiverName,
            ),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text('设备与手机需在同一 Wi-Fi；扫描几秒无结果可手动输入 IP',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline)),
                ),
                Semantics(
                  button: true,
                  selected: _mirrorMode,
                  label: '镜像屏幕',
                  child: TvFocusable(
                    enabled: TvScope.isTvOf(context),
                    onTap: () => setState(() => _mirrorMode = !_mirrorMode),
                    child: FilterChip(
                      selected: _mirrorMode,
                      label: const Text('镜像屏幕', style: TextStyle(fontSize: 12)),
                      avatar: Icon(Icons.phone_android,
                          size: 16,
                          color: _mirrorMode
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline),
                      onSelected: (v) => setState(() => _mirrorMode = v),
                    ),
                  ),
                ),
              ],
            ),
            if (_mirrorMode) ...[
              const SizedBox(height: 4),
              Text('镜像模式：把本机屏幕实时投到所选电视（含声音），点设备即开始',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.primary)),
            ],
            const SizedBox(height: 8),
            // 兼容模式（本机转码后投屏）三态开关（M5-0 / AC-22）：电视投
            // 不出或画面花屏时的第一动作是「始终」；选中状态按 UDN 写入
            // 配方记忆，跨启动生效。
            Row(
              children: [
                Expanded(
                  child: Text('兼容模式（本机转码后投屏）',
                      style: theme.textTheme.bodySmall),
                ),
                _transcodeChip(context, '自动', CastTranscodeMode.auto),
                const SizedBox(width: 4),
                _transcodeChip(context, '始终', CastTranscodeMode.always),
                const SizedBox(width: 4),
                _transcodeChip(context, '从不', CastTranscodeMode.never),
              ],
            ),
            const SizedBox(height: 4),
            Text('对本次连接的设备生效并按设备记忆；MKV/HLS 投不出或画面花屏时选「始终」',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 8),
            // 投屏画质三选（R2）：本机转码（兼容模式/加密分集/编码不支持）
            // 时 ffmpeg 的画质档位，全局记忆随备份走；直投不经过转码，不受影响。
            Row(
              children: [
                Expanded(
                  child: Text('投屏画质（本机转码时生效）',
                      style: theme.textTheme.bodySmall),
                ),
                for (final value in SettingsStore.castRelayQualityValues) ...[
                  if (value != SettingsStore.castRelayQualityValues.first)
                    const SizedBox(width: 4),
                  _qualityChip(
                    context,
                    value,
                    SettingsStore.castRelayQualityLabels[value] ?? value,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text('高清画质最好、CPU 占用最高；省流画质较低、更流畅；均衡为默认',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline)),
            const SizedBox(height: 12),
            // 会话恢复卡片（R1.2）：空闲态且有可恢复记录时显示在设备列表
            // 上方一行，不阻塞列表；损坏记录静默清理后隐藏。
            ..._resumeCard(context, theme),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: devices.length +
                    pinnedOffline.length +
                    (devices.isEmpty && pinnedOffline.isEmpty ? 1 : 0),
                itemBuilder: (itemContext, index) {
                  if (index < devices.length) {
                    final d = devices[index];
                    return _tvItem(
                      itemContext,
                      label: '设备 ${d.name}',
                      onTap: () => _connect(d),
                      child: ListTile(
                        key: ValueKey(d.id),
                        dense: true,
                        leading: Icon(
                          switch (d.protocol) {
                            CastProtocol.chromecast => Icons.cast,
                            CastProtocol.airplay => Icons.airplay,
                            CastProtocol.dlna => Icons.tv,
                          },
                          color: d.online
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        ),
                        title: Text(d.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          [
                            switch (d.protocol) {
                              CastProtocol.chromecast => 'Chromecast',
                              CastProtocol.airplay => 'AirPlay',
                              CastProtocol.dlna => 'DLNA',
                            },
                            if (d.modelName.isNotEmpty) d.modelName,
                            if (!d.online) '离线',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: cast.isPinned(d.id)
                            ? const Icon(Icons.push_pin, size: 16)
                            : null,
                        // 点击交给 TvFocusable：避免 ListTile 内建 InkWell 与
                        // 外层焦点节点形成双焦点。
                      ),
                    );
                  }
                  final pinnedIndex = index - devices.length;
                  if (pinnedIndex < pinnedOffline.length) {
                    // 钉选过但本轮没扫到的设备：仍可直连（同一局域网通常可达）。
                    final d = pinnedOffline[pinnedIndex];
                    return _tvItem(
                      itemContext,
                      label: '设备 ${d.name}',
                      onTap: () => _connect(d),
                      child: ListTile(
                        key: ValueKey(d.id),
                        dense: true,
                        leading: Icon(Icons.tv,
                            color: theme.colorScheme.outline),
                        title: Text(d.name,
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: const Text('未在本次扫描出现，点击尝试直连'),
                      ),
                    );
                  }
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Center(
                      child: Text('同一 Wi-Fi 下还没有发现可投屏的设备',
                          style: TextStyle(color: theme.colorScheme.outline)),
                    ),
                  );
                },
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
                _tvItem(
                  context,
                  label: '直连设备 IP',
                  onTap: _addByIp,
                  child: OutlinedButton(
                    onPressed: _addByIp,
                    child: const Text('直连'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _webCastButton(context),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error)),
              const SizedBox(height: 4),
              Text('打开右上角「投屏诊断」可查看失败分类与本机连通性自助验证',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
            ],
            if (_connecting)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Center(child: AppLoading.inline()),
              ),
          ],
        ),
      ),
    );
  }

  /// 恢复上次投屏卡片（R1.2）：空闲态且 lastSession 可重建目标时返回一行
  /// 卡片，显示在设备列表上方（不阻塞列表）；记录损坏（目标无法重建）→
  /// 静默清理存储键并隐藏。有活动会话（connecting/casting/stopping）时
  /// 不显示——扫描中（discovering）仍显示。
  List<Widget> _resumeCard(BuildContext context, ThemeData theme) {
    final cast = widget.scope.cast;
    final state = castController.state;
    final sessionIdle = state == CastSessionState.idle ||
        state == CastSessionState.discovering;
    final record = cast.lastSession;
    if (!castResumeCardVisible(record: record, sessionIdle: sessionIdle)) {
      return const [];
    }
    final target = record!.resolveTarget();
    if (target == null) {
      unawaited(_clearBrokenSessionRecord());
      return const [];
    }
    return [
      _tvItem(
        context,
        label: '恢复上次投屏',
        onTap: _resumeLastSession,
        child: ListTile(
          key: const ValueKey('cast_resume_card'),
          dense: true,
          leading:
              Icon(Icons.history, color: theme.colorScheme.primary),
          title: Text(
            castResumeCardText(record: record, target: target),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ];
  }

  /// 一键恢复上次投屏（R1.2）：controller 重建目标后走既有标准投屏序列。
  /// 成功与「已开始投屏」同语义（pop 'started'，调用方暂停本地）；记录
  /// 不可恢复 → 静默清理并留在面板；恢复尝试失败 → 固定文案
  /// 「恢复失败，请重新投屏」，原始异常只进 ErrorLog。
  Future<void> _resumeLastSession() async {
    if (_connecting) return;
    final cast = widget.scope.cast;
    if (cast.lastSession == null) return;
    setState(() {
      _connecting = true;
      _error = null;
      _stage = '恢复';
    });
    try {
      final ok = await castController.resumeLastSession();
      if (!mounted) return;
      if (!ok) {
        // 记录不可恢复（无记录/目标损坏）：静默清理并隐藏卡片。
        await _clearBrokenSessionRecord();
        if (mounted) setState(() => _connecting = false);
        return;
      }
      _stage = '播放';
      if (mounted) Navigator.of(context).pop('started');
    } catch (e, stack) {
      ErrorLog.instance.record('投屏会话恢复', e, stack);
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _error = '恢复失败，请重新投屏';
      });
    }
  }

  /// 损坏恢复记录的静默清理（R1.4）：写盘失败也吞掉（卡片本次已隐藏，
  /// 下次打开面板再试）。
  Future<void> _clearBrokenSessionRecord() async {
    try {
      await widget.scope.cast.clearLastSession();
    } catch (_) {}
  }

  /// 兼容模式三态切换（M5-0 / AC-22）：面板即时写入最近使用设备的配方
  /// （尽力而为，写盘失败不阻断面板）；连接目标设备时再写一次（见
  /// [_connect]），保证「对哪台设备选的模式就记在哪台设备上」。
  Widget _transcodeChip(
      BuildContext context, String label, CastTranscodeMode mode) {
    return Semantics(
      button: true,
      selected: _transcodeMode == mode,
      label: '兼容模式$label',
      child: TvFocusable(
        enabled: TvScope.isTvOf(context),
        onTap: () => _setTranscodeMode(mode),
        child: ChoiceChip(
          selected: _transcodeMode == mode,
          label: Text(label, style: const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _setTranscodeMode(mode),
        ),
      ),
    );
  }

  void _setTranscodeMode(CastTranscodeMode mode) {
    setState(() => _transcodeMode = mode);
    final target = widget.scope.cast.lastDevice;
    if (target == null) return;
    widget.scope.cast.recipes
        .setTranscodeMode(target, mode)
        .catchError((Object _) {});
  }

  /// 画质三选 chip（R2）：与兼容模式同一套交互；选择即写入
  /// SettingsStore（持久化 + 备份白名单），播放器 relay 调用按当前值透传。
  Widget _qualityChip(BuildContext context, String value, String label) {
    return Semantics(
      button: true,
      selected: _quality == value,
      label: '投屏画质$label',
      child: TvFocusable(
        enabled: TvScope.isTvOf(context),
        onTap: () => _setQuality(value),
        child: ChoiceChip(
          selected: _quality == value,
          label: Text(label, style: const TextStyle(fontSize: 12)),
          visualDensity: VisualDensity.compact,
          onSelected: (_) => _setQuality(value),
        ),
      ),
    );
  }

  void _setQuality(String value) {
    setState(() => _quality = value);
    widget.scope.settings.castRelayQuality = value;
  }

  Future<void> _connect(CastTarget device) async {
    if (_connecting) return;
    setState(() {
      _connecting = true;
      _error = null;
      _stage = '扫描';
      _diagDevice = device;
      // R5：连接开始冻结当前顺序 + 固定 lastId；touchLast 移到成功之后。
      _frozenDevices = orderedDevices(
        live: castController.devices,
        pinnedIds: widget.scope.cast.pinnedIds,
        lastId: widget.scope.cast.lastDevice?.id,
      );
      _connectingLastId = widget.scope.cast.lastDevice?.id;
    });
    // AC-22：兼容模式按 UDN 写入目标设备配方（投屏前生效；成功后 remember
    // 沿用该三态，写盘失败不阻断投屏）。
    try {
      await widget.scope.cast.recipes.setTranscodeMode(device, _transcodeMode);
    } catch (_) {}
    try {
      var effectiveMedia = widget.media;
      if (_mirrorMode) {
        _stage = '预检';
        final mirror = MirrorController.instance;
        if (!await mirror.requestPermission()) {
          _abort(mirror.lastError ?? '未授权屏幕录制');
          return;
        }
        final url = await mirror.start(api: widget.scope.api);
        if (!mounted) return;
        if (url == null || url.isEmpty) {
          _abort(mirror.lastError ?? '镜像服务启动失败');
          return;
        }
        effectiveMedia = CastMedia(url: url, title: '屏幕镜像', isMirror: true);
      }
      _stage = '连接';
      await castAndRemember(
        cast: () => castController.castTo(device, effectiveMedia),
        remember: () => widget.scope.cast.touchLast(device),
      );
      _stage = '播放';
      if (mounted) Navigator.of(context).pop('started');
    } catch (e, stack) {
      // 用户看到的是固定文案；stage 与原始异常/堆栈只进 ErrorLog。
      ErrorLog.instance.record('投屏连接·$_stage', e, stack);
      _recordSoapDiagnostic(e);
      if (e is CastException) {
        // 本地校验失败（如媒体类型判定：「该地址不是可投屏的视频」）——
        // 文案本身已说明原因，直接展示，不误导为「设备未响应」。
        _abort(e.message);
        return;
      }
      // 标准 DLNA 无响应：明确引导到网页投屏，不留死路。
      _abort('设备未响应，可重试、换一台设备，或试试下方「网页投屏」',
          suggestWebCast: true);
    }
  }

  /// 标准 DLNA 失败后的兜底入口：局域网网页投屏。
  /// 服务由 TTL / 下一次 start 回收——面板关闭时不能停，否则电视扫码时
  /// 页面已经不可达。
  Future<void> _openWebCast() async {
    if (_webCastBusy) return;
    final existing = WebCastService.instance.current;
    if (existing != null) {
      await _showWebCastDialog(existing);
      return;
    }
    setState(() => _webCastBusy = true);
    try {
      final handle = await WebCastService.instance.start(
        url: widget.media.url,
        title: widget.media.title,
        headers: widget.media.headers,
      );
      if (!mounted) return;
      if (handle == null) {
        setState(() => _error = '网页投屏启动失败，请检查局域网连接');
        return;
      }
      await _showWebCastDialog(handle);
    } catch (e, stack) {
      ErrorLog.instance.record('网页投屏', e, stack);
      if (mounted) {
        setState(() => _error = '网页投屏启动失败，请检查局域网连接');
      }
    } finally {
      if (mounted) setState(() => _webCastBusy = false);
    }
  }

  Future<void> _showWebCastDialog(WebCastHandle handle) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('网页投屏'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            QrImageView(data: handle.url, size: 180),
            const SizedBox(height: 12),
            const Text('用电视或手机浏览器扫码，或在同一 Wi-Fi 下输入下面的地址',
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            SelectableText(handle.url,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: handle.url)),
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('复制地址'),
            ),
            Text('30 分钟内有效', style: Theme.of(ctx).textTheme.bodySmall),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _webCastButton(BuildContext context) {
    const label = '网页投屏';
    if (_webCastBusy) {
      return _tvItem(
        context,
        label: label,
        onTap: () {},
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const AppLoading.inline(),
          label: const Text('正在准备…', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    return _tvItem(
      context,
      label: label,
      onTap: _openWebCast,
      child: _webCastSuggested
          ? FilledButton.icon(
              onPressed: _openWebCast,
              icon: const Icon(Icons.qr_code_2, size: 16),
              label: const Text('网页投屏（推荐）',
                  style: TextStyle(fontSize: 12)),
            )
          : OutlinedButton.icon(
              onPressed: _openWebCast,
              icon: const Icon(Icons.qr_code_2, size: 16),
              label: const Text('网页投屏（二维码）',
                  style: TextStyle(fontSize: 12)),
            ),
    );
  }

  void _abort(String message, {bool suggestWebCast = false}) {
    if (!mounted) return;
    setState(() {
      _connecting = false;
      _frozenDevices = null;
      _error = message;
      _webCastSuggested = suggestWebCast;
    });
  }

  void _recordSoapDiagnostic(Object e) {
    if (e is SoapException) {
      // 只取状态码与 faultCode：不把 controlUrl / 凭据带进诊断面板。
      final status = RegExp(r'HTTP\s+(\d{3})').firstMatch(e.message)?.group(1);
      _diagSoap = <String>[
        if (status != null) 'HTTP $status',
        if (e.faultCode != null) 'faultCode=${e.faultCode}',
        if (status == null && e.faultCode == null) 'SOAP 请求失败',
      ].join(' · ');
    } else {
      _diagSoap = '非 SOAP 异常（${e.runtimeType}）';
    }
  }

  /// 电视上「焦点可见」+ 语义焦点的统一交互容器；非 TV 退化为普通 InkWell。
  Widget _tvItem(BuildContext context,
      {required VoidCallback onTap,
      required Widget child,
      required String label}) {
    return Semantics(
      button: true,
      label: label,
      child: TvFocusable(
        enabled: TvScope.isTvOf(context),
        onTap: onTap,
        child: child,
      ),
    );
  }

  /// 诊断分区入口（M0；R1/R3 起与「会话抽屉取流指示」共用同一弹窗，
  /// 见顶层 [showCastDiagnostics]）。
  Future<void> _showDiagnostics(
          BuildContext context, List<CastTarget> devices) =>
      showCastDiagnostics(
        context,
        scope: widget.scope,
        device: _diagDevice,
        devices: devices,
        soapStatus: _diagSoap,
        stage: _stage,
      );

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

/// 投屏诊断弹窗（M0 设备抽屉入口；R1 起会话抽屉「取流指示」行共用）。
///
/// 失败判定 + 一句人话解释、本机 IP / 完整投屏 URL / 监听端口、自助验证
/// 指引、「接受但没取流」时的防火墙放行命令、当前配方（R3.1）与失败
/// 已试变体（R3.2）、「复制诊断报告」「导出到文件」。
///
/// 两级脱敏（review §8.4）：完整投屏 URL（含 token）只在面板展示供自测；
/// 复制/导出的报告一律走 [CastDiagnostics.toRedactedReport]（导出级脱敏，
/// token / 签名 query / 凭据头 / dc:description 不外泄）。
Future<void> showCastDiagnostics(
  BuildContext context, {
  required AppScope scope,
  CastTarget? device,
  List<CastTarget> devices = const <CastTarget>[],
  String soapStatus = '暂无',
  String stage = '扫描',
}) async {
  final theme = Theme.of(context);
  final diag = CastDiagnostics.instance;
  final verdict = diag.computeVerdict();
  final target = device ?? (devices.isEmpty ? null : devices.first);
  final model = target?.modelName ?? '';
  final maker = target?.manufacturer ?? '';
  final mirror = MirrorController.instance;
  final bound = SsdpDiscovery.lastBoundPort;
  final recipe = _lookupRecipe(scope, target);
  final exePath = _executablePath();
  final mediaUrl = diag.mediaUrl;
  final needsFirewallFix = verdict == CastVerdict.acceptedButNotFetched;
  final firewallCommand = needsFirewallFix && exePath.isNotEmpty
      ? CastDiagnostics.buildWindowsFirewallCommand(programPath: exePath)
      : null;
  final report = diag.toRedactedReport();
  final attempts = castRecipeAttemptLines(diag.timeline);
  final detail = <String>[
    report,
    '-- 面板环境 --',
    'SSDP 绑定端口：${bound > 0 ? '$bound' : '未绑定（可手动输入 IP 直连）'}',
    '已发现设备：${devices.length} 台',
    '设备型号：${model.isEmpty ? '未知' : model}',
    '设备厂商：${maker.isEmpty ? '未知' : maker}',
    '最近一次 SOAP 状态：$soapStatus',
    '镜像服务状态：${mirror.state.name}'
        '${mirror.lastError == null ? '' : '（${mirror.lastError}）'}',
    '当前配方：${castRecipeDisplayText(recipe)}',
    if (attempts.isNotEmpty) ...[
      '已试变体（最近 ${attempts.length} 条）：',
      for (final l in attempts) '  $l',
    ],
    '当前阶段：$stage',
  ].join('\n');

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('投屏诊断'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('失败判定', style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(
                verdict?.label ??
                    (diag.playingConfirmed
                        ? '无（电视已进入播放）'
                        : (diag.hasSession ? '暂无判定' : '尚未发起连接')),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: verdict == null
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (verdict != null) ...[
                const SizedBox(height: 4),
                Text(verdict.hint, style: theme.textTheme.bodySmall),
              ],
              const SizedBox(height: 12),
              Text('本机地址（仅供自测，请勿外发）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text('本机 IP：${diag.selectedIp ?? '未采集（发起一次投屏后显示）'}',
                  style: theme.textTheme.bodySmall),
              Text('监听端口：${diag.mediaPort?.toString() ?? '未采集（直投公网地址时无本机端口）'}',
                  style: theme.textTheme.bodySmall),
              if (mediaUrl != null) ...[
                const SizedBox(height: 4),
                SelectableText(mediaUrl, style: theme.textTheme.bodySmall),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: mediaUrl));
                      Navigator.of(dialogContext).pop();
                    },
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制投屏地址', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
              Text('自助验证：在同一 Wi-Fi 下的另一台设备（手机/平板）浏览器打开上面的'
                  '投屏地址。能打开或开始下载，说明本机服务可达、电视理应也能拉到流；'
                  '打不开则是本机 IP / 防火墙 / 端口问题，与协议无关。',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline)),
              if (needsFirewallFix) ...[
                const SizedBox(height: 12),
                Text('防火墙放行（Windows）', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(
                  diag.mediaPort == null
                      ? '判定为「已接受但电视没来取流」时，最常见原因是 Windows '
                          '防火墙拦下了本机媒体服务端口。可复制下方命令（管理员'
                          '运行一次即可，按程序放行）：'
                      : '判定为「已接受但电视没来取流」时，最常见原因是 Windows '
                          '防火墙拦下了本机媒体服务端口（当前监听端口：'
                          '${diag.mediaPort}）。可复制下方命令（管理员运行一次'
                          '即可，按程序放行）：',
                  style: theme.textTheme.bodySmall,
                ),
                if (firewallCommand != null) ...[
                  const SizedBox(height: 4),
                  SelectableText(firewallCommand,
                      style: theme.textTheme.bodySmall),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: firewallCommand));
                        Navigator.of(dialogContext).pop();
                      },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('复制放行命令', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ],
              const SizedBox(height: 12),
              Text('详细报告（复制/导出为脱敏版）',
                  style: theme.textTheme.titleSmall),
              const SizedBox(height: 4),
              SelectableText(detail, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: detail));
            Navigator.of(dialogContext).pop();
          },
          child: const Text('复制诊断报告'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            _exportDiagnosticsReport(context, report);
          },
          child: const Text('导出到文件'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(dialogContext).pop();
            _exportErrorLog(context);
          },
          child: const Text('导出运行日志'),
        ),
      ],
    ),
  );
}

/// 导出诊断报告到应用支持目录（导出级脱敏，见 [CastDiagnostics.toRedactedReport]）。
Future<void> _exportDiagnosticsReport(BuildContext context, String report) =>
    _exportTextFile(
      context,
      filePrefix: 'cast_diagnostics_',
      content: report,
      logSource: '投屏诊断导出',
      successTitle: '已导出诊断报告',
      failText: '诊断报告导出失败，请改用「复制诊断报告」',
    );

/// 一键导出 Dart ErrorLog 全文（M4-2）：安卓闪退取证的配套入口——
/// 崩溃复现后先「导出运行日志」，再配合「导出到文件」的诊断报告一起回传，
/// 同时拿到 Dart 层异常记录与投屏协议轨迹。
Future<void> _exportErrorLog(BuildContext context) => _exportTextFile(
      context,
      filePrefix: 'app_log_',
      content: ErrorLog.instance.text,
      logSource: '运行日志导出',
      successTitle: '已导出运行日志',
      failText: '运行日志导出失败，请到「我的 → 关于」复制错误日志',
    );

/// 把 [content] 写成应用支持目录里 `<filePrefix><日期时间>.txt` 并弹窗展示路径。
/// 导出失败不打断面板：原始异常只进 ErrorLog。
Future<void> _exportTextFile(
  BuildContext context, {
  required String filePrefix,
  required String content,
  required String logSource,
  required String successTitle,
  required String failText,
}) async {
  String? path;
  try {
    final dir = await getApplicationSupportDirectory();
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '$filePrefix'
        '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}.txt';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsString(content, flush: true);
    path = file.path;
  } catch (e, stack) {
    ErrorLog.instance.record(logSource, e, stack);
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(path == null ? '导出失败' : successTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            path == null ? failText : '文件位置：',
            style: Theme.of(dialogContext).textTheme.bodySmall,
          ),
          if (path != null) ...[
            const SizedBox(height: 8),
            SelectableText(path, style: Theme.of(dialogContext).textTheme.bodySmall),
          ],
        ],
      ),
      actions: [
        if (path != null)
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: path!));
              Navigator.of(dialogContext).pop();
            },
            child: const Text('复制路径'),
          ),
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

/// 当前可执行文件路径（防火墙 program 级放行命令用）；取不到为空串。
String _executablePath() {
  try {
    return Platform.resolvedExecutable;
  } catch (_) {
    return '';
  }
}

/// 优先读 CastStore 暴露的持久化配方表，其次读控制器内存表；都没有 = 未记忆。
CastRecipe? _lookupRecipe(AppScope scope, CastTarget? target) {
  if (target == null) return null;
  return scope.cast.recipes.lookup(target) ??
      castController.recipes.lookup(target);
}

/// 投屏会话抽屉：设备名 + 取流指示 + 状态徽标 + 进度条 + 上下集 +
/// 播放/暂停/静音/断开。
class _CastSessionSheet extends StatefulWidget {
  const _CastSessionSheet({required this.scope});

  final AppScope scope;

  @override
  State<_CastSessionSheet> createState() => _CastSessionSheetState();
}

class _CastSessionSheetState extends State<_CastSessionSheet> {
  bool _muted = false;
  // 远端音量乐观维护（各厂商 GetVolume 差异大，不做轮询对齐）。
  double _volume = 0.5;
  // 进度拖动（乐观 UI）：拖动中显示拖动值，不跟随轮询回跳；结束后 seekTo。
  bool _scrubbing = false;
  double? _dragValue;
  // TRANSITIONING 抖动消抖 + 上一帧显示的状态文案（消抖窗口内维持不变）。
  final CastTransitionDebouncer _transitionDebounce = CastTransitionDebouncer();
  String? _displayedStatus;

  @override
  void initState() {
    super.initState();
    _transitionDebounce.onElapsed = () {
      if (mounted) setState(() {});
    };
  }

  @override
  void dispose() {
    _transitionDebounce.dispose();
    super.dispose();
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(text),
        duration: const Duration(milliseconds: 800),
      ));
  }

  /// 拖动结束：乐观 seekTo（控制器先对齐本地再等轮询校正）；失败回读真实
  /// 位置（立即轮询一次）并提示一次固定文案，不让面板位置与电视永久漂移。
  Future<void> _seekTo(double seconds) async {
    final target = Duration(milliseconds: (seconds * 1000).round());
    try {
      await castController.seekTo(target);
    } catch (e, stack) {
      ErrorLog.instance.record('投屏拖动进度', e, stack);
      unawaited(castController.forceRefresh());
      _toast('该设备不支持拖动进度');
    }
  }

  Future<void> _nextEpisode() async {
    final ok = await castController.advanceNextEpisode();
    if (!ok && mounted) _toast('下一集不可用');
  }

  Future<void> _prevEpisode() async {
    final ok = await castController.jumpEpisode(-1);
    if (!ok && mounted) _toast('上一集不可用');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ListenableBuilder(
        listenable: castController,
        builder: (context, _) {
          final device = castController.currentDevice;
          final media = castController.currentMedia;
          final duration = castController.remoteDuration;
          final hasDuration = duration > Duration.zero;
          final maxSeconds = duration.inMilliseconds / 1000.0;
          final double? dragSeconds = _scrubbing ? _dragValue : null;
          final remotePosition = castController.remotePosition;
          final shownPosition = dragSeconds != null
              ? Duration(milliseconds: (dragSeconds * 1000).round())
              : remotePosition;
          // 状态徽标（TRANSITIONING 消抖：窗口内维持上一状态显示）。
          final rawState = castController.remoteTransportState;
          final hold = _transitionDebounce.shouldHold(rawState);
          final status =
              hold ? _displayedStatus : castTransportStateLabel(rawState);
          _displayedStatus = status;
          return Padding(
            padding: const EdgeInsets.all(16),
            // 控件增多（进度条/上下集）：矮窗口（横屏手机）下防溢出。
            child: SingleChildScrollView(
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
                        // null-aware element（?status）：与上面的 if-null 同义。
                        ?status,
                        if (media != null) media.title,
                        if (shownPosition > Duration.zero) _fmt(shownPosition),
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // 取流指示（R1）：电视是否来取过流——区分「网络/防火墙问题」
                  // 与「格式问题」的最快信号。数据随既有轮询（ListenableBuilder）
                  // 刷新；点击打开诊断弹窗（明细/防火墙指引，不重复实现）。
                  if (castFetchIndicatorText(
                        CastDiagnostics.instance.mediaRequests,
                        playing: status == '播放中',
                      )
                      case final fetchLine?)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.stream,
                          size: 18, color: theme.colorScheme.outline),
                      title: Text(fetchLine, style: theme.textTheme.bodySmall),
                      trailing: Icon(Icons.chevron_right,
                          size: 16, color: theme.colorScheme.outline),
                      onTap: () => showCastDiagnostics(
                        context,
                        scope: widget.scope,
                        device: device,
                        stage: '投屏中',
                      ),
                    ),
                  // 进度条：仅当远端回报真实时长时显示（直播/未知时长只留文本）。
                  if (hasDuration)
                    Row(
                      children: [
                        Text(_fmt(shownPosition),
                            style: theme.textTheme.bodySmall),
                        Expanded(
                          child: Slider(
                            value: (dragSeconds ??
                                    remotePosition.inMilliseconds / 1000.0)
                                .clamp(0.0, maxSeconds),
                            max: maxSeconds,
                            onChangeStart: (_) =>
                                setState(() => _scrubbing = true),
                            onChanged: (v) => setState(() => _dragValue = v),
                            onChangeEnd: (v) {
                              setState(() {
                                _scrubbing = false;
                                _dragValue = null;
                              });
                              unawaited(_seekTo(v));
                            },
                          ),
                        ),
                        Text(_fmt(duration), style: theme.textTheme.bodySmall),
                      ],
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
                  // 上一集/下一集：复用连播链路（手动换集不重复起停中继）。
                  // 回调未注入（直播/无队列场景）时按钮置灰。
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: castController.onEpisodeJump == null
                            ? null
                            : _prevEpisode,
                        icon: const Icon(Icons.skip_previous),
                        label: const Text('上一集'),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: castController.onNextEpisode == null
                            ? null
                            : _nextEpisode,
                        icon: const Icon(Icons.skip_next),
                        label: const Text('下一集'),
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

