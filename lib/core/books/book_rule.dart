import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'legado_js/legado_js_rewrite.dart';

/// js 求值接缝（legado_js 引擎注入；测试注入桩）。
abstract interface class JsRuleRunner {
  /// 执行 js 片段；[result] 为上段输出/当前内容；返回 String（字段规则）
  /// 或 List/Map（列表规则，js 直接产数组）。
  Future<Object?> evalJs(
    String code, {
    Object? result,
    String baseUrl = '',
    Map<String, Object?> extra = const {},
  });
}

/// legado 规则求值引擎——本项目支持的子集。
///
/// - URL 模板：`{{key}}` / `{{page}}` 占位 + 逗号尾随的请求选项 JSON
///   （`url,{ "method":"POST", "body":"searchkey={{key}}&page={{page}}" }`）。
/// - 列表/字段规则：JSONPath 简集（`$.data.books[*]`）或 CSS 简集
///   （`class.bookbox@tag.h4@tag.a@text`）。
/// - `##regex##replacement` 尾缀：命中后清洗（正文高频）。
/// - `||`：首个命中即返回；`&&`：结果拼接。
/// - js 段（`<js>`/`@js:`）：提供 [JsRuleRunner] 时分段执行（`evalStringAsync` /
///   `evalListAsync` / `parseSearchUrlAsync`）；无 runner 时拒绝（诚实报错）。
class BookRule {
  /// 拆出请求选项：`url` 与 `BookRequestOptions`。
  static (String, BookRequestOptions) parseSearchUrl(String searchUrl) {
    var url = searchUrl.trim();
    var options = const BookRequestOptions();
    // legado：主 URL 后跟逗号 + JSON 选项（JSON 里也可能有逗号，从第一个 `,`+`{` 切）。
    final brace = url.indexOf(',{');
    if (brace >= 0) {
      // 无条件先切掉 `,{...}` 选项块：即便选项 JSON 解析失败，主 URL 也不能残留
      // 选项文本，否则整串（相对路径 + 垃圾）会被当成 URL 送进 SSRF 校验。
      final optText = url.substring(brace + 1);
      url = url.substring(0, brace);
      try {
        final decoded = jsonDecode(optText);
        if (decoded is Map<String, dynamic>) {
          options = BookRequestOptions.fromJson(decoded);
        }
      } catch (_) {/* 选项解析不了：URL 已清洗，按纯 GET 处理 */}
    }
    return (url.trim(), options);
  }

  /// 填充搜索词与页码占位。
  static String fillUrl(String url, {required String key, required int page}) {
    final encoded = Uri.encodeComponent(key);
    return url
        .replaceAll('{{key}}', encoded)
        .replaceAll('{{page}}', '$page');
  }

