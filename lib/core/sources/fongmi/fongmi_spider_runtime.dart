import 'dart:convert';
import 'dart:isolate';

import 'package:flutter_qjs/flutter_qjs.dart';

import '../../ffi_bridge.dart';

/// FongMi（TVBox 生态）.js 爬虫运行时：**后台 isolate** 里的 QuickJS。
///
/// 关键约束：FongMi 的 `req(url)` 默认 **同步**返回（Java 实现阻塞 QuickJS
/// 线程等 Java HTTP）——Dart 主 isolate 阻塞不得，因此：
/// - 引擎跑在 `Isolate.run` 的后台 isolate 里（每次调用重建，无状态）；
/// - 同步 `req` → 同步通道 `fongmi_http` → handler 内 **阻塞 AquaCall('syncHttp')**
///   （Go 侧代取网络；isolate 内阻塞合法，UI 不受影响）；
/// - flutter_qjs 是纯 FFI（无平台通道），任意 isolate 可用；
/// - 方法面为 CatVod **短名**（init/home/homeVod/category/detail/search/play），
///   返回 JSON 字符串。
class FongmiSpiderRuntime {
  FongmiSpiderRuntime._();

  /// 调用一个 FongMi .js 源方法。
  ///
  /// [jsSource] 源码（含 `__JS_SPIDER__` 占位赋值）；[httpJs] 宿主 http.js
  /// 内容（主 isolate 经 rootBundle 读好后传入——Isolate 内不碰 rootBundle）；
  /// [profilePath] AquaNew 设备档案路径（后台 FFI 需要一个 client 句柄，
  /// syncHttp 不依赖其会话状态）；[ext] init(cfg) 的 ext 注入。
  static Future<Map<String, dynamic>> call({
    required String jsSource,
    required String method,
    List<Object?> args = const [],
    Map<String, dynamic>? ext,
    String? httpJs,
    required String profilePath,
    Map<String, String> libSources = const {},
    String? sourceUrl,
  }) async {
    final resultJson = await Isolate.run(() => _runInIsolate(
          jsSource: jsSource,
          method: method,
          argsJson: jsonEncode(args),
          extJson: jsonEncode(ext ?? {}),
          httpJs: httpJs,
          libSources: libSources,
          sourceUrl: sourceUrl,
          profilePath: profilePath,
        ));
    final decoded = jsonDecode(resultJson);
    // FongMi 方法直接返回结果 JSON（无信封）；个别源会包一层字符串。
    if (decoded is Map<String, dynamic>) {
      if (decoded.containsKey('__ok') || decoded.containsKey('__data')) {
        final data = decoded['__data'];
        if (data is String && data.isNotEmpty) {
          try {
            final inner = jsonDecode(data);
            if (inner is Map<String, dynamic>) return inner;
          } on FormatException {
            // 非 JSON 字符串：忽略。
          }
        }
        if (data is Map<String, dynamic>) return data;
        if (decoded['__ok'] == false) {
          throw Exception('Fongmi 调用失败: ${decoded['__error']}');
        }
      }
      return decoded;
    }
    return const {};
  }

  /// 模块解析：打包 lib 资产 → 相对 base 的网络模块（阻塞 FFI 抓取）。
  static String _moduleSource(
    String moduleName, {
    required String base,
    required Map<String, String> libSources,
    required String Function(String url) fetcher,
  }) {
    for (final entry in libSources.entries) {
      if (moduleName == entry.key ||
          moduleName.endsWith('/${entry.key}') ||
          moduleName.endsWith(entry.key)) {
        return entry.value;
      }
    }
    if (moduleName.startsWith('http://') ||
        moduleName.startsWith('https://')) {
      return fetcher(moduleName);
    }
    if (base.isNotEmpty && !moduleName.startsWith('/')) {
      return fetcher('$base/$moduleName');
    }
    return fetcher(moduleName);
  }

  /// 阻塞 FFI 抓取模块源（isolate 内合法；UTF-8 文本）。
  static String _blockingFetch(AquaLibrary lib, int handle, String url) {
    final resp = lib.call(handle, 'syncHttp',
        jsonEncode([{'url': url, 'method': 'GET'}]));
    final env = jsonDecode(resp) as Map<String, dynamic>;
    if (env['error'] != null) {
      throw Exception('模块抓取失败: ${env['error']['message']}');
    }
    final result = env['result'] as Map<String, dynamic>;
    if ((result['status'] as num).toInt() != 200) {
      throw Exception('模块抓取失败: HTTP ${result['status']}');
    }
    return utf8.decode(base64.decode(result['bodyB64'] as String),
        allowMalformed: true);
  }

