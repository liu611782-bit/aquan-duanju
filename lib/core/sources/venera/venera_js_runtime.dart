import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

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
  final Map<String, Map<String, dynamic>> _dataStore = {};

  Future<void> _ensure() async {
    if (_ready) return;
    final runtime = _runtime = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    runtime.enableHandlePromises();
    // fork 的双参 sendMessage → __nativeSend；Venera 形态的单参全局重新定义。
    runtime.onMessage('venera', (args) => _dispatch(args));
    final initJs = await rootBundle.loadString('assets/venera/init.js');
    runtime.evaluate('''
globalThis.__nativeSend = sendMessage;
globalThis.sendMessage = function (message) {
  return __nativeSend('venera', JSON.stringify(message));
};
''');
    runtime.evaluate(initJs);
    _ready = true;
  }

  /// 宿主方法分发（sendMessage.method）。
  dynamic _dispatch(dynamic args) {
    final message = args is Map ? args : <String, dynamic>{};
    switch (message['method']?.toString()) {
      case 'http':
        // async handler：Future → C-capability promise（fork 真桥唯一可靠路径）。
        return _handleHttp(Map<String, dynamic>.from(message));
      case 'convert':
        return _handleConvert(message);
      case 'html':
        return _handleHtml(message);
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
      case 'delay':
        final ms = (message['time'] as num?)?.toInt() ?? 0;
        return Future<dynamic>.delayed(Duration(milliseconds: ms));
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

  dynamic _handleConvert(dynamic message) {
    final type = message['type']?.toString() ?? 'utf8';
    final isEncode = message['isEncode'] == true;
    if (isEncode) {
      final str = message['value']?.toString() ?? '';
      final bytes =
          type == 'gbk' ? gbk.gbk.encode(str) : utf8.encode(str);
      return bytes;
    }
    final list = (message['value'] as List?)?.map((e) => (e as num).toInt()).toList() ??
        const <int>[];
    return type == 'gbk'
        ? gbk.gbk.decode(list)
        : utf8.decode(list, allowMalformed: true);
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
    final info = <String, dynamic>{};
    for (final field in ['name', 'key', 'version', 'minAppVersion', 'url']) {
      final v = _runtime!.evaluate(
          'String(globalThis.__veneraSources["$className"].$field ?? "")');
      info[field] = v.stringResult;
    }
    final key = info['key']!.toString();
    if (key.isEmpty || (info['name'] as String).isEmpty) {
      throw Exception('Venera source name/key required');
    }
    sources[key] = info;
    // 按 key 归位（temp 是加载暂存）。
    await _runtime!.evaluateAsync(
        'globalThis.__veneraSources["$key"] = globalThis.__veneraSources["$className"]');
    return info;
  }

  /// 调用源方法：[path] 如 `search.load` / `comic.loadEp` / `explore.<i>.load`。
  Future<dynamic> callMethod(String key, String path, List<Object?> args) {
    final argsJson = jsonEncode(args);
    return _awaitJs('''
(() => {
  var s = globalThis.__veneraSources["$key"];
  var f = s;
  for (var p of ${jsonEncode(path.split('.'))}) { f = f ? f[p] : undefined; }
  if (typeof f !== 'function') throw new Error('方法不存在: $path');
  return f(...$argsJson);
})()''');
  }

  /// evaluateAsync + handlePromise 封装（fork 真桥）。
  Future<dynamic> _awaitJs(String code) async {
    final res = await _runtime!.evaluateAsync(code);
    final promised = await _runtime!.handlePromise(res);
    final raw = promised.stringResult;
    if (raw.isEmpty || raw == 'undefined' || raw == 'null') return null;
    try {
      return jsonDecode(raw);
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
      if (bytes) 'bytes': body else 'text': utf8.decode(body, allowMalformed: true),
    };
  } finally {
    client.close();
  }
}