  /// URL 通道（对齐 AnalyzeUrl.initUrl 顺序）：先 js 产出 URL → `{{…}}` 内嵌
  /// js 求值（`{{key}}/{{page}}` 字面占位保持旧契约，不进 js）→ 切选项 → 填 key/page。
  static Future<(String, BookRequestOptions)> parseSearchUrlAsync(
    String searchUrl, {
    required String key,
    required int page,
    JsRuleRunner? js,
    String baseUrl = '',
  }) async {
    var url = searchUrl.trim();
    if (js != null && LegadoJsRewrite.containsJs(url)) {
      // AnalyzeUrl.analyzeJs：段序列 result 传递；文本段（js 前缀）按 `@result`→result 拼接。
      var result = '';
      for (final seg in LegadoJsRewrite.split(url)) {
        if (seg.webJs) {
          throw FormatException('@webjs: 需要 WebView，暂不支持');
        }
        if (seg.isJs) {
          result = '${await js.evalJs(seg.text,
              result: result, baseUrl: baseUrl, extra: {'key': key, 'page': page})}';
        } else {
          result += seg.text.replaceAll('@result', result);
        }
      }
      url = result.trim();
      if (url.isEmpty) {
        throw FormatException('搜索 URL 的 js 求值为空');
      }
    }
    if (js != null) {
      final embeds = LegadoJsRewrite.urlEmbeds(url);
      for (final e in embeds.reversed) {
        final value = await js.evalJs(e.code,
            result: key, baseUrl: baseUrl, extra: {'key': key, 'page': page});
        url = url.replaceRange(e.start, e.end, '$value');
      }
    }
    final (clean, options) = parseSearchUrl(url);
    return (fillUrl(clean, key: key, page: page), options);
  }

  /// 列表规则：从页面（HTML 或 JSON）求出一批节点（js 无关路径，行为不变）。
  static List<dynamic> evalList(Object page, String rule) {
    final expr = _splitAlternatives(rule).first;
    if (expr.startsWith('/')) {
      // XPath：现引擎无求值器，诚实报错（package:html 只认 CSS，此前会抛笼统异常）。
      throw FormatException('XPath 规则暂不支持: $expr');
    }
    if (page is Map<String, dynamic> || page is List<dynamic>) {
      return _jsonList(page, expr);
    }
    return _cssList(page, expr);
  }

  /// 列表规则（支持 js 段）。无 js 的规则走 [evalList]（行为逐字节一致）。
  static Future<List<dynamic>> evalListAsync(
    Object page,
    String rule, {
    JsRuleRunner? js,
  }) async {
    if (LegadoJsRewrite.containsJs(rule) && js == null) {
      throw FormatException('js 列表规则需要 js 引擎（未注入 runner）: $rule');
    }
    if (js == null || !LegadoJsRewrite.containsJs(rule)) {
      return evalList(page, rule);
    }
    for (final alt in LegadoJsRewrite.splitAlternatives(rule)) {
      try {
        var content = page is String ? page : jsonEncode(page);
        var isListShape = false;
        for (final seg in LegadoJsRewrite.split(alt)) {
          if (seg.webJs) throw FormatException('@webjs: 需要 WebView，暂不支持');
          if (seg.isJs) {
            content =
                '${await js.evalJs(seg.text, result: content)}';
          } else {
            final nodes = evalList(_maybeParseJson(content), seg.text);
            content = jsonEncode(nodes);
            isListShape = true;
          }
        }
        final parsed = _maybeParseJson(content);
        if (parsed is List) return parsed;
        if (parsed is Map) return [parsed];
        if (!isListShape && parsed is String && parsed.isNotEmpty) {
          return [parsed];
        }
      } on FormatException {
        rethrow;
      } catch (_) {
        // 分支失败：尝试下一 || 分支。
      }
    }
    return const [];
  }

  /// 字段规则：从节点求字符串（js 无关路径，行为不变）。
  static String evalString(
    dynamic node,
    String rule, {
    String baseUrl = '',
  }) {
    final parts = _splitAlternatives(rule);
    for (final part in parts) {
      final (expr, clean) = _splitClean(part);
      var value = '';
      if (expr.isNotEmpty) {
        if (expr.startsWith('/')) {
          throw FormatException('XPath 规则暂不支持: $expr');
        }
        if (node is Map<String, dynamic> || node is List<dynamic>) {
          value = _jsonString(node, expr);
        } else {
          value = _cssString(node, expr);
        }
      } else if (node is String) {
        value = node;
      } else if (node is Map && expr.isEmpty) {
        value = node.values.join(' ');
      }
      value = applyClean(value, clean);
      if (value.trim().isNotEmpty) return _absoluteUrl(value.trim(), baseUrl);
    }
    return '';
  }

  /// 字段规则（支持 js 段）。无 js 的规则走 [evalString]（行为逐字节一致）。
  ///
  /// 分段语义（AnalyzeRule.getString）：段序列 `result` 传递；文本段的选择器作用
  /// 于**当前内容字符串**；js 段返回值成为下一段输入；`##` 清洗作用于整条分支
  /// 的最终输出（与旧契约一致）。
  static Future<String> evalStringAsync(
    dynamic node,
    String rule, {
    String baseUrl = '',
    JsRuleRunner? js,
    Map<String, Object?> bindings = const {},
  }) async {
    if (LegadoJsRewrite.containsJs(rule) && js == null) {
      throw FormatException('js 字段规则需要 js 引擎（未注入 runner）: $rule');
    }
    if (js == null || !LegadoJsRewrite.containsJs(rule)) {
      return evalString(node, rule, baseUrl: baseUrl);
    }
    for (final alt in LegadoJsRewrite.splitAlternatives(rule)) {
      try {
        final (expr, clean) = splitClean(alt);
        var content = node is String
            ? node
            : (node is Map || node is List ? jsonEncode(node) : '${node ?? ''}');
        var out = content;
        for (final seg in LegadoJsRewrite.split(expr)) {
          if (seg.webJs) {
            throw FormatException('@webjs: 需要 WebView，暂不支持');
          }
          if (seg.isJs) {
            out = '${await js.evalJs(seg.text,
                result: content, baseUrl: baseUrl, extra: bindings)}';
          } else {
            out = evalString(_maybeParseJson(content), seg.text,
                baseUrl: baseUrl);
          }
          content = out;
        }
        final value = applyClean(out.trim(), clean);
        if (value.trim().isNotEmpty) {
          return _absoluteUrl(value.trim(), baseUrl);
        }
      } on FormatException {
        rethrow;
      } catch (_) {
        // 分支失败：尝试下一 || 分支。
      }
    }
    return '';
  }

  /// 内容字符串里的选择器求值入参：JSON 内容先解码（js 段常产 JSON）。
  static Object _maybeParseJson(String content) {
    final t = content.trim();
    if (t.startsWith('{') || t.startsWith('[')) {
      try {
        return jsonDecode(t);
      } catch (_) {}
    }
    return content;
  }

  /// `##regex##replacement` 清洗执行。
  static String applyClean(String value, (String, String)? clean) {
    if (clean == null) return value;
    try {
      return value.replaceAll(RegExp(clean.$1), clean.$2);
    } catch (_) {
      return value;
    }
  }

  /// `##` 尾缀拆分（runtime 的 `_splitContentRule` 与内部 `_splitClean` 的收敛点）。
  static (String, (String, String)?) splitClean(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) return (rule.trim(), null);
    final expr = rule.substring(0, idx).trim();
    final rest = rule.substring(idx + 2);
    final sep = rest.indexOf('##');
    if (sep < 0) return (expr, (rest, ''));
    return (expr, (rest.substring(0, sep), rest.substring(sep + 2)));
  }

  // ---------- 内部 ----------

  /// `a || b` 首个命中；`a && b` 拼接。这里列表求值只取首个可用分支。
  static Iterable<String> _splitAlternatives(String rule) sync* {
    for (final part in rule.split('||')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  static (String, (String, String)?) _splitClean(String rule) =>
      splitClean(rule);

  // ---------- JSONPath 简集 ----------

  static dynamic _jsonGet(Object? node, String path) {
    if (path.startsWith(r'$.') || path.startsWith(r'$.')) {
      path = path.substring(2);
    } else if (path == r'$') {
      return node;
    }
    var current = node;
    for (final seg in path.split('.')) {
      if (seg.isEmpty) continue;
      if (seg == '*') {
        if (current is List) return current;
        if (current is Map) return current.values.toList();
        return null;
      }
      // `key[*]` 或 `key[0]`
      final bracket = RegExp(r'^(.*?)\[(\*|\d+)\]$').firstMatch(seg);
      final key = bracket?.group(1) ?? seg;
      final index = bracket?.group(2);
      if (current is List) {
        if (index == null) return null;
        final i = int.tryParse(index);
        if (i == null || i >= current.length) return null;
        current = current[i];
      } else if (current is Map) {
        var next = current[key];
        if (next == null && bracket != null) {
          // 递归键：$.//name 风格 → 同名键深搜。
          for (final v in current.values) {
            if (v is Map) {
              final found = v[key];
              if (found != null) {
                next = found;
                break;
              }
            }
          }
        }
        if (next == null) return null;
        current = next;
      } else {
        return null;
      }
      if (index == '*') {
        if (current is List) return current;
        return null;
      }
    }
    return current;
  }

  static List<dynamic> _jsonList(Object page, String expr) {
    final got = _jsonGet(page, expr);
    if (got is List) return got;
    if (got is Map) return [got];
    return const [];
  }

  static String _jsonString(Object? node, String expr) {
    final got = _jsonGet(node, expr);
    if (got == null) return '';
    if (got is String) return got;
    if (got is num || got is bool) return '$got';
    if (got is List) return got.map((e) => '$e').join(' ');
    return '$got';
  }

  // ---------- CSS 简集 ----------

  static dom.Document _document(Object page) {
    if (page is dom.Document) return page;
    return html_parser.parse(page.toString());
  }

  static dom.Element? _query(dom.Document doc, String sel) {
    // `id.xxx` / `class.xxx` 简写。
    if (sel.startsWith('id.')) {
      return doc.getElementById(sel.substring(3));
    }
    if (sel.startsWith('class.')) {
      final items = doc.getElementsByClassName(sel.substring(6));
      return items.isEmpty ? null : items.first;
    }
    if (sel.startsWith('tag.')) {
      final items = doc.getElementsByTagName(sel.substring(4));
      return items.isEmpty ? null : items.first;
    }
    final items = doc.querySelectorAll(sel);
    return items.isEmpty ? null : items.first;
  }

  static List<dom.Element> _queryAll(
    dom.Document doc,
    String sel,
  ) {
    if (sel.startsWith('class.')) {
      return doc.getElementsByClassName(sel.substring(6)).toList();
    }
    if (sel.startsWith('tag.')) {
      return doc.getElementsByTagName(sel.substring(4)).toList();
    }
    if (sel.startsWith('id.')) {
      final e = doc.getElementById(sel.substring(3));
      return e == null ? const [] : [e];
    }
    return doc.querySelectorAll(sel).toList();
  }

  static List<dynamic> _cssList(Object page, String expr) {
    final doc = _document(page);
    // 列表规则可能是链式的 `class.xx@tag.li`：按 `@` 逐段走。
    final segments = expr.split('@');
    var nodes = _queryAll(doc, segments.first);
    for (var i = 1; i < segments.length && nodes.isNotEmpty; i++) {
      final seg = segments[i];
      if (_attrLike(seg) || seg == 'text' || seg == 'textNodes') continue;
      final next = <dom.Element>[];
      for (final node in nodes) {
        if (seg.startsWith('class.')) {
          next.addAll(node.getElementsByClassName(seg.substring(6)));
        } else if (seg.startsWith('tag.')) {
          next.addAll(node.getElementsByTagName(seg.substring(4)));
        } else {
          next.addAll(node.querySelectorAll(seg));
        }
      }
      nodes = next;
    }
    return nodes;
  }

  static bool _attrLike(String seg) =>
      seg == 'href' || seg == 'src' || seg == 'content' || seg == 'value';

  static String _cssString(Object? node, String expr) {
    final segments = expr.split('@');
    dom.Element? current;
    if (node is dom.Element) {
      current = node;
    } else if (node is dom.Document) {
      current = _query(node, segments.first) ??
          (segments.first.startsWith('id.') ||
                  segments.first.startsWith('class.') ||
                  segments.first.startsWith('tag.')
              ? _query(node, segments.first)
              : null);
      if (current == null) return '';
      segments.removeAt(0);
    } else if (node is String) {
      final doc = html_parser.parse(node);
      current = segments.isEmpty ? doc.documentElement : _query(doc, segments.first);
      if (current == null) return '';
      if (segments.isNotEmpty) segments.removeAt(0);
    }
    var attr = segments.isEmpty ? 'text' : segments.last;
    var root = current!;
    for (var i = 0; i < segments.length - 1; i++) {
      final seg = segments[i];
      if (_attrLike(seg) || seg == 'text' || seg == 'textNodes') continue;
      dom.Element? next;
      if (seg.startsWith('class.')) {
        final items = root.getElementsByClassName(seg.substring(6));
        next = items.isEmpty ? null : items.first;
      } else if (seg.startsWith('tag.')) {
        final items = root.getElementsByTagName(seg.substring(4));
        next = items.isEmpty ? null : items.first;
      } else {
        final items = root.querySelectorAll(seg);
        next = items.isEmpty ? null : items.first;
      }
      if (next == null) return '';
      root = next;
    }
    if (attr == 'text' || attr == 'textNodes') {
      return root.text.trim();
    }
    if (_attrLike(attr)) {
      return root.attributes[attr] ?? '';
    }
    // 其余按属性名取；取不到退回文本。
    return root.attributes[attr] ?? root.text.trim();
  }

  static String _absoluteUrl(String value, String baseUrl) {
    if (baseUrl.isEmpty) return value;
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    // 只对「长得像路径」的值补全：长文本（正文/简介）会被 Uri.resolve
    // 整段吞进查询串。
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
}

/// 搜索请求选项（legado 的 `, { ... }` 尾随 JSON）。
class BookRequestOptions {
  const BookRequestOptions({
    this.method = 'GET',
    this.body = '',
    this.headers = const {},
    this.charset = '',
  });

  final String method;
  final String body;
  final Map<String, String> headers;
  final String charset;

  bool get isPost => method.toUpperCase() == 'POST';

  factory BookRequestOptions.fromJson(Map<String, dynamic> json) =>
      BookRequestOptions(
        method: json['method']?.toString() ?? 'GET',
        body: json['body']?.toString() ?? '',
        charset: json['charset']?.toString() ?? '',
        headers: json['headers'] is Map
            ? (json['headers'] as Map).map(
                (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
              )
            : const {},
      );
}
