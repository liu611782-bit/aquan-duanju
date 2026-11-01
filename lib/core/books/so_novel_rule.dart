import 'dart:convert';

import 'package:html/dom.dart';

import 'so_novel_selector.dart';

/// so-novel 规则 DSL 求值（research §2）。语法：`<selector>(@js:…)*(@java:…)*`，
/// `@` 是**步骤/属性边界**（第一个 `@` 前是选择器；选择器本身不含 `@`）。
///
/// 内容类型（`getContentType`）：串里含 `@href`→绝对 href、`@src`→绝对 src、
/// `@value`→value 属性、选择器以 `meta[` 开头→content 属性、否则→text。
/// 步骤链：`@js:` 交给注入的 [runJs]（P2 接 QuickJS），`@java:` 见 [_javaExec]。
class SoNovelRule {
  const SoNovelRule();

  /// 取字段值：在 [root] 子树里按 [query] 选择 → 取内容 → 跑步骤链。
  static String extract(
    Node root,
    String query, {
    String baseUri = '',
    String Function(String code, String input)? runJs,
    bool html = false,
  }) {
    if (query.trim().isEmpty) return '';
    final sel = selectorOf(query);
    final ct = html ? SoContentType.html : contentTypeOf(query);
    final els = sel.isEmpty ? const <Element>[] : soNovelSelect(root, sel);
    var result = _contentOf(els, ct, baseUri);
    for (final step in stepsOf(query)) {
      switch (step.lang) {
        case 'js':
          if (runJs == null) {
            throw SoNovelSelectorException('未提供 @js 运行器', query);
          }
          result = runJs(step.code, result);
        case 'java':
          result = _javaExec(step.code, result);
        default:
          throw SoNovelSelectorException('未知步骤语言 @${step.lang}:', query);
      }
    }
    return result;
  }

  /// 容器选择（`result`/`toc.item` 等）：只用 `@` 前的选择器，取元素列表。
  static List<Element> selectList(Node root, String query) {
    final sel = selectorOf(query);
    return sel.isEmpty ? const <Element>[] : soNovelSelect(root, sel);
  }

  /// 第一个 `@` 前 = 选择器。
  static String selectorOf(String query) {
    final at = query.indexOf('@');
    return (at < 0 ? query : query.substring(0, at)).trim();
  }

  static SoContentType contentTypeOf(String query) {
    if (query.contains('@href')) return SoContentType.href;
    if (query.contains('@src')) return SoContentType.src;
    if (query.contains('@value')) return SoContentType.value;
    if (selectorOf(query).startsWith('meta[')) return SoContentType.content;
    return SoContentType.text;
  }

  /// 抽 `@js:` / `@java:` 步骤（code 里可含 `@`/`:`，只按 `@js:`/`@java:` 标记切）。
  static List<SoStep> stepsOf(String query) {
    final re = RegExp(r'@(js|java):');
    final marks = re.allMatches(query).toList();
    final steps = <SoStep>[];
    for (var i = 0; i < marks.length; i++) {
      final start = marks[i].end;
      final end = i + 1 < marks.length ? marks[i + 1].start : query.length;
      steps.add(SoStep(marks[i].group(1)!, query.substring(start, end).trim()));
    }
    return steps;
  }

  static String _contentOf(
    List<Element> els,
    SoContentType ct,
    String baseUri,
  ) {
    if (els.isEmpty) return '';
    switch (ct) {
      case SoContentType.text:
        return els.map((e) => e.text).join(' ').trim();
      case SoContentType.html:
        return els.map((e) => e.innerHtml).join();
      case SoContentType.href:
        return _absUrl(els.first.attributes['href'], baseUri);
      case SoContentType.src:
        return _absUrl(els.first.attributes['src'], baseUri);
      case SoContentType.value:
        return els.first.attributes['value'] ?? '';
      case SoContentType.content:
        return els.first.attributes['content'] ?? '';
    }
  }

  static String _absUrl(String? raw, String baseUri) {
    if (raw == null || raw.trim().isEmpty) return '';
    final v = raw.trim();
    if (baseUri.isEmpty) return v;
    return Uri.tryParse(baseUri)?.resolve(v).toString() ?? v;
  }

  /// `@java:` 仅两短语（research §2.3）：base64.decode() 与 string.replace(a,b)。
  static String _javaExec(String code, String input) {
    final c = code.trim();
    if (c == 'base64.decode()') {
      final out = StringBuffer();
      for (final line in input.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        try {
          out.write(utf8.decode(base64Decode(t)));
        } catch (_) {/* 非法行跳过 */}
      }
      return out.toString();
    }
    final m = RegExp(r"string\.replace\('([^']*)','([^']*)'\)").firstMatch(c);
    if (m != null) {
      // so-novel 用 Java replaceAll：第一参数按正则。
      try {
        return input.replaceAll(RegExp(m.group(1)!), m.group(2)!);
      } catch (_) {
        return input.replaceAll(m.group(1)!, m.group(2)!);
      }
    }
    return input; // 未知 @java: 短语：原样返回（与 so-novel 一致）
  }
}

class SoStep {
  const SoStep(this.lang, this.code);
  final String lang; // 'js' | 'java'
  final String code;
}

enum SoContentType { text, html, href, src, value, content }
