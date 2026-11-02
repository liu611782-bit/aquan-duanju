import 'package:flutter/material.dart';

/// 书源 Cookie 编辑对话框（Cloudflare `cf_clearance` / 登录态会话）。
///
/// 返回编辑后的 Cookie（empty = 清空）；取消返回 null。
Future<String?> showBookSourceCookieDialog(
  BuildContext context, {
  required String title,
  required String initial,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Cookie · $title'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '粘贴浏览器里的 Cookie（形如 `cf_clearance=xxx; other=yyy`）。'
            '站点有 Cloudflare 人机校验时，这一步能绕过 403；'
            'Cookie 过期后需重新复制。留空表示不发送 Cookie。',
            style: TextStyle(fontSize: 12, height: 1.5),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: controller,
            minLines: 3,
            maxLines: 6,
            decoration: const InputDecoration(
              hintText: 'cf_clearance=...',
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
