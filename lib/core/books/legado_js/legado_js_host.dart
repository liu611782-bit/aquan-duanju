import 'dart:convert';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import '../../book_markup.dart';
import '../../ffi_bridge.dart';
import '../../sources/source_import.dart';
import '../book_rule.dart';
import '../so_novel_selector.dart';
import 'legado_js_crypto.dart';
import 'legado_js_rewrite.dart';

/// isolate 内执行请求（主 isolate 组装；[transport] 须为可发送闭包/顶层函数）。
typedef LegadoJsTransport = String Function(String requestJson);

class LegadoJsRequest {
  const LegadoJsRequest({
    required this.code,
    this.bindings = const {},
    this.jsLib = '',
    this.cacheIn = const {},
    this.cookieIn = const {},
    this.transport,
    this.enforceSsrf = true,
    this.profilePath = 'legado-js',
  });

  final String code;
  final Map<String, Object?> bindings;
  final String jsLib;
  final Map<String, String> cacheIn;
  final Map<String, String> cookieIn;
  final LegadoJsTransport? transport;
  final bool enforceSsrf;
  final String profilePath;
}

/// legado js 宿主：QuickJS + 同步通道（isolate 内运行，见 LegadoJsEngine）。
///
/// 通道契约（spike test 实测锁定）：handler 收到**已解析**的 Map；返回的 Dart
/// 对象直接映射为 JS 值（Map→object / String→string / null→null）。
class LegadoJsHost {
  LegadoJsHost._();

  static String run(LegadoJsRequest req) {
    final ctx = _Ctx(req, depth: 0);
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    try {
      rt.enableHandlePromises();
      rt.onMessage('legado_host', (args) => _dispatch(rt, ctx, args));
      _evalChecked(rt, _shimJs);
      _evalChecked(rt, _prelude(ctx.req.bindings, depth: ctx.depth));
      if (req.jsLib.trim().isNotEmpty) {
        _evalChecked(rt, req.jsLib);
      }
      _evalChecked(rt, 'globalThis.__lv = eval(${jsonEncode(req.code)});');
      final value = _captureCompletion(rt);
      return jsonEncode({
        'ok': true,
        'value': value,
        'cacheOut': ctx.cache,
        'cookieOut': ctx.cookieFlat(),
        'logs': ctx.logs,
      });
    } catch (e) {
      return jsonEncode({
        'ok': false,
        'error': '$e',
        'cacheOut': ctx.cache,
        'cookieOut': ctx.cookieFlat(),
        'logs': ctx.logs,
      });
    } finally {
      try {
        rt.dispose();
      } catch (_) {}
    }
  }

  /// flutter_qjs 的 evaluate 对出错脚本**不抛**而是返回 isError 的 JsValue
  /// （so_novel_func 同款检查）——不查会把 js 错误静默吞成空串。
  static JsEvalResult _evalChecked(QuickJsRuntime2 rt, String src) {
    final v = rt.evaluate(src);
    if (v.isError) {
      throw StateError('js 求值失败: ${v.stringResult}');
    }
    return v;
  }

  /// 完成值捕获：`eval(code)` 的完成值（含 var 声明后的尾表达式）→ 统一字符串。
  static String _captureCompletion(QuickJsRuntime2 rt) {
    return _evalChecked(
      rt,
      'var __t = globalThis.__lv; '
      '(typeof __t === "undefined" || __t === null) ? "" : '
      '(typeof __t === "object" ? JSON.stringify(__t) : String(__t))',
    ).stringResult;
  }

  static String _prelude(Map<String, Object?> b, {required int depth}) {
    String j(String k) => jsonEncode(b[k]);
    final pre = <String>[
      'var result = ${jsonEncode(b['result']?.toString() ?? '')};',
      'var src = result;',
      'var baseUrl = ${jsonEncode(b['baseUrl']?.toString() ?? '')};',
      'var key = ${b.containsKey('key') ? j('key') : 'null'};',
      'var page = ${b['page'] is num ? '${b['page'] as num}' : 'null'};',
      'var book = ${jsonEncode(b['book'] ?? const <String, dynamic>{})};',
      'var chapter = ${jsonEncode(b['chapter'] ?? const <String, dynamic>{})};',
      'var __sourceKey = ${jsonEncode(b['sourceKey']?.toString() ?? '')};',
    ];
    if (depth > 0) pre.add('var __depth = $depth;');
    return pre.join('\n');
  }

