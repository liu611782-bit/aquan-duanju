import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:flutter/services.dart' show rootBundle;
import 'package:fast_gbk/fast_gbk.dart' as gbk;
import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:html/parser.dart' as html_parser;

/// Venera 漫画源契约兼容运行时（Phase 1：宿主桥 + 加载协议 + 方法调用）。
///
/// Venera 源契约（官方 parser.dart/js_engine.dart 逐行确认）：
/// - 全局单参 `sendMessage(message)` + `appVersion`；先 evaluate `assets/venera/init.js`
///   （定义 ComicSource 基类与 Network/Convert/Html/Ui 等，全部回宿主）；
/// - 源码 `class X extends ComicSource` → 实例化进 `__veneraSources[key]`；
/// - 方法调用走 evaluateAsync + handlePromise（fork 真桥）。
///
/// fork 注入的双参 sendMessage 先重命名为 `__nativeSend`，再定义 Venera 形态的
/// 单参全局——两个世界（CatVod/Venera）各用各的运行时实例，互不影响。
class VeneraJsRuntime {
  VeneraJsRuntime._();

  static final VeneraJsRuntime instance = VeneraJsRuntime._();

  JavascriptRuntime? _runtime;
  bool _ready = false;

  /// key → {name, version, minAppVersion, url}
  final Map<String, Map<String, dynamic>> sources = {};

  /// html 有状态 DOM 注册表：key → Document/Element。
  final Map<String, dynamic> _domRegistry = {};
  var _domSeq = 0;

  /// load_data/save_data 持久化壳（Phase 2 接 _JsonFileStore）。
  final Map<String, dynamic> _dataStore = {};

  /// load_setting/save_setting 壳（Phase 2 接设置存储）。
  final Map<String, dynamic> _settingsStore = {};

  Future<void> _ensure() async {
    if (_ready) return;
    final runtime = _runtime = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    runtime.enableHandlePromises();
    // fork 的双参 sendMessage → __nativeSend；Venera 形态的单参全局重新定义。
    // 双通道：Venera 源在同步 getter 里调 loadSetting/convert（不能等
    // Promise），http/delay 则必须异步——按方法面拆分同步/异步两条路。
    runtime.onMessage('venera_sync', (args) {
      try {
        // 同步回传也必须 JSON 字符串：sync _dartToJs 对 Map 会转 JS 对象，
        // 但信封统一让 JS 包装层 JSON.parse，形态一致。
        return jsonEncode(_dispatchSync(Map<String, dynamic>.from(args as Map)));
      } catch (e) {
        return jsonEncode({'__veneraError': '$e'});
      }
    });
    runtime.onMessage('venera', (args) async {
      try {
        final result = await _dispatchAsync(Map<String, dynamic>.from(args as Map));
        // 异步回传必须 JSON 字符串：fork 的 Future 分支用 "$res" 插值，
        // Map 会变成 Dart toString；字符串插值则无损。
        return jsonEncode(result);
      } catch (e) {
        return jsonEncode({'__veneraError': '$e'});
      }
    });
    final initJs = await rootBundle.loadString('assets/venera/init.js');
    runtime.evaluate('''
globalThis.__nativeSend = sendMessage;
var __VENERA_ASYNC = {http: 1, delay: 1, compute: 1, image: 1, UI: 1,
  getClipboard: 1, setClipboard: 1};
globalThis.sendMessage = function (message) {
  if (__VENERA_ASYNC[message.method]) {
    // 异步方法：返回 Promise（源码/库均以 await 消费）。
    return __nativeSend('venera', JSON.stringify(message)).then(function (raw) {
      var v = JSON.parse(raw);
      if (v && v.__veneraError) throw new Error(v.__veneraError);
      return v;
    });
  }
  // 同步方法（convert/load_setting/load_data/...）：立即返回值——
  // Venera 源在同步 getter 里调它们（https://\${this.loadSetting(..)}）。
  var raw = __nativeSend('venera_sync', JSON.stringify(message));
  var v = JSON.parse(raw);
  if (v && v.__veneraError) throw new Error(v.__veneraError);
  return v;
};
''');
    // init.js 用 `let console` 顶层声明，与 fork 预定义的 var console 冲突
    // （redeclaration）→ 包函数作用域求值，再把源码需要的全局显式导出。
    const globals = [
      'setTimeout', 'setInterval', 'Convert', 'createUuid', 'randomInt',
      'randomDouble', 'Network', 'Cookie', 'HtmlDocument', 'HtmlElement',
      'HtmlNode', 'log', 'console', 'Comic', 'ComicDetails', 'Comment',
      'ImageLoadingConfig', 'ComicSource', 'Image',
    ];
    final export = globals
        .map((g) => "globalThis.$g = $g;")
        .join('\n');
    final initResult = runtime.evaluate('''
(function () {
$initJs
$export
})();
''');
    if (initResult.isError) {
      throw Exception('Venera init.js 加载失败: ${initResult.stringResult}');
    }
    _ready = true;
  }

