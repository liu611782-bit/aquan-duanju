/// 接收端 UI/启动接线门面（Phase B）：对设置页与投屏面板暴露开关语义
/// （开 → ReceiverController.start()，关 → byebye + 清会话 + 关页），
/// 对来投会话暴露页面导航（新投替换只更新会话，不关页重开）。
///
/// 持久化边界：开关与名称的落盘在 SettingsStore（`cast.receiverEnabled` /
/// `cast.receiverName`），本类只管运行态——core 不反向依赖 store 层，
/// 调用方（开关 UI / main bootstrap）负责读写设置。
///
/// 平台分支（R1.4）：桌面（Windows/macOS/Linux）直接起本地接收端栈；
/// Android 额外经 [ReceiverAndroidBridge] 起前台服务 + 组播锁（失败回滚
/// 并上抛，开关 UI 统一回弹 + 提示）；iOS 等其余平台不暴露开关。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../error_log.dart';
import 'receiver_android_bridge.dart';
import 'receiver_controller.dart';
import 'receiver_player_adapter.dart';
import 'receiver_player_mediakit.dart';

/// 允许做接收端的平台：桌面（Windows / macOS / Linux）∨ Android（R1.4）。
bool receiverPlatformSupported() =>
    Platform.isWindows ||
    Platform.isMacOS ||
    Platform.isLinux ||
    Platform.isAndroid;

class CastReceiverService extends ChangeNotifier {
  CastReceiverService._() {
    _controller = _createController();
    if (Platform.isAndroid) {
      _attachAndroidBridge(ReceiverAndroidBridge());
    }
  }

  /// 测试构造：注入自管控制器（不动 [instance]）；来投回调统一由门面
  /// 接管（UDN loader 在注入的 controller 上自行传入）。测试宿主非
  /// Android，需模拟 Android 平台分支时注入 [androidBridge] 替身。
  @visibleForTesting
  CastReceiverService.forTest({
    ReceiverController? controller,
    ReceiverAndroidBridge? androidBridge,
  }) {
    _controller = controller ?? _createController();
    _controller!.onIncomingSession = _onIncomingSession;
    if (androidBridge != null) {
      _attachAndroidBridge(androidBridge);
    }
  }

  static final CastReceiverService instance = CastReceiverService._();

  /// 平台判定覆盖（widget 测试模拟非桌面平台；生产置 null）。
  @visibleForTesting
  static bool? platformSupportedForTest;

  static bool get platformSupported =>
      platformSupportedForTest ?? receiverPlatformSupported();

  /// Android 平台桥（前台服务/组播锁/通知/音频焦点事件）。桌面为 null：
  /// 不创建通道、开关路径与 Phase B 完全一致；仅 Android（或测试注入）非空。
  ReceiverAndroidBridge? androidBridge;

  ReceiverController? _controller;

  ReceiverController get controller => _controller!;

  /// UDN 持久化（main bootstrap 注入 `CastStore.ensureReceiverUdn`；
  /// 未注入时控制器临时生成 UDN，重启变化仅影响发送端旧设备记忆）。
  Future<String?> Function()? udnLoader;

  /// 打开接收端播放页（main 注入 rootNavigatorKey.push；只在页未开时调用）。
  /// 返回是否真的开出了页（导航未就绪时返回 false，页标不置位）。
  bool Function(ReceiverSession session)? openSessionPage;

  /// 关闭接收端播放页（开关关闭且页开着时调用；main 注入 popUntil）。
  void Function()? closeSessionPage;

  /// 当前会话：播放页监听（新投替换 → 值更新，不关页；接收端关闭 → null）。
  final ValueNotifier<ReceiverSession?> session = ValueNotifier(null);

  bool _pageOpen = false;

  bool get enabled => _controller!.running;

  /// 接收端口（未运行 null；设置副标题显示用）。
  int? get port => _controller!.port;

  /// 生产引擎工厂：惰性创建独立 media_kit Player（首次 start 才初始化）。
  ReceiverPlayer _createPlayer() {
    if (receiverPlatformSupported()) {
      return MediaKitReceiverPlayer();
    }
    // iOS 等未支持平台（守卫后理论不可达）：stub 保底，不初始化媒体库。
    return StubReceiverPlayer();
  }

  ReceiverController _createController() {
    return ReceiverController(
      playerFactory: _createPlayer,
      udnLoader: () async => udnLoader?.call(),
      onIncomingSession: _onIncomingSession,
    );
  }

