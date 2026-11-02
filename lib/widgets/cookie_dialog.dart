import 'package:flutter/material.dart';

/// 书源鉴权编辑结果。
typedef BookSourceAuth = ({String cookie, String userAgent});

/// 书源 Cookie + User-Agent 编辑对话框。
///
/// Cloudflare 的 `cf_clearance` 与 UA 绑定，两者必须成对填写，否则依旧 403；
/// 登录态站点只需要 Cookie。返回 null 表示取消。
Future<BookSourceAuth?> showBookSourceAuthDialog(
  BuildContext context, {
  required String title,
  String cookie = '',
  String userAgent = '',
}) async {
  final cookieController = TextEditingController(text: cookie);
  final uaController = TextEditingController(text: userAgent);
  final result = await showDialog<BookSourceAuth>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Cookie / UA · $title'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '站点有 Cloudflare 人机校验时（返回 403「Just a moment」）：\n'
              '1. 用浏览器打开该站点并通过校验；\n'
              '2. F12 → Application → Cookies，复制 cf_clearance 等整行；\n'
              '3. 同一次请求的 User-Agent 也一并粘贴（Cookie 与 UA 绑定）。',
              style: TextStyle(fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: cookieController,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Cookie',
                hintText: 'cf_clearance=...',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: uaController,
              minLines: 1,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'User-Agent（留空用内置 Chrome UA）',
                hintText: 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) ...',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop((
            cookie: cookieController.text.trim(),
            userAgent: uaController.text.trim(),
          )),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  cookieController.dispose();
  uaController.dispose();
  return result;
}
