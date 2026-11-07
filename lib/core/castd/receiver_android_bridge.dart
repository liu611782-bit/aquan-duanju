/// Android 接收端平台桥（Phase A）：前台服务 + MulticastLock + 通知 +
/// 音频焦点事件的唯一 Dart 入口。接收端 HTTP/SSDP/播放栈复用 castd 纯 Dart
/// 实现，本桥只负责 Android 平台侧的保活与系统事件。
///
/// ## 通道协议（与 MainActivity.kt / ReceiverService.kt 对齐）
///
/// **aquan/cast**（Dart→Kotlin；MainActivity 的 when 分支分发，与发送端
/// 投屏/镜像方法共用同一条通道）：
/// - `receiverStart {port:int}` → `int`：起 ReceiverService 前台服务 +
///   MulticastLock（SSDP 组播收包前提），顺带请求 Android 13+ 通知权限
///   （拒绝仍可投，仅无通知）；回显 Dart 接收端 HTTP 监听端口。
/// - `receiverStop {}` → `void`：停前台服务 + 释放组播锁。
/// - `setSessionMeta {title:String?}` → `void`：通知栏「正在接收：<标题>」；
///   首个会话同时申请音频焦点（AUDIOFOCUS_GAIN）。
///
/// **aquan/castd**（Kotlin→Dart 事件，[listen] 注册 handler）：
/// - `receiverPause`：音频焦点被抢占（来电/其他播放器）→ 引擎 pause 并上报
///   PAUSED_PLAYBACK；恢复后不自动续播（用户手动/发送端 Play）。
///
/// 为什么事件不共用 aquan/cast：MirrorController（镜像 Dart 桥）构造即独占
/// 注册 aquan/cast 的 handler，而 Dart 侧每个通道名只允许一个 handler——接收
/// 端若在同一条通道上注册会把镜像事件顶掉（反之镜像先注册则丢 receiverPause）。
/// 接收端控制方法沿用 aquan/cast，事件回推单独开通道，两侧互不影响。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../error_log.dart';

/// aquan/castd：Kotlin→Dart 接收端事件通道（见库头「通道协议」）。
const MethodChannel kReceiverEventChannel = MethodChannel('aquan/castd');

class ReceiverAndroidBridge {
  ReceiverAndroidBridge();

  static const MethodChannel _channel = MethodChannel('aquan/cast');

  /// 音频焦点被抢占（receiverPause 事件）→ 引擎 pause。生产由
  /// CastReceiverService 注入；null = 忽略事件。
  Future<void> Function()? onPauseRequested;

  bool _listening = false;

  /// 注册 receiverPause 事件监听（幂等；开关开启前调用）。
  void listen() {
    if (_listening) return;
    _listening = true;
    kReceiverEventChannel.setMethodCallHandler((call) async {
      if (call.method == 'receiverPause') {
        await onPauseRequested?.call();
      }
      return null;
    });
  }

  /// 起前台服务 + 组播锁；[port] 为 Dart 接收端 HTTP 监听端口（原生侧原样
  /// 回显）。未实现（MissingPluginException）/失败原样上抛，由调用方回滚
  /// 开关与已起的接收端栈。
  Future<int?> receiverStart({int? port}) =>
      _channel.invokeMethod<int>('receiverStart', {'port': port});

  /// 停前台服务 + 释放组播锁（尽力而为：服务可能已被系统回收，异常只进
  /// ErrorLog，不阻断关闭流程）。
  Future<void> receiverStop() async {
    try {
      await _channel.invokeMethod<void>('receiverStop');
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·停止平台服务', e, st);
    }
  }

  /// 推送当前会话标题（通知栏「正在接收：<标题>」+ 服务内申请音频焦点）。
  /// 失败静默进 ErrorLog——通知只是保活副产物，不阻断投送链。
  Future<void> pushSessionTitle(String? title) async {
    try {
      await _channel.invokeMethod<void>('setSessionMeta', {'title': title});
    } on MissingPluginException {
      // 平台桥未注册（桌面/测试宿主）：静默。
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·推送会话标题', e, st);
    }
  }
}
