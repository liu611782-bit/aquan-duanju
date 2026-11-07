/// 「允许其他设备投到本机」开关（设置页与投屏面板共用入口，R4.1）。
///
/// - 平台守卫（R1.4）：桌面 ∨ Android 可见；iOS 等其余平台整块隐藏。
///   Android 开关经平台桥起前台服务（失败回滚 + SnackBar，与桌面启动失败
///   同一提示口径）；桌面行为不变；
/// - 开 → [CastReceiverService.setEnabled] (start)；关 → stop（byebye+清会话，
///   页开着会一并关闭）；持久化由调用方经 [onPersistEnabled] 写 SettingsStore；
/// - 防火墙提示：开启后提供「复制防火墙放行命令」（M0 的 program 级生成器，
///   Windows 专属；局域网搜不到本机时的自助手段）；
/// - 接收名可在设置页改名（R4.2；空名 = 默认「<主机名>（aquan 接收）」）；
/// - 投送准入（11-07-cast-receiver-advanced R1.5）：设置页形态增准入模式三选
///   与允许列表管理入口；运行态写 [CastReceiverService.admission]，落盘经
///   [onAdmissionModeChanged] / [onAdmissionListsChanged] 回调（core 不反向
///   依赖 store 层）。面板紧凑形态不变。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/cast/cast_diagnostics.dart';
import '../core/castd/receiver_admission.dart';
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
    this.admissionMode = 'anyone',
    this.onAdmissionModeChanged,
    this.onAdmissionListsChanged,
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

  /// 持久化的准入模式（anyone/ask/whitelist；非法回落 anyone 显示）。
  final String admissionMode;

  /// 准入模式落盘（设置页传 `settings.castReceiverAdmissionMode = mode`）。
  /// 运行态由本 tile 直接写 `receiver.admission.mode`。
  final void Function(String mode)? onAdmissionModeChanged;

  /// 名单（允许/拒绝）变化后的落盘回调：带策略出的两份 JSON 快照。
  final void Function(String allowJson, String denyJson)?
      onAdmissionListsChanged;

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
            if (!compact) ...[
              ListTile(
                dense: true,
                leading: const Icon(Icons.verified_user_outlined),
                title: const Text('投送准入'),
                subtitle: Text(
                  receiverAdmissionModeLabel(admissionMode),
                  maxLines: 2,
                ),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _pickAdmissionMode(context, receiver),
              ),
              ListTile(
                dense: true,
                leading: const Icon(Icons.rule_outlined),
                title: const Text('管理允许列表'),
                subtitle: Text(_allowListSubtitle(receiver), maxLines: 2),
                trailing: const Icon(Icons.chevron_right, size: 18),
                onTap: () => _manageAdmissionLists(context, receiver),
              ),
            ],
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

  String _allowListSubtitle(CastReceiverService receiver) {
    final allow = receiver.admission.allowEntries.length;
    final deny = receiver.admission.denyEntries.length;
    final buffer = StringBuffer('已记住 $allow 台设备');
    if (deny > 0) buffer.write(' · 拒绝名单 $deny 台');
    return buffer.toString();
  }

  /// 准入模式三选（R1.1）：运行态写策略，落盘走回调。
  Future<void> _pickAdmissionMode(
    BuildContext context,
    CastReceiverService receiver,
  ) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('投送准入'),
        children: [
          for (final mode in receiverAdmissionModes)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, mode),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text(_admissionOptionLabel(admissionMode, mode)),
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == admissionMode) return;
    receiver.admission.mode = admissionModeFromString(picked);
    onAdmissionModeChanged?.call(picked);
  }

  String _admissionOptionLabel(String current, String mode) {
    final desc = switch (mode) {
      'anyone' => '局域网内任何设备都能投送到本机',
      'ask' => '陌生设备首次投送时弹窗确认，可记住',
      'whitelist' => '只允许列表内的设备投送',
      _ => '',
    };
    final prefix = current == mode ? '✓ ' : '';
    return '$prefix${receiverAdmissionModeLabel(mode)}（$desc）';
  }

  /// 允许/拒绝名单管理（R1.5）：条目 = IP/UA/时间，单删 + 清空；
  /// 白名单模式只看允许表，拒绝名单是「每次询问」记住的拒绝。
  Future<void> _manageAdmissionLists(
    BuildContext context,
    CastReceiverService receiver,
  ) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => _AdmissionListsDialog(
        receiver: receiver,
        onChanged: () {
          onAdmissionListsChanged?.call(
            receiver.admission.encodeAllowJson(),
            receiver.admission.encodeDenyJson(),
          );
          // 名单计数显示在 tile 副标题上：变更后刷新。
          receiver.notifyAdmissionChanged();
        },
      ),
    );
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

/// 准入名单管理弹窗：允许名单 + 拒绝名单（ask 模式记住的拒绝）两个分区，
/// 条目显示 IP/UA/时间，支持单删与分区清空。变更经 [onChanged] 通知调用方
/// 持久化，并经 `receiver.notifyAdmissionChanged()` 触发本弹窗重建
/// （ListenableBuilder 监听 service，删空一个分区后区块即时消失）。
class _AdmissionListsDialog extends StatelessWidget {
  const _AdmissionListsDialog({required this.receiver, required this.onChanged});

  final CastReceiverService receiver;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: receiver,
      builder: (context, _) {
        final theme = Theme.of(context);
        final policy = receiver.admission;
        final allow = policy.allowEntries;
        final deny = policy.denyEntries;
        return AlertDialog(
          title: const Text('投送准入名单'),
          content: SizedBox(
            width: 420,
            child: (allow.isEmpty && deny.isEmpty)
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                        '暂无记录。开启「每次询问」后，勾选「记住此设备」的设备会出现在这里'),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (allow.isNotEmpty) ...[
                          _sectionHeader(context, '允许名单', allow.length, () {
                            policy.clearAllowed();
                            onChanged();
                          }),
                          for (final e in allow)
                            _entryTile(context, theme, e, () {
                              policy.removeAllowed(e.ip);
                              onChanged();
                            }),
                        ],
                        if (deny.isNotEmpty) ...[
                          _sectionHeader(context, '拒绝名单（每次询问记住）',
                              deny.length, () {
                            policy.clearDenied();
                            onChanged();
                          }),
                          for (final e in deny)
                            _entryTile(context, theme, e, () {
                              policy.removeDenied(e.ip);
                              onChanged();
                            }),
                        ],
                      ],
                    ),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  Widget _sectionHeader(
    BuildContext context,
    String label,
    int count,
    VoidCallback clear,
  ) {
    return Row(
      children: [
        Expanded(child: Text('$label（$count）')),
        TextButton(onPressed: clear, child: const Text('清空')),
      ],
    );
  }

  Widget _entryTile(
    BuildContext context,
    ThemeData theme,
    ReceiverAdmissionEntry entry,
    VoidCallback remove,
  ) =>
      ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          entry.userAgent.isEmpty ? Icons.devices_other : Icons.smartphone,
          size: 20,
        ),
        title: Text(entry.ip, style: theme.textTheme.bodyMedium),
        subtitle: Text(
          _entrySubtitle(entry),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.outline),
        ),
        trailing: IconButton(
          tooltip: '删除此条目',
          icon: const Icon(Icons.delete_outline, size: 20),
          onPressed: remove,
        ),
      );

  String _entrySubtitle(ReceiverAdmissionEntry e) {
    final time = _formatTime(e.at);
    return e.userAgent.isEmpty ? time : '${e.userAgent} · $time';
  }

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}
