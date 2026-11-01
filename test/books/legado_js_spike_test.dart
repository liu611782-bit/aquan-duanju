import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';

import '../spider/native_lib_guard.dart';

/// 通道语义契约锁（spike）：flutter_qjs 同步通道（onMessage/sendMessage）的
/// 编解码行为，LegadoJsHost 的 shim 依赖它。需要原生库，默认 skip
/// （AQUAN_SPIDER_TESTS=1 + Debug dll，跑法同 spider 集成测试）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('同步通道：handler 收到什么、返回什么 JS 才拿到什么', () {
    if (!ensureFlutterQjsLibrary()) return;
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024);
    Object? gotArgs;
    Object? rawArgs;
    rt.onMessage('spike', (args) {
      rawArgs = args;
      if (args is String) {
        gotArgs = jsonDecode(args);
      } else {
        gotArgs = args;
      }
      // 返回一个 Map（信封形态之一）。
      return {'ok': true, 'n': 42, 's': 'hello'};
    });
    try {
      rt.enableHandlePromises();
      final raw = rt.evaluate(
          'var raw = sendMessage("spike", JSON.stringify({a:1})); '
          'JSON.stringify({type: typeof raw, isStr: typeof raw === "string", val: String(raw)})')
          .stringResult;
      // ignore: avoid_print
      print('SPIKE raw-from-js: $raw');
      // ignore: avoid_print
      print('SPIKE dart-handler gotArgs: $gotArgs (raw: $rawArgs)');
      expect(raw, isNotEmpty);
    } finally {
      rt.dispose();
    }
  });

  test('同步通道：handler 返回字符串的形态', () {
    if (!ensureFlutterQjsLibrary()) return;
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024);
    rt.onMessage('spike2', (args) => jsonEncode({'ok': true, 'v': 'x'}));
    try {
      rt.enableHandlePromises();
      final raw = rt.evaluate(
          'var raw = sendMessage("spike2", "ping"); '
          'JSON.stringify({type: typeof raw, val: String(raw)})').stringResult;
      // ignore: avoid_print
      print('SPIKE2 handler-returns-json-string, js sees: $raw');
    } finally {
      rt.dispose();
    }
  });

  test('eval 完成值捕获（var 声明 + 表达式）', () {
    if (!ensureFlutterQjsLibrary()) return;
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024);
    try {
      rt.enableHandlePromises();
      final v = rt.evaluate(
          'globalThis.__lv = eval(${jsonEncode('var a = 3; var b = "x"; a * 2 + b')}); '
          'var t = globalThis.__lv; '
          '(typeof t === "undefined" || t === null) ? "" : '
          '(typeof t === "object" ? JSON.stringify(t) : String(t))').stringResult;
      expect(v, '6x');
    } finally {
      rt.dispose();
    }
  });
}