  /// 异步方法分发（http/delay/compute/image/UI/剪贴板）。
  Future<dynamic> _dispatchAsync(Map<String, dynamic> message) async {
    switch (message['method']?.toString()) {
      case 'http':
        return _handleHttp(message);
      case 'delay':
        final ms = (message['time'] as num?)?.toInt() ?? 0;
        await Future<void>.delayed(Duration(milliseconds: ms));
        return null;
      default:
        throw Exception('Unknown async Venera method: ${message['method']}');
    }
  }

  /// 同步方法分发（convert/存储/设置/工具——Venera 源同步 getter 依赖）。
  dynamic _dispatchSync(dynamic args) {
    final message = args is Map ? args : <String, dynamic>{};
    switch (message['method']?.toString()) {
      case 'convert':
        return _handleConvert(Map<String, dynamic>.from(message));
      case 'html':
        return _handleHtml(message);
      case 'load_setting':
        return _settingsStore['${message['key']}/${message['setting_key']}'];
      case 'save_setting':
        _settingsStore['${message['key']}/${message['setting_key']}'] =
            message['value'];
        return null;
      case 'load_data':
        final key = '${message['key']}/${message['data_key']}';
        return _dataStore[key];
      case 'save_data':
        final key = '${message['key']}/${message['data_key']}';
        _dataStore[key] =
            message['data'] is Map
                ? Map<String, dynamic>.from(message['data'] as Map)
                : message['data'];
        return null;
      case 'delete_data':
        _dataStore.remove('${message['key']}/${message['data_key']}');
        return null;
      case 'log':
        return null;
      case 'uuid':
        final r = Random();
        const hex = '0123456789abcdef';
        return String.fromCharCodes(List.generate(
            32, (i) => hex.codeUnitAt(r.nextInt(i == 12 ? 4 : 16))));
      case 'random':
        final min = (message['min'] as num?)?.toInt() ?? 0;
        final max = (message['max'] as num?)?.toInt() ?? 1;
        return min + Random().nextInt((max - min).clamp(1, 1 << 30));
      case 'getPlatform':
        return 'aquan';
      case 'getLocale':
        return 'zh-CN';
      case 'appVersion':
        return '1.0.0';
      case 'isLogged':
        return false;
      case 'cookie':
      case 'getClipboard':
      case 'setClipboard':
      case 'compute':
      case 'image':
      case 'UI':
        throw Exception('Venera method not supported yet: ${message['method']}');
      default:
        throw Exception('Unknown Venera method: ${message['method']}');
    }
  }

  /// Convert 全面（utf8/gbk/base64/md5/sha1/sha256/sha512/hmac/hex）。
  /// 值宽容：String（含 ArrayBuffer 桥接形态）与 bytes 均可。
  dynamic _handleConvert(dynamic message) {
    final type = message['type']?.toString() ?? 'utf8';
    final isEncode = message['isEncode'] == true;
    final value = message['value'];

    String strOf(dynamic v) {
      if (v is String) return v;
      if (v is Uint8List) return utf8.decode(v, allowMalformed: true);
      if (v is List) {
        return utf8.decode(v.map((e) => (e as num).toInt()).toList(),
            allowMalformed: true);
      }
      return '$v';
    }

    List<int> bytesOf(dynamic v) {
      if (v is Uint8List) return v;
      if (v is List) return v.map((e) => (e as num).toInt()).toList();
      if (v is String) return utf8.encode(v);
      return utf8.encode('$v');
    }

    Digest hashOf(String algo, List<int> data) => switch (algo) {
          'md5' => md5.convert(data),
          'sha1' => sha1.convert(data),
          'sha512' => sha512.convert(data),
          _ => sha256.convert(data),
        };

    switch (type) {
      case 'utf8':
        return isEncode ? utf8.encode(strOf(value)) : utf8.decode(bytesOf(value), allowMalformed: true);
      case 'gbk':
        return isEncode
            ? gbk.gbk.encode(strOf(value))
            : gbk.gbk.decode(bytesOf(value));
      case 'base64':
        return isEncode ? base64.encode(bytesOf(value)) : base64.decode(strOf(value));
      case 'hex':
        if (isEncode) {
          return bytesOf(value)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
        }
        final hexStr = strOf(value).replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
        return [
          for (var i = 0; i + 1 < hexStr.length; i += 2)
            int.parse(hexStr.substring(i, i + 2), radix: 16),
        ];
      case 'md5':
      case 'sha1':
      case 'sha256':
      case 'sha512':
        return hashOf(type, bytesOf(value)).toString();
      case 'hmac':
        final hash = message['hash']?.toString() ?? 'sha256';
        final key = bytesOf(message['key']);
        final data = bytesOf(value);
        final digest = switch (hash) {
          'md5' => Hmac(md5, key),
          'sha1' => Hmac(sha1, key),
          'sha512' => Hmac(sha512, key),
          _ => Hmac(sha256, key),
        }.convert(data).toString();
        return digest;
      default:
        throw Exception('Unknown convert type: $type');
    }
  }

