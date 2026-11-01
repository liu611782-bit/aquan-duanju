/// legado 规则串的分段器（对标 `AnalyzeRule.splitSourceRule` / `AnalyzeUrl`，research §3.3）。
///
/// 语法事实（AppPattern.kt:7-11）：
/// - `JS_PATTERN = <js>([\w\W]*?)</js>|@js:([\w\W]*)`（`@js:` 吃到串尾）
/// - `@webjs:` → 需要 WebView，诚实报不支持
/// - `{{…}}` 内嵌 js（URL 通道求值）
/// 现代 legado **没有**裸 `js:` 前缀（research §3.4）。
library;

class LegadoJsRewrite {
  LegadoJsRewrite._();

  static final RegExp jsPattern =
      RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);
  static final RegExp webJsPattern =
      RegExp(r'@webjs:([\w\W]{5,})', caseSensitive: false);
  static final RegExp embedPattern = RegExp(r'\{\{([\w\W]*?)\}\}');

  /// 是否含 js 语法（`<js>` / `@js:` / `@webjs:` / `{{…}}`）。
  /// 注意：不匹配裸 `js:`（误伤面大且现代 legado 无此语法）。
  static bool containsJs(String rule) =>
      jsPattern.hasMatch(rule) ||
      webJsPattern.hasMatch(rule) ||
      embedPattern.hasMatch(rule);

  static bool containsWebJs(String rule) => webJsPattern.hasMatch(rule);

  /// 规则串切段：js 段（[RuleSegment.isJs]）与普通段按出现顺序排列。
  ///
  /// `<js>code</js>tail` → [js(code), text(tail)]；`sel@js:code` →
  /// [text(sel), js(code)]；无 js → 单个 text 段。
  static List<RuleSegment> split(String rule) {
    final segments = <RuleSegment>[];
    var start = 0;
    for (final m in jsPattern.allMatches(rule)) {
      if (m.start > start) {
        segments.add(RuleSegment(
            false, rule.substring(start, m.start), webJs: false));
      }
      final code = (m.group(2) ?? m.group(1) ?? '').trim();
      final prefix = rule.substring(start, m.start);
      segments.add(RuleSegment(
          true, code, webJs: webJsPattern.hasMatch(prefix + m.group(0)!)));
      start = m.end;
    }
    if (start < rule.length) {
      segments.add(RuleSegment(false, rule.substring(start), webJs: false));
    }
    if (segments.isEmpty) segments.add(RuleSegment(false, rule, webJs: false));
    return segments;
  }

  /// `||` 分支切分，**引号与 `<js>…</js>` 内不切**（legado RuleAnalyzer.splitRule
  /// 的避坑语义；本工程旧实现是简单 split，含 js 的规则会切坏脚本）。
  static List<String> splitAlternatives(String rule) {
    final parts = <String>[];
    final buf = StringBuffer();
    var i = 0;
    String? quote;
    var inJsBlock = false;
    while (i < rule.length) {
      final ch = rule[i];
      if (inJsBlock) {
        if (ch == '<' && rule.startsWith('</js>', i)) {
          inJsBlock = false;
          buf.write('</js>');
          i += 5;
          continue;
        }
        buf.write(ch);
        i++;
        continue;
      }
      if (quote != null) {
        buf.write(ch);
        if (ch == quote) quote = null;
        i++;
        continue;
      }
      if (ch == '"' || ch == '\'') {
        quote = ch;
        buf.write(ch);
        i++;
        continue;
      }
      if (ch == '<' && rule.toLowerCase().startsWith('<js>', i)) {
        inJsBlock = true;
        buf.write('<js>');
        i += 4;
        continue;
      }
      if (ch == '|' && i + 1 < rule.length && rule[i + 1] == '|') {
        parts.add(buf.toString());
        buf.clear();
        i += 2;
        continue;
      }
      buf.write(ch);
      i++;
    }
    parts.add(buf.toString());
    return [
      for (final p in parts)
        if (p.trim().isNotEmpty) p.trim()
    ];
  }

  /// URL 里的内嵌 `{{…}}` 求值项（`{{key}}/{{page}}` 字面占位除外——保持旧契约）。
  static List<EmbedPiece> urlEmbeds(String url) {
    final out = <EmbedPiece>[];
    for (final m in embedPattern.allMatches(url)) {
      final inner = m.group(1)!.trim();
      if (inner == 'key' || inner == 'page' || inner == 'searchPage') {
        continue;
      }
      out.add(EmbedPiece(m.start, m.end, inner));
    }
    return out;
  }
}

class RuleSegment {
  const RuleSegment(this.isJs, this.text, {required this.webJs});
  final bool isJs;

  /// js 段 = 代码；普通段 = 选择器/文本规则。
  final String text;

  /// `@webjs:` 段（需要 WebView，诚实报不支持）。
  final bool webJs;
}

class EmbedPiece {
  const EmbedPiece(this.start, this.end, this.code);
  final int start;
  final int end;
  final String code;
}
