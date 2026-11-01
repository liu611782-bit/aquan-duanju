import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';

/// so-novel `@js:` 的 `func(r)` 执行器（QuickJS 承载，research §3）。
///
/// 契约：`r` 是 String、返回 String；模板尾部补 `return r;`（用户代码只改 r 不 return
/// 时回落 r）；每次调用用 IIFE 隔离避免脏全局；JS 异常**上抛**（不静默产错值）。
///
/// 依赖 flutter_qjs 原生插件，**只在真机/桌面运行时可用**（`flutter test` 无插件），
/// 故本类不写单测，由 so-novel P3 设备实测覆盖；runtime 层用可注入的 runJs 做离线测试。
class SoNovelFunc {
  SoNovelFunc();

  JavascriptRuntime? _rt;

  String call(String code, String input) {
    final rt = _rt ??= QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    final src = StringBuffer()
      ..write('(function(){try{function func(r){\n')
      ..write(code)
      ..write('\n;return r;} var __o=func(')
      ..write(jsonEncode(input))
      ..write('); return String(__o);}catch(e){throw new Error(String(e));}})()');
    final res = rt.evaluate(src.toString());
    if (res.isError) {
      throw StateError('so-novel @js 执行失败: ${res.stringResult}');
    }
    return res.stringResult;
  }

  void dispose() {
    try {
      _rt?.dispose();
    } catch (_) {}
    _rt = null;
  }
}