  /// 开 / 关接收端。[name] 为用户改过的接收名（空串 = 用默认名）。
  /// 返回实际运行态（启动失败 → false，异常已进 ErrorLog 并原样上抛）。
  ///
  /// Android 分支（R1.4）：开启时在本地接收端栈起好后调 [startPlatformService]
  /// （前台服务 + 组播锁）；失败回滚已起的栈再上抛，开关 UI 统一回弹 + 提示。
  Future<bool> setEnabled(bool value, {String? name}) async {
    final controller = _controller!;
    if (value) {
      controller.friendlyNameOverride =
          (name == null || name.isEmpty) ? null : name;
      try {
        await controller.start();
        await startPlatformService();
      } catch (_) {
        // 平台桥失败（MissingPlugin / 服务启动异常）：回滚接收端栈再上抛。
        if (controller.running) {
          try {
            await controller.stop();
          } catch (e, st) {
            ErrorLog.instance.record('DLNA 接收·回滚停止', e, st);
          }
        }
        rethrow;
      } finally {
        notifyListeners();
      }
      return controller.running;
    }
    // 关闭：先下 Android 前台服务（通知即刻消失），再 byebye + 清订阅/会话
    // （controller.stop）+ 尽力停引擎 + 关页。
    final wasRunning = controller.running;
    await stopPlatformService();
    await controller.stop();
    if (wasRunning) {
      try {
        await controller.playerOrNull?.stop();
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·关闭引擎', e, st);
      }
    }
    session.value = null;
    if (_pageOpen) {
      _pageOpen = false;
      _safeCall(closeSessionPage, '关闭接收端播放页');
    }
    notifyListeners();
    return false;
  }

  /// Android 前台服务 + MulticastLock（开关开启时调用；桌面无桥直接返回）。
  /// 失败上抛，由 [setEnabled] 回滚已起的接收端栈。
  Future<void> startPlatformService() async {
    final bridge = androidBridge;
    if (bridge == null) return;
    await bridge.receiverStart(port: controller.port);
  }

  /// Android 前台服务下线（开关关闭时调用；尽力而为，异常进 ErrorLog）。
  Future<void> stopPlatformService() async {
    final bridge = androidBridge;
    if (bridge == null) return;
    await bridge.receiverStop();
  }

  /// Android 平台桥接线（生产仅 Android；测试注入替身走同一路径）。
  void _attachAndroidBridge(ReceiverAndroidBridge bridge) {
    androidBridge = bridge;
    bridge.onPauseRequested = _onAudioFocusPause;
    bridge.listen();
  }

  /// Android 音频焦点被抢占（receiverPause 事件，R1.3）：引擎 pause →
  /// 状态 PAUSED_PLAYBACK；恢复后不自动续播（用户手动 / 发送端 Play）。
  Future<void> _onAudioFocusPause() async {
    final player = _controller?.playerOrNull;
    if (player == null) return;
    try {
      await player.pause();
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·音频焦点暂停', e, st);
    }
  }

  /// 开机自启（main bootstrap 调用；设置里开着 → 直接起接收端）。
  /// 失败只进 ErrorLog，不阻断启动。
  Future<void> startIfEnabled({required bool enabledFlag, String? name}) async {
    if (!enabledFlag) return;
    try {
      await setEnabled(true, name: name);
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·开机自启', e, st);
    }
  }

  /// 运行中改名（空串 = 回默认名；描述 XML 闭包读实时值，下一次请求生效）。
  void rename(String name) {
    controller.friendlyNameOverride = name.isEmpty ? null : name;
    notifyListeners();
  }

  void _onIncomingSession(ReceiverSession session) {
    this.session.value = session;
    // Android：通知栏「正在接收：<标题>」+ 服务内申请音频焦点（失败静默）。
    unawaited(androidBridge?.pushSessionTitle(session.title));
    if (!_pageOpen) {
      _pageOpen = _openPage(session);
    }
    notifyListeners();
  }

  bool _openPage(ReceiverSession session) {
    final open = openSessionPage;
    if (open == null) return false;
    try {
      return open(session);
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·打开接收端播放页', e, st);
      return false;
    }
  }

  /// 播放页 dispose 回调（引擎 Stop 由页面负责，这里只复位页标）。
  void notifyPageClosed() {
    _pageOpen = false;
    notifyListeners();
  }

  bool _safeCall(void Function()? action, String label) {
    if (action == null) return false;
    try {
      action();
      return true;
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·$label', e, st);
      return false;
    }
  }

  @override
  void dispose() {
    session.dispose();
    super.dispose();
  }
}
