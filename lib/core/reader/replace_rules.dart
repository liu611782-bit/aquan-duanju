/// 正文替换规则：去广告、去水印、去「本章未完」这类站点噪声。
///
/// 规则在 `htmlToParagraphs` 之后、简繁转换与分页之前逐段执行：
/// 一条规则命中后段落变空就把整段丢掉，这样分页不会留下空白行。
library;

import 'dart:convert';

/// 规则作用域。
enum ReplaceScope {
  global('全部书籍'),
  book('当前书籍');

  const ReplaceScope(this.label);

  final String label;

  static ReplaceScope fromName(Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return ReplaceScope.global;
  }
}

/// 一条替换规则。
class ReplaceRule {
  const ReplaceRule({
    required this.id,
    required this.name,
    required this.pattern,
    this.replacement = '',
    this.isRegex = true,
    this.enabled = true,
    this.scope = ReplaceScope.global,
    this.bookId = '',
    this.builtin = false,
  });

  factory ReplaceRule.fromJson(Map<String, dynamic> json) => ReplaceRule(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        pattern: json['pattern'] as String? ?? '',
        replacement: json['replacement'] as String? ?? '',
        isRegex: json['is_regex'] as bool? ?? true,
        enabled: json['enabled'] as bool? ?? true,
        scope: ReplaceScope.fromName(json['scope']),
        bookId: json['book_id'] as String? ?? '',
        builtin: json['builtin'] as bool? ?? false,
      );

  final String id;
  final String name;
  final String pattern;
  final String replacement;

  /// 关掉表示按字面量替换（等价于 `String.replaceAll`）。
  final bool isRegex;
  final bool enabled;
  final ReplaceScope scope;
  final String bookId;

  /// 内置规则：删除后可在「恢复内置」里找回。
  final bool builtin;

  ReplaceRule copyWith({
    String? name,
    String? pattern,
    String? replacement,
    bool? isRegex,
    bool? enabled,
    ReplaceScope? scope,
  }) =>
      ReplaceRule(
        id: id,
        name: name ?? this.name,
        pattern: pattern ?? this.pattern,
        replacement: replacement ?? this.replacement,
        isRegex: isRegex ?? this.isRegex,
        enabled: enabled ?? this.enabled,
        scope: scope ?? this.scope,
        bookId: bookId,
        builtin: builtin,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'pattern': pattern,
        'replacement': replacement,
        'is_regex': isRegex,
        'enabled': enabled,
        'scope': scope.name,
        'book_id': bookId,
        'builtin': builtin,
      };
}

/// 内置规则：默认开启，覆盖最常见的站点噪声。
const List<ReplaceRule> kBuiltinReplaceRules = <ReplaceRule>[
  ReplaceRule(
    id: 'builtin_url',
    name: '去掉正文里的网址',
    pattern: r'https?://[A-Za-z0-9\-._~:/?#\[\]@!$&()*+,;=%]+',
    isRegex: true,
    builtin: true,
  ),
  ReplaceRule(
    id: 'builtin_promo',
    name: '去掉站点推广语',
    pattern: r'(本章未完[，,]?\s*请|点击下一页继续|请记住本站|手机用户请|最新网址|首发地址|'
        r'笔趣阁|请收藏本站|一秒记住|更新最快)',
    isRegex: true,
    builtin: true,
  ),
  ReplaceRule(
    id: 'builtin_blank',
    name: '折叠连续空白',
    pattern: r'[ \t\u3000]{2,}',
    replacement: ' ',
    isRegex: true,
    builtin: true,
  ),
  ReplaceRule(
    id: 'builtin_paren',
    name: '去掉括号广告位',
    pattern: r'[（(]\s*(?:未完待续|本章完|求月票|求推荐票)\s*[)）]',
    isRegex: true,
    builtin: true,
  ),
];

/// 书级别名：把规则按作用域过滤出对 [bookId] 生效的那批。
List<ReplaceRule> rulesForBook(List<ReplaceRule> rules, String bookId) => [
      for (final rule in rules)
        if (rule.enabled &&
            (rule.scope == ReplaceScope.global ||
                (rule.scope == ReplaceScope.book && rule.bookId == bookId)))
          rule,
    ];

/// 逐段应用规则；替换后为空白的段落直接丢弃。
///
/// 返回新列表，不修改入参。
List<String> applyReplaceRules(List<String> paragraphs, List<ReplaceRule> rules) {
  final active = rules.where((r) => r.enabled && r.pattern.isNotEmpty).toList();
  if (active.isEmpty) return paragraphs;
  final out = <String>[];
  for (final paragraph in paragraphs) {
    var text = paragraph;
    for (final rule in active) {
      text = _applyOne(text, rule);
      if (text.isEmpty) break;
    }
    final trimmed = text.trim();
    if (trimmed.isEmpty) continue;
    out.add(trimmed);
  }
  return out;
}

String _applyOne(String text, ReplaceRule rule) {
  if (!rule.isRegex) {
    return rule.replacement.isEmpty
        ? text.replaceAll(rule.pattern, '')
        : text.replaceAll(rule.pattern, rule.replacement);
  }
  final regex = _compile(rule.pattern);
  if (regex == null) return text;
  return text.replaceAll(regex, rule.replacement);
}

final Map<String, RegExp?> _cache = <String, RegExp?>{};

RegExp? _compile(String pattern) {
  if (_cache.containsKey(pattern)) return _cache[pattern];
  RegExp? compiled;
  try {
    compiled = RegExp(pattern);
  } catch (_) {
    compiled = null;
  }
  _cache[pattern] = compiled;
  return compiled;
}

/// 解析 legado/阅读 的「净化规则」JSON，转成本工程的 [ReplaceRule]。
///
/// 兼容字段：`name`/`rule`（正则）/`replacement`/`isRegex`/`isEnabled`，
/// 也接受 `pattern` 与 `{replaceRules:[...]}` 包装；无法识别的条目跳过。
List<ReplaceRule> parseLegadoPurificationRules(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return const [];
  }
  final List<dynamic> items;
  if (decoded is List) {
    items = decoded;
  } else if (decoded is Map<String, dynamic>) {
    final list = decoded['replaceRules'] ?? decoded['rules'];
    if (list is List) {
      items = list;
    } else {
      items = [decoded];
    }
  } else {
    return const [];
  }

  final out = <ReplaceRule>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    if (item is! Map) continue;
    final name = (item['name'] ?? '净化规则 ${i + 1}').toString();
    final pattern = (item['rule'] ?? item['pattern'] ?? '').toString();
    if (pattern.isEmpty) continue;
    // 只收能编译的正则：坏规则塞进去只会静默失效。
    if (!isValidPattern(pattern)) continue;
    out.add(ReplaceRule(
      id: 'imp_${name.hashCode.toRadixString(36)}_$i',
      name: name,
      pattern: pattern,
      replacement: (item['replacement'] ?? '').toString(),
      isRegex: item['isRegex'] is bool ? item['isRegex'] as bool : true,
      enabled: item['isEnabled'] is bool ? item['isEnabled'] as bool : true,
    ));
  }
  return out;
}

/// 校验一条正则是否可用（规则编辑页用）。
bool isValidPattern(String pattern) {
  if (pattern.isEmpty) return false;
  try {
    RegExp(pattern);
    return true;
  } catch (_) {
    return false;
  }
}
