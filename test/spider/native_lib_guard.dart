import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// `flutter_js` 的 QuickJS 桥（基线探针 js_engine_probe_test 用）。
const String kQuickJsLibName = 'quickjs_c_bridge.dll';

/// `flutter_qjs` fork 的原生库（spider 运行时引擎，spider_synthetic_test 用）。
const String kFlutterQjsLibName = 'flutter_qjs_plugin.dll';

/// 打开这些用例的环境变量。
///
/// spider 用例本质是**集成测试**：要真实的 QuickJS 原生库 + 真实 HTTP 夹具，
/// 不能混在 `flutter test` 的单元测试里。默认 skip，显式开关才跑。
const String kSpiderTestEnv = 'AQUAN_SPIDER_TESTS';

/// 找 [name]：先看 PATH，再看常见构建目录（Debug 在前——本机流程构建 debug）。
String? findNativeLibrary(String name) {
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in path.split(Platform.pathSeparator)) {
    if (dir.trim().isEmpty) continue;
    final candidate =
        File('${dir.trim()}${Platform.pathSeparator}$name');
    if (candidate.existsSync()) return candidate.path;
  }
  for (final dir in const <String>[
    'build/windows/x64/runner/Debug',
    'build/windows/x64/runner/Release',
  ]) {
    final candidate = File('$dir${Platform.pathSeparator}$name');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}

String? findQuickJsLibrary() => findNativeLibrary(kQuickJsLibName);

String? findFlutterQjsLibrary() => findNativeLibrary(kFlutterQjsLibName);

/// 守卫：没显式开启、或缺原生库时**跳过**当前用例。
///
/// 返回 true 表示「可以继续跑」。预加载后 Windows 按模块名复用，之后
/// 引擎里的 `DynamicLibrary.open('<名字>')` 直接命中同一模块。
bool _ensureNativeLibrary(String name, String? Function() find) {
  if (Platform.environment[kSpiderTestEnv] != '1') {
    markTestSkipped(
      'QuickJS 集成测试默认跳过：用 `tool/run_spider_tests.ps1` 运行'
      '（它会构建原生库、注入 PATH 并设置 $kSpiderTestEnv=1）。',
    );
    return false;
  }
  final path = find();
  if (path == null) {
    markTestSkipped(
      '需要原生库 $name：'
      '先执行 `flutter build windows --debug`，或直接跑 `tool/run_spider_tests.ps1`。',
    );
    return false;
  }
  try {
    DynamicLibrary.open(path);
  } catch (e) {
    markTestSkipped('$name 存在但加载失败：$e');
    return false;
  }
  return true;
}

/// flutter_js 基线探针（js_engine_probe_test）。
bool ensureQuickJsLibrary() =>
    _ensureNativeLibrary(kQuickJsLibName, findQuickJsLibrary);

/// flutter_qjs 运行时引擎（spider_synthetic_test）。
bool ensureFlutterQjsLibrary() =>
    _ensureNativeLibrary(kFlutterQjsLibName, findFlutterQjsLibrary);