  static String _runInIsolate({
    required String jsSource,
    required String method,
    required String argsJson,
    required String extJson,
    required String? httpJs,
    required Map<String, String> libSources,
    required String? sourceUrl,
    required String profilePath,
  }) {
    final lib = AquaLibrary.open();
    final createResp = lib.create(profilePath, '');
    final createEnv = jsonDecode(createResp) as Map<String, dynamic>;
    if (createEnv['error'] != null) {
      throw Exception('AquaNew 失败: ${createEnv['error']}');
    }
    final handle = (createEnv['result']['handle'] as num).toInt();

    // 模块相对解析基址：源自身 URL 的目录（moduleNormalizeName 同语义）。
    final dir = (sourceUrl ?? '').contains('/')
        ? (sourceUrl ?? '').substring(0, (sourceUrl ?? '').lastIndexOf('/'))
        : '';

    final runtime = QuickJsRuntime2(
      stackSize: 1024 * 1024 * 4,
      moduleHandler: (moduleName) => _moduleSource(
        moduleName,
        base: dir,
        libSources: libSources,
        fetcher: (url) => _blockingFetch(lib, handle, url),
      ),
    );
    try {
      runtime.enableHandlePromises();
      // 同步 req：阻塞 AquaCall（Go 代取网络）——isolate 内阻塞合法。
      runtime.onMessage('fongmi_http', (args) {
        final m = args is Map ? args : <String, dynamic>{};
        final resp = lib.call(handle, 'syncHttp',
            jsonEncode([
              {
                'url': m['url']?.toString() ?? '',
                'method': m['method']?.toString() ?? 'GET',
                'headers': m['headers'] ?? const {},
                'body': m['data']?.toString() ?? '',
              },
            ]));
        final env = jsonDecode(resp) as Map<String, dynamic>;
        if (env['error'] != null) {
          throw Exception('syncHttp: ${env['error']['message']}');
        }
        final result = env['result'] as Map<String, dynamic>;
        return jsonEncode({
          'status': result['status'],
          'headers': result['headers'],
          'body': utf8.decode(
              base64.decode(result['bodyB64'] as String),
              allowMalformed: true),
        });
      });
      // _http：Java 侧注入的同步桥的对等物——经同步通道（阻塞 AquaCall）。
      runtime.evaluate('''
globalThis._http = function (url, options) {
  options = options || {};
  var raw = sendMessage('fongmi_http', JSON.stringify({
    url: url, method: options.method || 'GET',
    headers: options.headers || {},
    data: options.body !== undefined ? options.body : (options.data || '')
  }));
  return JSON.parse(raw);
};
''');
      if (httpJs != null && httpJs.isNotEmpty) {
        runtime.evaluate(httpJs);
      }
      // global/window/self 别名（FongMi http.js 同款）。
      runtime.evaluate('''
['global', 'window', 'self'].forEach(function (name) {
  try {
    Object.defineProperty(globalThis, name, {
      enumerable: true, configurable: true,
      get() { return globalThis; }, set() {}
    });
  } catch (e) {}
});
''');
      // 源码：以 MODULE 求值（支持 ES import；moduleHandler 解析依赖），
      // 占位替换成全局赋值（FongMi 协议）。
      runtime.evaluate(
        jsSource.replaceFirst('__JS_SPIDER__', 'globalThis.__JS_SPIDER__'),
        name: sourceUrl,
        evalFlags: JSEvalFlag.MODULE,
      );
      // init（catvod 式 ext 注入）。
      runtime.evaluate(
          'globalThis.__JS_SPIDER__.init(${extJson == '{}' ? 'undefined' : extJson})');
      // 方法调用（短名，返回 JSON 字符串）。
      return runtime.evaluate(
          'String(globalThis.__JS_SPIDER__.$method(...$argsJson))').stringResult;
    } finally {
      runtime.dispose();
      // client 档案为临时文件：本 isolate 内不删（跨调用复用路径由调用方管理）。
    }
  }
}