  Future<dynamic> _handleHttp(Map<String, dynamic> message) async {
    // 动态 import 避免与 Venera 契约耦合：直接用 http 包。
    return _performHttp(
      method: (message['http_method']?.toString() ?? 'GET').toUpperCase(),
      url: message['url']?.toString() ?? '',
      headers: message['headers'] is Map
          ? (message['headers'] as Map)
              .map((k, v) => MapEntry(k.toString(), v.toString()))
          : null,
      data: message['data'],
      bytes: message['bytes'] == true,
    );
  }

  dynamic _handleHtml(dynamic message) {
    final fn = message['function']?.toString() ?? '';
    switch (fn) {
      case 'parse':
        final key = 'd${_domSeq++}';
        _domRegistry[key] =
            html_parser.parse(message['data']?.toString() ?? '');
        return key;
      case 'querySelector':
      case 'querySelectorAll':
        final doc = _domRegistry[message['key']?.toString()];
        if (doc == null) return fn == 'querySelector' ? null : <String>[];
        final query = message['query']?.toString() ?? '';
        if (fn == 'querySelector') {
          final el = _query(doc, query);
          if (el == null) return null;
          final k = 'e${_domSeq++}';
          _domRegistry[k] = el;
          return k;
        }
        final els = _querySelectorAll(doc, query);
        return [
          for (final el in els)
            () {
              final k = 'e${_domSeq++}';
              _domRegistry[k] = el;
              return k;
            }(),
        ];
      default:
        // attributes/text/innerHTML 等元素级操作：key 指向 Element。
        final el = _domRegistry[message['key']?.toString()];
        if (el == null) return null;
        return _elementOp(el, fn, message);
    }
  }

  /// Venera HtmlElement 的操作子集（attributes/attributesMap/text 等）。
  dynamic _elementOp(dynamic el, String fn, dynamic message) {
    // el 为 html 包的 Element；具体能力由测试驱动补齐。
    if (fn == 'attributes') {
      final name = message['name']?.toString() ?? '';
      return el.attributes?[name]?.toString();
    }
    if (fn == 'attributesMap') {
      return Map<String, String>.from(el.attributes ?? {});
    }
    if (fn == 'text') return el.text?.toString();
    if (fn == 'innerHTML') return el.innerHtml?.toString();
    return null;
  }

  dynamic _query(dynamic doc, String query) {
    try {
      return doc.querySelector(query);
    } catch (_) {
      return null;
    }
  }

