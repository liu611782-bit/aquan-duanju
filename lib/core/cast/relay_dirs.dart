/// 中继临时目录与 CA 证书包定位（11-08-android-cast-device-fixes）。
///
/// 为什么存在：Android 应用进程没有 TMPDIR 环境变量，Go 侧
/// `os.MkdirTemp("", …)` 落到不存在的 `/tmp`（真机实证：
/// CAST_RELAY_INTERNAL「中继启动失败，请重试」）。同理 Android 没有
/// OpenSSL 默认证书路径，https 上游握手可能因证书校验失败早退。
///
/// Dart 侧解析 path_provider 临时目录、把内置 CA 包（assets/cast/cacert.pem）
/// 拷进临时目录，经 `castRelayStart` 的 `work_dir`/`ca_file` 透传给 Go；
/// 两字段为空时 Go 回落现状（桌面零回归）。桌面端也统一走这里
/// （%TEMP% 同样可用），让会话/孤儿清理只有一个口径。
library;

import 'dart:io' show File, Platform;

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

class RelayDirs {
  RelayDirs._();

  /// 测试注入点：真机路径解析在 flutter test 里无插件通道，注入假路径覆盖。
  /// 注入即重置已 memoize 的结果（防测试间静态状态互串）。
  // ignore: avoid_setters_without_getters
  static set debugWorkDirResolver(Future<String?> Function()? value) {
    _workDirResolver = value;
    _workDir = null;
  }

  // ignore: avoid_setters_without_getters
  static set debugCaFileResolver(Future<String?> Function()? value) {
    _caFileResolver = value;
    _caFileFuture = null;
  }

  static Future<String?> Function()? _workDirResolver;
  static Future<String?> Function()? _caFileResolver;

  static String? _workDir;
  static Future<String?>? _caFileFuture;

  /// 中继临时目录基址（memoize）。解析失败返回 null：payload 置空，
  /// Go 侧回落 os.TempDir()（桌面现状）。
  static Future<String?> workDir() async {
    final resolver = _workDirResolver;
    if (resolver != null) return resolver();
    if (_workDir != null) return _workDir;
    try {
      _workDir = (await getTemporaryDirectory()).path;
    } on Exception {
      // path_provider 不可用（测试环境/插件缺失）：不阻断投屏，Go 走现状。
      _workDir = null;
    }
    return _workDir;
  }

  /// CA 证书包路径：把 assets/cast/cacert.pem 拷到临时目录后返回绝对路径。
  /// 已拷贝过直接复用；任何一步失败返回 null（不传 ca_file，Go 现状）。
  static Future<String?> caFile() =>
      _caFileFuture ??= (_caFileResolver ?? _resolveCaFile)();

  static Future<String?> _resolveCaFile() async {
    try {
      final base = await workDir();
      if (base == null || base.isEmpty) return null;
      final file = File(
          '$base${base.endsWith(Platform.pathSeparator) ? '' : Platform.pathSeparator}aquan-cast-ca.pem');
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/cast/cacert.pem');
        await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      }
      return file.path;
    } on Exception {
      // asset 缺失/写盘失败：https 上游交给设备现状（部分 ROM 仍可握手）。
      return null;
    }
  }
}
