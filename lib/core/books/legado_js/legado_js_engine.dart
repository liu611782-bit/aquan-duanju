import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'legado_js_host.dart';

/// legado js 规则引擎（主 isolate 侧门面）。
///
/// 形态（design.md / research §5.2③）：每次 [eval] 在独立 isolate 里重建 QuickJS
/// （fongmi 已投产模式），同步通道 + 后台 isolate 内阻塞 FFI `syncHttp`——给 js 以
/// Rhino 式**同步**语义（`java.ajax(url).body()` 原样可跑），零源码改写、按 eval 天然隔离。
///
/// 测试：[transport] 注入纯函数（isolate 内回调，禁碰主 isolate 状态），摆脱
/// AquaLibrary 与 flutter_qjs 之外的依赖；真 QuickJS 用例需 Debug dll PATH。
class LegadoJsEngine {
  LegadoJsEngine({
    this.transport,
    this.enforceSsrf = true,
    this.profilePath = 'legado-js',
  });

  /// 生产 = null（isolate 内阻塞 AquaCall('syncHttp')）；测试 = 纯函数。
  final LegadoJsTransport? transport;
  final bool enforceSsrf;

  /// AquaNew 设备档案键（仅 FFI 路径用，任意稳定字符串）。
  final String profilePath;

  Future<LegadoJsResult> eval(
    String code, {
    Map<String, Object?> bindings = const {},
    String jsLib = '',
    Map<String, String> cacheIn = const {},
    Map<String, String> cookieIn = const {},
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final req = LegadoJsRequest(
      code: code,
      bindings: bindings,
      jsLib: jsLib,
      cacheIn: cacheIn,
      cookieIn: cookieIn,
      transport: transport,
      enforceSsrf: enforceSsrf,
      profilePath: profilePath,
    );
    final String raw;
    try {
      raw = await Isolate.run(() => LegadoJsHost.run(req)).timeout(timeout);
    } on TimeoutException {
      throw LegadoJsException('js 执行超时（${timeout.inSeconds}s）');
    }
    final Map<String, dynamic> env;
    try {
      env = jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      throw LegadoJsException('js 引擎返回无法解析: ${raw.substring(0, raw.length.clamp(0, 120))}');
    }
    final logs = [for (final l in (env['logs'] as List? ?? const [])) '$l'];
    if (env['ok'] != true) {
      throw LegadoJsException('${env['error']}');
    }
    return LegadoJsResult(
      value: _maybeJson('${env['value']}'),
      cacheOut: _strMap(env['cacheOut']),
      cookieOut: _strMap(env['cookieOut']),
      logs: logs,
    );
  }

  /// js 返回值约定：宿主侧已 JSON.stringify；数组/对象还原成 Dart 结构供列表规则用。
  static Object? _maybeJson(String v) {
    final t = v.trim();
    if (t.startsWith('[') || t.startsWith('{')) {
      try {
        return jsonDecode(v);
      } catch (_) {/* 纯文本碰巧以 {/[ 开头：按字符串 */}
    }
    return v;
  }

  static Map<String, String> _strMap(Object? raw) {
    if (raw is Map) {
      return {
        for (final e in raw.entries) e.key.toString(): e.value?.toString() ?? ''
      };
    }
    return const {};
  }
}

class LegadoJsResult {
  const LegadoJsResult({
    required this.value,
    this.cacheOut = const {},
    this.cookieOut = const {},
    this.logs = const [],
  });

  /// String（标量/文本）或 List/Map（列表规则、JSON 输出）。
  final Object? value;
  final Map<String, String> cacheOut;
  final Map<String, String> cookieOut;
  final List<String> logs;
}

class LegadoJsException implements Exception {
  const LegadoJsException(this.message);
  final String message;
  @override
  String toString() => message;
}