  List<dynamic> _querySelectorAll(dynamic doc, String query) {
    try {
      return doc.querySelectorAll(query).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 加载一个 Venera 源（协议见 parser.dart:85-115）：
  /// 提取类名 → `(() => { js; this['temp'] = new X(); }).call()` →
  /// 同步读 name/key/version → 注册 `__veneraSources[key]`。
  Future<Map<String, dynamic>> loadSource(String js) async {
    await _ensure();
    final line1 =
        js.split('\n').firstWhere((e) => e.trim().startsWith('class '));
    if (!line1.contains('extends ComicSource')) {
      throw Exception('Invalid Venera source: no ComicSource class');
    }
    var className =
        line1.split('class')[1].split('extends ComicSource').first.trim();
    final result = await _runtime!.evaluateAsync('''
(() => {
  $js
  globalThis.__veneraSources = globalThis.__veneraSources || {};
  globalThis.__veneraSources["$className"] = new $className();
  return 'ok';
}).call(globalThis)
''');
    final promised = await _runtime!.handlePromise(result);
    if (promised.stringResult != 'ok') {
      throw Exception('Venera source load failed: ${promised.stringResult}');
    }
    final keyInfo = _runtime!.evaluate(
        'String(globalThis.__veneraSources["$className"].key ?? "")');
    // 按 key 归位（类名为加载暂存键）。
    await _runtime!.evaluateAsync(
        'globalThis.__veneraSources["$keyInfo"] = globalThis.__veneraSources["$className"]');
    final info = <String, dynamic>{};
    for (final field in ['name', 'key', 'version', 'minAppVersion', 'url']) {
      final v = _runtime!.evaluate(
          'String(globalThis.__veneraSources["$keyInfo"].$field ?? "")');
      info[field] = v.stringResult;
    }
    final key = info['key']!.toString();
    if (key.isEmpty || (info['name'] as String).isEmpty) {
      throw Exception('Venera source name/key required');
    }
    sources[key] = info;
    // 预置设置默认值（Venera 宿主行为：loadSetting 未设置时回落 default，
    // 如 mh18 的 baseUrl 依赖 domains 设置）。
    final settingsRaw = await _awaitJs(
        'JSON.stringify(globalThis.__veneraSources["$key"].settings ?? {})');
    if (settingsRaw is Map) {
      settingsRaw.forEach((sk, sv) {
        final def = sv is Map ? sv['default'] : null;
        _settingsStore.putIfAbsent('$key/$sk', () => def);
      });
    }
    return info;
  }

  /// 求值一个表达式并 JSON 解析（读取实例字段/元数据用）。
  Future<dynamic> evalJson(String expr) => _awaitJs(expr);

  /// 调用源方法：[path] 如 `search.load` / `comic.loadEp` / `explore.<i>.load`。
  Future<dynamic> callMethod(String key, String path, List<Object?> args) {
    final argsJson = jsonEncode(args);
    // 结果在 **JS 内部** JSON.stringify 后回传（spider 同款往返）：fork 的
    // promise 管线曾把 Dart 对象插值成 toString 形态，字符串则无损。
    return _awaitJs('''
(async () => {
  var s = globalThis.__veneraSources["$key"];
  var f = s;
  for (var p of ${jsonEncode(path.split('.'))}) { f = f ? f[p] : undefined; }
  if (typeof f !== 'function') throw new Error('方法不存在: $path');
  var r = await f(...$argsJson);
  return JSON.stringify({__ok: true, __data: r === undefined ? null : r});
})().catch(e => JSON.stringify({__ok: false, __error: String(e)}));
''');
  }

  /// evaluateAsync + handlePromise 封装（fork 真桥）。
  Future<dynamic> _awaitJs(String code) async {
    final res = await _runtime!.evaluateAsync(code);
    final promised = await _runtime!.handlePromise(res);
    final raw = promised.stringResult;
    if (raw.isEmpty || raw == 'undefined' || raw == 'null') return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map && decoded.containsKey('__ok')) {
        if (decoded['__ok'] == false) {
          throw Exception('Venera 调用失败: ${decoded['__error']}');
        }
        return decoded['__data'];
      }
      return decoded;
    } on FormatException {
      return raw;
    }
  }

  void dispose() {
    _runtime?.dispose();
    _runtime = null;
    _ready = false;
    sources.clear();
    _domRegistry.clear();
    _dataStore.clear();
  }
}

/// spReq 风格的 HTTP 执行（Venera http 方法）。
Future<Map<String, dynamic>> _performHttp({
  required String method,
  required String url,
  Map<String, dynamic>? headers,
  Object? data,
  required bool bytes,
}) async {
  // 独立实现，避免依赖 spider 的通道形态。
  final client = HttpClient();
  try {
    final req = await client.openUrl(method, Uri.parse(url));
    headers?.forEach((k, v) {
      if (k.toLowerCase() != 'content-type' || true) req.headers.set(k, '$v');
    });
    if (data != null && method != 'GET') {
      req.add(utf8.encode('$data'));
    }
    final res = await req.close();
    final body = await res.fold<List<int>>(<int>[], (a, c) => a..addAll(c));
    return {
      'status': res.statusCode,
      'headers': () {
        final h = <String, String>{};
        res.headers.forEach((k, v) => h[k] = v.join(', '));
        return h;
      }(),
      // Network 契约：{status, headers, body}（fetchBytes 为 ArrayBuffer、
      // sendRequest 为字符串——Array 形态的 bytes 亦兼容索引/length 用法）。
      'body': bytes ? body : utf8.decode(body, allowMalformed: true),
    };
  } finally {
    client.close();
  }
}
