/// 「允许其他设备投到本机」开关（设置页与投屏面板共用入口，R4.1）。
///
/// - 平台守卫（R1.4）：桌面 ∨ Android 可见；iOS 等其余平台整块隐藏。
///   Android 开关经平台桥起前台服务（失败回滚 + SnackBar，与桌面启动失败
///   同一提示口径）；桌面行为不变；
/// - 开 → [CastReceiverService.setEnabled] (start)；关 → stop（byebye+清会话，
///   页开着会一并关闭）；持久化由调用方经 [onPersistEnabled] 写 SettingsStore；
/// - 防火墙提示：开启后提供「复制防火墙放行命令」（M0 的 program 级生成器，
///   Windows 专属；局域网搜不到本机时的自助手段）；
/// - 接收名可在设置页改名（R4.2；空名 = 默认「<主机名>（aquan 接收）」）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cast/cast_diagnostics.dart';
import '../core/castd/receiver_service.dart';
import '../core/error_log.dart';

class CastReceiverTile extends StatelessWidget {
  const CastReceiverTile({
    super.key,
    this.service,
    this.onPersistEnabled,
    this.onRename,
    this.receiverName = '',
    this.compact = false,
    this.supported,
  });

  /// null → 全局单例（widget 测试注入替身）。
  final CastReceiverService? service;

  /// 开关落盘（设置页/面板传 `settings.castReceiverEnabled = v`；测试可省）。
  final void Function(bool enabled)? onPersistEnabled;

  /// 接收名落盘（设置页传 `settings.castReceiverName = name`；null = 不提供改名）。
  final void Function(String name)? onRename;

  /// 当前持久化的接收名（空 = 默认名）。
  final String receiverName;

  /// 投屏面板内的紧凑形态：只留开关一行（设置页还带改名/防火墙行）。
  final bool compact;

  /// 平台判定覆盖（widget 测试模拟 Android；null = 按当前平台）。
  final bool? supported;

  @override
  Widget build(BuildContext context) {
    final isSupported = supported ?? CastReceiverService.platformSupported;
    if (!isSupported) return const SizedBox.shrink();
    final receiver = service ?? CastReceiverService.instance;
    return ListenableBuilder(
      listenable: receiver,
      builder: (context, _) {
        final enabled = receiver.enabled;
        return Column(
          children: [
            SwitchListTile(
              secondary: const Icon(Icons.cast_connected_outlined),
              title: const Text('允许其他设备投到本机'),
              subtitle: Text(_subtitle(receiver, enabled), maxLines: 2),
              value: enabled,
              onChanged: (v) => unawaited(_toggle(context, receiver, v)),
            ),
            if (!compact && enabled) ...[
              if (onRename != null)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.badge_outlined),
                  title: const Text('接收名称'),
                  subtitle: Text(receiver.controller.friendlyName),
                  trailing: const Icon(Icons.edit_outlined, size: 18),
                  onTap: () => _rename(context, receiver),
                ),
              if (Platform.isWindows)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('复制防火墙放行命令'),
                  subtitle: const Text(
                    '其他设备搜不到本机或投不上时，用管理员 PowerShell 执行复制的命令',
                  ),
                  trailing: const Icon(Icons.copy_rounded, size: 18),
                  onTap: () => _copyFirewallCommand(context),
                ),
            ],
          ],
        );
      },
    );
  }

  String _subtitle(CastReceiverService receiver, bool enabled) {
    if (!enabled) {
      return '开启后，同一局域网内的设备可把视频投到本机播放';
    }
    final port = receiver.port;
    final name = receiver.controller.friendlyName;
    return port == null ? '正在启动：$name' : '$name · 端口 $port';
  }

  Future<void> _toggle(
    BuildContext context,
    CastReceiverService receiver,
    bool value,
  ) async {
    onPersistEnabled?.call(value);
    try {
      final running = await receiver.setEnabled(value, name: receiverName);
      if (!running && value && context.mounted) {
        // 启动失败（端口/网络异常已进 ErrorLog）：回滚持久化，开关随实际态回弹。
        onPersistEnabled?.call(false);
        _toast(context, '接收端启动失败，请稍后再试');
      }
    } catch (e, st) {
      ErrorLog.instance.record('DLNA 接收·开关切换', e, st);
      onPersistEnabled?.call(false);
      if (context.mounted) _toast(context, '接收端启动失败，请稍后再试');
    }
  }

  Future<void> _rename(BuildContext context, CastReceiverService receiver) async {
    final controller = TextEditingController(text: receiverName);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('接收名称'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            hintText: '留空则使用默认名称',
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null) return;
    onRename?.call(name.trim());
    receiver.rename(name.trim());
  }

  /// M0 的 program 级放行命令（与投屏诊断面板同源），文案固定中文。
  Future<void> _copyFirewallCommand(BuildContext context) async {
    final command = CastDiagnostics.buildWindowsFirewallCommand(
      programPath: Platform.resolvedExecutable,
    );
    await Clipboard.setData(ClipboardData(text: command));
    if (context.mounted) _toast(context, '已复制防火墙放行命令，可在管理员 PowerShell 中执行');
  }

  void _toast(BuildContext context, String text) {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }
}
