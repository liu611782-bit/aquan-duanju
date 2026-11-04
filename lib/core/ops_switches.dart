import 'dart:io';

import 'package:meta/meta.dart';

/// 运维急停开关（`app_ops.yaml`）。
///
/// 约定：**功能开关一律放在应用内设置**，配置文件只保留「出了事要立刻停掉」
/// 的几项。这里刻意不引入 YAML 依赖——只解析 `key: true/false` 这一种子集，
/// 任何语法错误都按「全部关闭」处理，绝不因为配置文件写坏而启动失败。
///
/// 查找顺序（找到第一个存在的就用）：
/// 1. 可执行文件同级目录（便携包/运维直接替换）；
/// 2. 应用支持目录（数据目录）。
///
/// 支持的键：
/// ```yaml
/// # 停止自动找源（含后台调度与手动触发）
/// disable_auto_source: true
/// # 停止自动检查更新（手动检查仍可用）
/// disable_auto_update: true
/// # 停止自动重建合并源（手动重建仍可用）
/// disable_auto_merge: true
/// ```
class OpsSwitches {
  OpsSwitches._();

  static const String fileName = 'app_ops.yaml';

  /// 自动找源急停：连手动「立即找源」一并拒绝（避免后台被反复触发）。
  static bool disableAutoSource = false;

  /// 自动检查更新急停：只拦启动后的静默检查，不影响用户手动点。
  static bool disableAutoUpdate = false;

  /// 合并源自动重建急停：保留现有 `merged_sources.json` 不再覆盖。
  static bool disableAutoMerge = false;

  /// 实际读取到的文件路径（空 = 没有配置文件）。
  static String loadedFrom = '';

  static bool get anyActive =>
      disableAutoSource || disableAutoUpdate || disableAutoMerge;

  /// 启动时调用一次；失败静默（急停文件不能成为启动风险）。
  static Future<void> load({Directory? supportDirectory}) async {
    final candidates = <String>[
      _executableDirPath(),
      if (supportDirectory != null) supportDirectory.path,
    ];
    for (final dir in candidates) {
      if (dir.isEmpty) continue;
      final file = File('$dir${Platform.pathSeparator}$fileName');
      try {
        if (!await file.exists()) continue;
        final values = parse(await file.readAsString());
        disableAutoSource = values['disable_auto_source'] ?? false;
        disableAutoUpdate = values['disable_auto_update'] ?? false;
        disableAutoMerge = values['disable_auto_merge'] ?? false;
        loadedFrom = file.path;
        return;
      } catch (_) {
        // 读不动就跳过，继续找下一个位置。
      }
    }
  }

  /// 解析极简 YAML：`key: value`，值只认布尔与 0/1、on/off、yes/no。
  @visibleForTesting
  static Map<String, bool> parse(String text) {
    final out = <String, bool>{};
    for (final rawLine in text.split(RegExp(r'\r?\n'))) {
      var line = rawLine;
      final hash = line.indexOf('#');
      if (hash >= 0) line = line.substring(0, hash);
      line = line.trim();
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).trim().toLowerCase();
      final value = line.substring(colon + 1).trim().toLowerCase();
      if (key.isEmpty || value.isEmpty) continue;
      out[key] = switch (value) {
        'true' || 'yes' || 'on' || '1' => true,
        'false' || 'no' || 'off' || '0' => false,
        _ => false,
      };
    }
    return out;
  }

  @visibleForTesting
  static void reset() {
    disableAutoSource = false;
    disableAutoUpdate = false;
    disableAutoMerge = false;
    loadedFrom = '';
  }

  static String _executableDirPath() {
    try {
      return File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      return '';
    }
  }
}
