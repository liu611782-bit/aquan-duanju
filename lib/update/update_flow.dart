import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'update_service.dart';

/// 有新版本时的交互入口：Windows 且带安装包时给「一键更新」
/// （下载 setup.exe 带进度，静默安装后本应用退出）；其它平台跳发布页。
Future<void> updateInteractive(BuildContext context) async {
  final service = UpdateService.instance;
  final canInstall = service.canInstallInApp;
  if (!canInstall) {
    await service.openReleasePage();
    return;
  }
  final isAndroid = Platform.isAndroid;
  // 异步间隙前取好引用，避免 BuildContext 跨 await。
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final action = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('发现新版本 v${service.latestVersion}'),
      content: Text(isAndroid
          ? '一键更新会下载安装包并调起系统安装器；'
              '首次安装需允许「安装未知应用」。'
          : '一键更新会下载安装包并自动安装，安装过程中应用会关闭，'
              '完成后请重新打开阿圈短剧。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, 'browser'),
          child: const Text('浏览器打开'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, 'install'),
          child: const Text('一键更新'),
        ),
      ],
    ),
  );
  if (action == 'browser') {
    await service.openReleasePage();
    return;
  }
  if (action != 'install') return;

  // 进度框不 await：下载成功后应用直接退出；失败时由下面关闭。
  if (!context.mounted) return;
  unawaited(showDialog<void>(
    useRootNavigator: true,
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text('正在下载 v${service.latestVersion}'),
        content: ValueListenableBuilder<double?>(
          valueListenable: service.downloadProgress,
          builder: (context, progress, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 10),
              Text(progress == null
                  ? '准备下载…'
                  : '${(progress * 100).toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ),
    ),
  ));
  try {
    await service.downloadAndInstall();
  } catch (e) {
    navigator.pop();
    messenger.showSnackBar(
        SnackBar(content: Text('更新下载失败，可到发布页手动下载：$e')));
  }
}