  // ---------------- 通道分派 ----------------

  static Object? _dispatch(QuickJsRuntime2 rt, _Ctx ctx, Object? args) {
    try {
      final m = args is Map ? args : const {};
      final op = m['op']?.toString() ?? '';
      final a = m['args'] is Map ? (m['args'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
      final out = _op(rt, ctx, op, a);
      return out;
    } catch (e) {
      return {'__err': '$e'};
    }
  }

  static Object? _op(QuickJsRuntime2 rt, _Ctx ctx, String op, Map<String, dynamic> a) {
    switch (op) {
      case 'log':
        ctx.logs.add(a['msg']?.toString() ?? '');
        return null;
      case 'http':
        return _httpSync(ctx, a, wantBodyOnly: false);
      case 'http_string':
        return _httpSync(ctx, a, wantBodyOnly: true);
      case 'rule_string':
        final rule = a['rule']?.toString() ?? '';
        final content =
            a['content'] == null ? _bind(ctx, 'result') : a['content'].toString();
        return _ruleEvalString(ctx, content, rule,
            baseUrl: _bind(ctx, 'baseUrl'),
            isUrl: a['isUrl'] == true,
            depth: ctx.depth + 1);
      case 'rule_list':
        final rule = a['rule']?.toString() ?? '';
        final content =
            a['content'] == null ? _bind(ctx, 'result') : a['content'].toString();
        return _ruleEvalList(ctx, content, rule,
            baseUrl: _bind(ctx, 'baseUrl'), depth: ctx.depth + 1);
      case 'cache_get':
        final v = ctx.cache[a['key']?.toString() ?? ''];
        return v == null || v.isEmpty ? null : v;
      case 'cache_put':
        ctx.cache[a['key']?.toString() ?? ''] = a['value']?.toString() ?? '';
        return null;
      case 'cache_del':
        ctx.cache.remove(a['key']?.toString() ?? '');
        return null;
      case 'cookie_get':
        return _cookieHeader(ctx, a['url']?.toString() ?? '');
      case 'cookie_get_key':
        final jar = ctx.cookieHost(a['url']?.toString() ?? '');
        return jar[a['key']?.toString() ?? ''];
      case 'cookie_set':
        _cookieSet(ctx, a['url']?.toString() ?? '', a['value']?.toString() ?? '');
        return null;
      case 'cookie_remove':
        ctx.cookies.remove(_hostOf(a['url']?.toString() ?? ''));
        return null;
      case 'digest':
        return LegadoJsCrypto.digestHex(
            a['data']?.toString() ?? '', a['algorithm']?.toString() ?? 'MD5');
      case 'digest_b64':
        return LegadoJsCrypto.digestBase64Str(
            a['data']?.toString() ?? '', a['algorithm']?.toString() ?? 'MD5');
      case 'md5_16':
        return LegadoJsCrypto.md5Encode16(a['data']?.toString() ?? '');
      case 'hmac_hex':
        return LegadoJsCrypto.hmacHex(a['data']?.toString() ?? '',
            a['algorithm']?.toString() ?? 'HmacSHA256', a['key']?.toString() ?? '');
      case 'hmac_base64':
        return LegadoJsCrypto.hmacBase64(a['data']?.toString() ?? '',
            a['algorithm']?.toString() ?? 'HmacSHA256', a['key']?.toString() ?? '');
      case 'b64_encode':
        return LegadoJsCrypto.base64EncodeStr(a['data']?.toString() ?? '');
      case 'b64_decode':
        return LegadoJsCrypto.base64DecodeStr(a['data']?.toString() ?? '');
      case 'hex_encode':
        return LegadoJsCrypto.hexEncodeToString(a['data']?.toString() ?? '');
      case 'hex_decode':
        return LegadoJsCrypto.hexDecodeToString(a['data']?.toString() ?? '');
      case 'str_to_bytes':
        return base64.encode(LegadoJsCrypto.strToBytes(
            a['data']?.toString() ?? '', a['charset']?.toString() ?? 'utf-8'));
      case 'bytes_to_str':
        return LegadoJsCrypto.bytesToStr(
            LegadoJsCrypto.base64DecodeBytes(a['data']?.toString() ?? ''),
            a['charset']?.toString() ?? 'utf-8');
      case 'cipher_new':
        final id = ctx.nextCipherId++;
        ctx.ciphers[id] = LegadoJsCrypto.createSymmetricCrypto(
            a['transformation']?.toString() ?? '',
            a['key']?.toString() ?? '',
            a['iv']?.toString() ?? '');
        return id;
      case 'cipher_op':
        final cipher = ctx.ciphers[(a['h'] as num?)?.toInt()];
        if (cipher == null) throw StateError('加密句柄不存在');
        final data = a['data']?.toString() ?? '';
        return switch (a['op']?.toString()) {
          'encrypt' => cipher.encryptB64(data),
          'encrypt_hex' => cipher.encryptHex(data),
          'decrypt' => cipher.decryptB64(data),
          'decrypt_str' => cipher.decryptStr(data),
          _ => throw StateError('未知 cipher op'),
        };
      case 'rsa_new':
        final id = ctx.nextRsaId++;
        ctx.rsas[id] = LegadoJsCrypto.createAsymmetricCrypto(
            a['transformation']?.toString() ?? 'RSA');
        return id;
      case 'rsa_key':
        final rsa = ctx.rsas[(a['h'] as num?)?.toInt()];
        if (rsa == null) throw StateError('RSA 句柄不存在');
        final key = a['key']?.toString() ?? '';
        if (a['kind']?.toString() == 'priv') {
          rsa.setPrivateKey(key);
        } else {
          rsa.setPublicKey(key);
        }
        return null;
      case 'rsa_op':
        final rsa = ctx.rsas[(a['h'] as num?)?.toInt()];
        if (rsa == null) throw StateError('RSA 句柄不存在');
        final data = a['data']?.toString() ?? '';
        return switch (a['op']?.toString()) {
          'encrypt' => rsa.encryptB64(data),
          'encrypt_hex' => rsa.encryptHex(data),
          'decrypt' => rsa.decryptB64(data),
          'decrypt_str' => rsa.decryptStr(data),
          _ => throw StateError('未知 rsa op'),
        };
      case 'dom_query':
        return _domQuery(ctx, a);
      case 'dom_text':
        return _domOf(ctx, a).text.trim();
      case 'dom_html':
        return _domOf(ctx, a).innerHtml;
      case 'dom_attr':
        return _domOf(ctx, a).attributes[a['name']?.toString() ?? ''] ?? '';
      case 'time_format':
        final t = a['time'];
        return LegadoJsCrypto.timeFormat(a['pattern']?.toString() ?? '',
            t == null ? null : (t is num ? t : '$t'));
      case 'abs_url':
        return _absUrl(a['url']?.toString() ?? '', a['base']?.toString() ?? '');
      default:
        throw UnsupportedError('legado js 宿主暂不支持: $op');
    }
  }

  // ---------------- 网络 ----------------

  /// transport/FFI 契约：请求 `{url, method, headers, body}` →
  /// 响应 `{status:int, headers:Map, body:String}`（body 已解码文本）。
  static Map<String, dynamic> _httpSync(_Ctx ctx, Map<String, dynamic> a,
      {required bool wantBodyOnly}) {
    var url = a['url']?.toString() ?? '';
    var method = (a['method'] ?? 'GET').toString();
    String? body = a['body']?.toString();
    final headers = <String, String>{};
    final h = a['headers'];
    if (h is Map) {
      for (final e in h.entries) {
        headers[e.key.toString()] = e.value?.toString() ?? '';
      }
    } else if (h is String && h.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(h);
        if (decoded is Map) {
          for (final e in decoded.entries) {
            headers[e.key.toString()] = e.value?.toString() ?? '';
          }
        }
      } catch (_) {}
    }
    // legado 的 ajax/get 首参允许带 `,{...}` 选项（AnalyzeUrl 语义）。
    if (url.contains(',{')) {
      final (u, opts) = BookRule.parseSearchUrl(url);
      url = u;
      if (opts.isPost && (body == null || body.isEmpty)) body = opts.body;
      headers.addAll(opts.headers);
      method = opts.method;
    }
    final timeout = (a['timeout'] as num?)?.toInt();
    // SSRF：js 发起的请求与运行时同契约（引擎按 enforceSsrf 开关，测试关）。
    if (ctx.req.enforceSsrf) {
      SourceImporter.validateImportUrl(url);
    }
    // 会话 cookie：未显式给 Cookie 头时带上 jar 里的。
    if (!headers.containsKey('Cookie')) {
      final jar = _cookieHeader(ctx, url);
      if (jar.isNotEmpty) headers['Cookie'] = jar;
    }
    final reqJson = jsonEncode({
      'url': url,
      'method': method.toUpperCase(),
      'headers': headers,
      'body': body ?? '',
      'timeoutMs': ?timeout,
    });
    final raw = ctx.req.transport != null
        ? ctx.req.transport!(reqJson)
        : _ffiHttp(ctx, reqJson);
    final resp = jsonDecode(raw) as Map<String, dynamic>;
    final status = (resp['status'] as num?)?.toInt() ?? 0;
    final respHeaders = <String, String>{
      for (final e in (resp['headers'] as Map? ?? const {}).entries)
        e.key.toString(): e.value?.toString() ?? ''
    };
    final respBody = resp['body']?.toString() ?? '';
    // Set-Cookie 尽力捕获（响应头若带则并入 jar）。
    final setCookie = respHeaders['set-cookie'] ?? respHeaders['Set-Cookie'];
    if (setCookie != null && setCookie.isNotEmpty) {
      _cookieSet(ctx, url, setCookie);
    }
    if (wantBodyOnly) return {'body': respBody};
    return {'status': status, 'headers': respHeaders, 'body': respBody};
  }

  static AquaLibrary? _lib;
  static int? _handle;

  static String _ffiHttp(_Ctx ctx, String reqJson) {
    _lib ??= AquaLibrary.open();
    _handle ??= (_jsonOf(_lib!.create(ctx.req.profilePath, ''))['result']
            ['handle'] as num)
        .toInt();
    // Go 侧 syncHttp 的入参是「请求对象数组」（fongmi 同款）。
    final call = jsonEncode([
      jsonDecode(reqJson) as Map<String, dynamic>,
    ]);
    final resp = _jsonOf(_lib!.call(_handle!, 'syncHttp', call));
    if (resp['error'] != null) {
      throw StateError('syncHttp: ${resp['error']['message']}');
    }
    final result = resp['result'] as Map<String, dynamic>;
    final bodyBytes = base64.decode('${result['bodyB64']}');
    final headers = result['headers'];
    final contentType = headers is Map
        ? (headers['content-type'] ?? headers['Content-Type'])?.toString()
        : null;
    return jsonEncode({
      'status': result['status'],
      'headers': headers,
      'body': decodeMarkupText(bodyBytes, contentType: contentType),
    });
  }

  static Map<String, dynamic> _jsonOf(String raw) =>
      jsonDecode(raw) as Map<String, dynamic>;

  // ---------------- 规则递归（java.getString / getStringList） ----------------

  static String _ruleEvalString(
    _Ctx ctx,
    String node,
    String rule, {
    required String baseUrl,
    required bool isUrl,
    required int depth,
  }) {
    if (depth > 3) throw StateError('getString 嵌套 js 过深');
    for (final alt in LegadoJsRewrite.splitAlternatives(rule)) {
      try {
        final (expr, clean) = BookRule.splitClean(alt);
        var content = node;
        var out = '';
        for (final seg in LegadoJsRewrite.split(expr)) {
          if (seg.webJs) {
            throw UnsupportedError('@webjs: 需要 WebView，暂不支持');
          }
          if (seg.isJs) {
            out = _nestedEval(ctx, seg.text, {
              'result': content,
              'baseUrl': baseUrl,
              'sourceKey': ctx.req.bindings['sourceKey'],
            }, depth);
          } else {
            out = _evalStringOnContent(content, seg.text, baseUrl);
          }
          content = out;
        }
        final value = BookRule.applyClean(out.trim(), clean);
        if (value.isNotEmpty) {
          return isUrl ? _absUrl(value, baseUrl) : value;
        }
      } on UnsupportedError {
        rethrow;
      } catch (_) {
        // 该分支失败：尝试下一 || 分支（全失败落空串）。
      }
    }
    return '';
  }

  static List<dynamic> _ruleEvalList(
    _Ctx ctx,
    String node,
    String rule, {
    required String baseUrl,
    required int depth,
  }) {
    if (depth > 3) throw StateError('getStringList 嵌套 js 过深');
    for (final alt in LegadoJsRewrite.splitAlternatives(rule)) {
      try {
        var content = node;
        var last = content;
        var sawSelector = false;
        for (final seg in LegadoJsRewrite.split(alt)) {
          if (seg.webJs) throw UnsupportedError('@webjs: 需要 WebView，暂不支持');
          if (seg.isJs) {
            last = _nestedEval(ctx, seg.text, {
              'result': content,
              'baseUrl': baseUrl,
              'sourceKey': ctx.req.bindings['sourceKey'],
            }, depth);
            content = last;
          } else {
            last = BookRule.evalList(_maybeParse(content), seg.text).toString();
            content = last;
            sawSelector = true;
          }
        }
        if (!sawSelector) {
          final parsed = _maybeParse(content);
          if (parsed is List) return parsed;
          if (parsed is Map) return [parsed];
          return parsed is String && parsed.isNotEmpty ? [parsed] : const [];
        }
        final list = BookRule.evalList(_maybeParse(content), alt);
        if (list.isNotEmpty) return list;
      } on UnsupportedError {
        rethrow;
      } catch (_) {
        // 下一分支。
      }
    }
    return const [];
  }

  static Object _maybeParse(String content) {
    final t = content.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(t);
      } catch (_) {}
    }
    return content;
  }

  /// 选择器段作用于「当前内容字符串」：JSON 内容走 JSONPath，否则 HTML。
  static String _evalStringOnContent(String content, String seg, String baseUrl) {
    if (seg.trim().isEmpty) return content;
    return BookRule.evalString(_maybeParse(content), seg, baseUrl: baseUrl);
  }

  /// 嵌套 js（getString 的规则里再含 js）：**新开 QuickJS runtime**，避免同
  /// runtime 重入；宿主通道按 depth+1 重挂，cache/cookie 与外层共享。
  static String _nestedEval(
      _Ctx ctx, String code, Map<String, Object?> bindings, int depth) {
    final nested = _Ctx(ctx.req, depth: depth, inherit: ctx);
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024);
    try {
      rt.enableHandlePromises();
      rt.onMessage('legado_host', (args) => _dispatch(rt, nested, args));
      _evalChecked(rt, _shimJs);
      _evalChecked(rt, _prelude(bindings, depth: depth));
      _evalChecked(rt, 'globalThis.__lv = eval(${jsonEncode(code)});');
      return _captureCompletion(rt);
    } finally {
      try {
        rt.dispose();
      } catch (_) {}
    }
  }

  // ---------------- 工具 ----------------

  static String _bind(_Ctx ctx, String key) =>
      ctx.req.bindings[key]?.toString() ?? '';

  // ---------------- DOM 句柄（java.getElement/getElements） ----------------

  /// `java.getElement(sel[, content])`：句柄表注册，JS 侧方法对象按句柄回查。
  static Object? _domQuery(_Ctx ctx, Map<String, dynamic> a) {
    dom.Node root;
    if (a['h'] != null) {
      root = _domOf(ctx, a);
    } else {
      final content = a['content']?.toString() ?? _bind(ctx, 'result');
      root = html_parser.parse(content);
    }
    final els = soNovelSelect(root, a['selector']?.toString() ?? '');
    if (a['many'] != true) {
      if (els.isEmpty) return null;
      ctx.doms.add(els.first);
      return {'handle': ctx.doms.length - 1};
    }
    final handles = <int>[];
    for (final e in els.take(50)) {
      ctx.doms.add(e);
      handles.add(ctx.doms.length - 1);
    }
    return {'handles': handles};
  }

  static dom.Element _domOf(_Ctx ctx, Map<String, dynamic> a) {
    final h = (a['h'] as num?)?.toInt();
    if (h == null || h < 0 || h >= ctx.doms.length) {
      throw StateError('DOM 句柄不存在');
    }
    return ctx.doms[h];
  }

  static String _absUrl(String value, String baseUrl) {
    if (value.isEmpty || baseUrl.isEmpty) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    final looksLikePath = value.startsWith('/') ||
        value.startsWith('./') ||
        value.startsWith('../') ||
        value.startsWith('?') ||
        value.startsWith('#');
    if (!looksLikePath) return value;
    try {
      return Uri.parse(baseUrl).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  static String _hostOf(String url) {
    final u = Uri.tryParse(url);
    return (u == null || !u.hasScheme) ? '' : u.host;
  }

  static String _cookieHeader(_Ctx ctx, String url) {
    final jar = ctx.cookieHost(url);
    return [for (final e in jar.entries) '${e.key}=${e.value}'].join('; ');
  }

  static void _cookieSet(_Ctx ctx, String url, String value) {
    final host = _hostOf(url);
    if (host.isEmpty) return;
    final jar = ctx.cookies.putIfAbsent(host, () => <String, String>{});
    for (final piece in value.split(';')) {
      final kv = piece.split('=');
      if (kv.length < 2) continue;
      final k = kv.first.trim();
      if (k.isEmpty || k == 'Path' || k == 'Domain' || k == 'Expires' || k == 'Max-Age' || k == 'HttpOnly' || k == 'Secure') {
        continue;
      }
      jar[k] = kv.sublist(1).join('=').trim();
    }
  }

  // ---------------- 宿主 shim（JS 侧） ----------------

  static const String _shimJs = r'''
function __host(op, args) {
  var v = sendMessage('legado_host', JSON.stringify({op: op, args: args === undefined ? null : args}));
  if (v && v.__err) throw new Error(v.__err);
  return v;
}
function __b64e(s) { return __host('b64_encode', {data: String(s)}); }
function __b64d(s) { return __host('b64_decode', {data: String(s)}); }
function __hdr(h) { return h; }
function __resp(r) {
  r = r || {status: 0, headers: {}, body: ''};
  return {
    body: function () { return r.body; },
    code: function () { return r.status; },
    headers: function () { return r.headers; },
    string: function () { return r.body; }
  };
}
function __elem(h) {
  return {
    text: function () { return __host('dom_text', {h: h}); },
    html: function () { return __host('dom_html', {h: h}); },
    attr: function (k) { return __host('dom_attr', {h: h, name: String(k)}); },
    select: function (s) {
      var r = __host('dom_query', {h: h, selector: String(s), many: false});
      return r === null ? null : __elem(r.handle);
    },
    selectAll: function (s) {
      var r = __host('dom_query', {h: h, selector: String(s), many: true});
      var out = [];
      var hs = r.handles || [];
      for (var i = 0; i < hs.length; i++) out.push(__elem(hs[i]));
      return out;
    }
  };
}
var java = {
  log: function () { __host('log', {msg: Array.prototype.join.call(arguments, ' ')}); },
  getString: function (rule, mContent, isUrl) {
    return __host('rule_string', {rule: String(rule), content: mContent === undefined ? null : String(mContent), isUrl: !!isUrl});
  },
  getStringList: function (rule) {
    return __host('rule_list', {rule: String(rule), content: null});
  },
  setContent: function () { throw new Error('java.setContent 暂不支持'); },
  put: function (k, v) { __host('cache_put', {key: '__java__' + String(k), value: JSON.stringify(v === undefined ? null : v)}); return v; },
  ajax: function (url, callTimeout) { return __host('http_string', {url: String(url), timeout: callTimeout}); },
  ajaxAll: function (urls) {
    var arr = typeof urls === 'string' ? JSON.parse(urls) : urls;
    var out = [];
    for (var i = 0; i < arr.length; i++) out.push(__host('http_string', {url: String(arr[i])}));
    return JSON.stringify(out);
  },
  get: function (a, b, c) {
    // legado 按参数个数重载：get(key) = KV 缓存；get(url, headers[, timeout]) = HTTP。
    if (b === undefined) {
      var s = __host('cache_get', {key: '__java__' + String(a)});
      if (s === null || s === undefined || s === '') return null;
      try { return JSON.parse(s); } catch (e) { return s; }
    }
    return __resp(__host('http', {url: String(a), method: 'GET', headers: b || null, timeout: c}));
  },
  post: function (url, body, headers, timeout) {
    return __resp(__host('http', {url: String(url), method: 'POST', body: body === undefined ? '' : String(body), headers: headers || null, timeout: timeout}));
  },
  head: function (url, headers, timeout) {
    return __resp(__host('http', {url: String(url), method: 'HEAD', headers: headers || null, timeout: timeout}));
  },
  connect: function (url, headers, timeout) {
    return __resp(__host('http', {url: String(url), method: 'GET', headers: headers || null, timeout: timeout}));
  },
  md5Encode: function (s) { return __host('digest', {data: String(s), algorithm: 'MD5'}); },
  md5Encode16: function (s) { return __host('md5_16', {data: String(s)}); },
  digestHex: function (data, algorithm) { return __host('digest', {data: String(data), algorithm: String(algorithm)}); },
  digestBase64Str: function (data, algorithm) { return __host('digest_b64', {data: String(data), algorithm: String(algorithm)}); },
  HMacHex: function (data, algorithm, key) { return __host('hmac_hex', {data: String(data), algorithm: String(algorithm), key: String(key)}); },
  HMacBase64: function (data, algorithm, key) { return __host('hmac_base64', {data: String(data), algorithm: String(algorithm), key: String(key)}); },
  base64Encode: function (s) { return __b64e(s); },
  base64Decode: function (s) { return __b64d(s); },
  base64EncodeToByteArray: function (s) { return __b64e(s); },
  base64DecodeToByteArray: function (s) { return __b64d(s); },
  hexEncodeToString: function (s) { return __host('hex_encode', {data: String(s)}); },
  hexDecodeToString: function (s) { return __host('hex_decode', {data: String(s)}); },
  hexDecodeToByteArray: function (s) { return __host('hex_decode', {data: String(s)}); },
  strToBytes: function (s, charset) { return __host('str_to_bytes', {data: String(s), charset: charset || 'utf-8'}); },
  bytesToStr: function (b64, charset) { return __host('bytes_to_str', {data: String(b64), charset: charset || 'utf-8'}); },
  encodeURI: function (s) { return encodeURI(s); },
  encodeURIComponent: function (s) { return encodeURIComponent(s); },
  decodeURI: function (s) { return decodeURI(s); },
  decodeURIComponent: function (s) { return decodeURIComponent(s); },
  timeFormat: function (pattern, time) { return __host('time_format', {pattern: String(pattern), time: time === undefined ? null : time}); },
  timeFormatUTC: function (pattern, time) { return __host('time_format', {pattern: String(pattern), time: time === undefined ? null : time}); },
  toURL: function (url, base) { return __host('abs_url', {url: String(url), base: base === undefined ? '' : String(base)}); },
  createSymmetricCrypto: function (transformation, key, iv) {
    var h = __host('cipher_new', {transformation: String(transformation), key: String(key), iv: iv === undefined ? '' : String(iv)});
    return {
      encrypt: function (data) { return __host('cipher_op', {h: h, op: 'encrypt', data: __b64e(String(data))}); },
      encryptBase64: function (data) { return __host('cipher_op', {h: h, op: 'encrypt', data: __b64e(String(data))}); },
      encryptStr: function (data) { return __host('cipher_op', {h: h, op: 'encrypt', data: __b64e(String(data))}); },
      encryptHex: function (data) { return __host('cipher_op', {h: h, op: 'encrypt_hex', data: __b64e(String(data))}); },
      decrypt: function (data) { return __host('cipher_op', {h: h, op: 'decrypt', data: String(data)}); },
      decryptBase64: function (data) { return __host('cipher_op', {h: h, op: 'decrypt', data: String(data)}); },
      decryptStr: function (data) { return __host('cipher_op', {h: h, op: 'decrypt_str', data: String(data)}); }
    };
  },
  createAsymmetricCrypto: function (transformation) {
    var h = __host('rsa_new', {transformation: String(transformation || 'RSA')});
    return {
      setPublicKey: function (k) { __host('rsa_key', {h: h, kind: 'pub', key: String(k)}); return this; },
      setPrivateKey: function (k) { __host('rsa_key', {h: h, kind: 'priv', key: String(k)}); return this; },
      encrypt: function (d) { return __host('rsa_op', {h: h, op: 'encrypt', data: String(d)}); },
      encryptBase64: function (d) { return __host('rsa_op', {h: h, op: 'encrypt', data: String(d)}); },
      encryptHex: function (d) { return __host('rsa_op', {h: h, op: 'encrypt_hex', data: String(d)}); },
      decrypt: function (d) { return __host('rsa_op', {h: h, op: 'decrypt', data: String(d)}); },
      decryptBase64: function (d) { return __host('rsa_op', {h: h, op: 'decrypt', data: String(d)}); },
      decryptStr: function (d) { return __host('rsa_op', {h: h, op: 'decrypt_str', data: String(d)}); }
    };
  },
  createSign: function (algorithm) {
    return {
      sign: function (data, key) { return __host('hmac_hex', {data: String(data), algorithm: String(algorithm), key: String(key)}); },
      signHex: function (data, key) { return __host('hmac_hex', {data: String(data), algorithm: String(algorithm), key: String(key)}); }
    };
  },
  getElement: function (sel, content) {
    var r = __host('dom_query', {selector: String(sel), content: content === undefined ? null : String(content), many: false});
    return r === null ? null : __elem(r.handle);
  },
  getElements: function (sel, content) {
    var r = __host('dom_query', {selector: String(sel), content: content === undefined ? null : String(content), many: true});
    var out = [];
    var hs = r.handles || [];
    for (var i = 0; i < hs.length; i++) out.push(__elem(hs[i]));
    return out;
  },
  webView: null,
  getWebViewUA: function () { throw new Error('webView 暂不支持'); },
  startBrowser: function () { throw new Error('webView 暂不支持'); },
  startBrowserAwait: function () { throw new Error('webView 暂不支持'); },
  htmlFormat: function (s) { throw new Error('java.htmlFormat 暂不支持'); },
  t2s: function (s) { throw new Error('繁简转换暂不支持'); },
  s2t: function (s) { throw new Error('繁简转换暂不支持'); },
  importScript: function () { throw new Error('importScript 暂不支持'); },
  cacheFile: function () { throw new Error('cacheFile 暂不支持'); },
  toast: function () {},
  longToast: function () {},
  randomUUID: function () { return __host('digest', {data: String(Math.random()) + String(Date.now()), algorithm: 'MD5'}); }
};
var cache = {
  put: function (k, v, saveTime) { __host('cache_put', {key: String(k), value: v === undefined || v === null ? '' : String(v), ttl: saveTime}); },
  get: function (k) { return __host('cache_get', {key: String(k)}); },
  delete: function (k) { __host('cache_del', {key: String(k)}); },
  putMemory: function (k, v) { cache.put(k, v); },
  getFromMemory: function (k) { return cache.get(k); },
  deleteMemory: function (k) { cache.delete(k); },
  putFile: function () { throw new Error('cache.putFile 暂不支持'); },
  getFile: function () { throw new Error('cache.getFile 暂不支持'); }
};
var cookie = {
  getCookie: function (url) { return __host('cookie_get', {url: String(url)}) || ''; },
  getKey: function (url, key) { return __host('cookie_get_key', {url: String(url), key: String(key)}); },
  setCookie: function (url, c) { __host('cookie_set', {url: String(url), value: String(c)}); },
  replaceCookie: function (url, c) { cookie.setCookie(url, c); },
  removeCookie: function (url) { __host('cookie_remove', {url: String(url)}); },
  setWebCookie: function (url, c) { cookie.setCookie(url, c); }
};
var source = {
  getKey: function () { return __sourceKey; },
  getVariable: function () { return __host('cache_get', {key: '__srcvar__'}); },
  putVariable: function (v) { __host('cache_put', {key: '__srcvar__', value: v === undefined || v === null ? '' : String(v)}); return v; },
  put: function (k, v) { cache.put('__src__' + String(k), v); return v; },
  get: function (k) { return cache.get('__src__' + String(k)); },
  getLoginHeaderMap: function () { return {}; },
  getLoginHeader: function () { return ''; },
  getLoginInfoMap: function () { return {}; }
};
''';
}

class _Ctx {
  _Ctx(this.req, {required this.depth, _Ctx? inherit})
      : cache = inherit == null ? Map<String, String>.of(req.cacheIn) : inherit.cache,
        cookies = inherit == null ? _cookieJar(req.cookieIn) : inherit.cookies {
    nextCipherId = inherit?.nextCipherId ?? 0;
  }

  final LegadoJsRequest req;
  final int depth;

  /// 会话缓存/cookie：入参快照起步，写出经 cacheOut/cookieOut 带回主 isolate。
  final Map<String, String> cache;
  final Map<String, Map<String, String>> cookies;
  final Map<int, SymmetricCipher> ciphers = {};
  final Map<int, RsaCipher> rsas = {};
  final List<dom.Element> doms = <dom.Element>[];
  final List<String> logs = [];
  int nextCipherId = 0;
  int nextRsaId = 0;

  Map<String, String> cookieHost(String url) {
    final u = Uri.tryParse(url);
    final host = (u == null || !u.hasScheme) ? '' : u.host;
    return cookies[host] ?? const {};
  }

  Map<String, String> cookieFlat() => {
        for (final e in cookies.entries)
          for (final kv in e.value.entries) '${e.key}|${kv.key}': kv.value,
      };

  static Map<String, Map<String, String>> _cookieJar(Map<String, String> flat) {
    final jar = <String, Map<String, String>>{};
    for (final e in flat.entries) {
      final i = e.key.indexOf('|');
      if (i <= 0) continue;
      jar.putIfAbsent(e.key.substring(0, i), () => {})[e.key.substring(i + 1)] =
          e.value;
    }
    return jar;
  }
}
