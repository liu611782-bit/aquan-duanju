/// 准入询问弹窗（11-07-cast-receiver-advanced R1.4）：陌生设备首次投送时
/// 经 rootNavigatorKey 全局弹出——**不依赖接收端播放页打开**（首投即问）。
///
/// 「允许 / 拒绝 + 记住此设备」勾选；调用方（main 注入的
/// `admissionPromptHandler`）拿返回值写策略名单。30s 超时由策略层兜底
/// （超时 = 拒绝），弹窗不自带计时器。
library;

import 'package:flutter/material.dart';

import '../core/castd/receiver_admission.dart';

/// 弹全局准入询问（未响应关闭 = 拒绝，不记住）。
Future<AdmissionPromptOutcome> showReceiverAdmissionDialog(
  BuildContext context, {
  required String ip,
  required String userAgent,
}) async {
  final outcome = await showDialog<AdmissionPromptOutcome>(
    context: context,
    // 点弹窗外部不关闭：准入决定必须显式做出（超时路径由策略层兜底）。
    barrierDismissible: false,
    builder: (_) => _ReceiverAdmissionDialog(ip: ip, userAgent: userAgent),
  );
  return outcome ?? const AdmissionPromptOutcome(allow: false);
}

class _ReceiverAdmissionDialog extends StatefulWidget {
  const _ReceiverAdmissionDialog({required this.ip, required this.userAgent});

  final String ip;
  final String userAgent;

  @override
  State<_ReceiverAdmissionDialog> createState() =>
      _ReceiverAdmissionDialogState();
}

class _ReceiverAdmissionDialogState extends State<_ReceiverAdmissionDialog> {
  bool _remember = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final device = widget.ip.isEmpty ? '未知设备' : widget.ip;
    return AlertDialog(
      title: const Text('投屏请求'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('设备 $device 请求投屏到本机', style: theme.textTheme.bodyMedium),
          if (widget.userAgent.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                widget.userAgent,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ),
          CheckboxListTile(
            value: _remember,
            onChanged: (v) => setState(() => _remember = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('记住此设备'),
            subtitle: const Text('下次投送不再询问'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            AdmissionPromptOutcome(allow: false, remember: _remember),
          ),
          child: const Text('拒绝'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            AdmissionPromptOutcome(allow: true, remember: _remember),
          ),
          child: const Text('允许'),
        ),
      ],
    );
  }
}
