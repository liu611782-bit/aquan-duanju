import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// legado 规则求值引擎——本项目支持的子集。
///
/// - URL 模板：`{{key}}` / `{{page}}` 占位 + 逗号尾随的请求选项 JSON
///   （`url,{ "method":"POST", "body":"searchkey={{key}}&page={{page}}" }`）。
/// - 列表/字段规则：JSONPath 简集（`$.data.books[*]`）或 CSS 简集
///   （`class.bookbox@tag.h4@tag.a@text`）。
/// - `##regex##replacement` 尾缀：命中后清洗（正文高频）。
/// - `||`：首个命中即返回；`&&`：结果拼接。
/// - 不支持 `js:` / `<js>`（模型层 [BookSource.requiresJs] 先行拦截）。
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

  /// 列表规则：从页面（HTML 或 JSON）求出一批节点。
  static List<dynamic> evalList(Object page, String rule) {
    final expr = _splitAlternatives(rule).first;
    if (page is Map<String, dynamic> || page is List<dynamic>) {
      return _jsonList(page, expr);
    }
    return _cssList(page, expr);
  }

  /// 字段规则：从节点求字符串。
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

  /// `##regex##replacement` 清洗执行。
  static String applyClean(String value, (String, String)? clean) {
    if (clean == null) return value;
    try {
      return value.replaceAll(RegExp(clean.$1), clean.$2);
    } catch (_) {
      return value;
    }
  }

  // ---------- 内部 ----------

  /// `a || b` 首个命中；`a && b` 拼接。这里列表求值只取首个可用分支。
  static Iterable<String> _splitAlternatives(String rule) sync* {
    for (final part in rule.split('||')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) yield trimmed;
    }
  }

  static (String, (String, String)?) _splitClean(String rule) {
    final idx = rule.indexOf('##');
    if (idx < 0) return (rule.trim(), null);
    final expr = rule.substring(0, idx).trim();
    final rest = rule.substring(idx + 2);
    final sep = rest.indexOf('##');
    if (sep < 0) return (expr, (rest, ''));
    return (expr, (rest.substring(0, sep), rest.substring(sep + 2)));
  }

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
