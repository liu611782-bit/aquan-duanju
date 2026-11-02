import 'package:html/dom.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';

/// so-novel 选择器子集引擎（package:html 缺 `:nth-of-type`/`:contains`、`:nth-child(even)`
/// 静默失效，且 so-novel 规则里 nth-of-type 常处**中置** compound，末尾后过滤救不回，
/// 故自带小型引擎）。支持：tag、`#id`、`.class`、`[attr]`/`[attr=v]`/`[attr^=v]`/
/// `[attr\$=v]`/`[attr*=v]`、`:nth-of-type(anb|odd|even|n)`、`:nth-child(同)`、
/// `:not(简单compound)`、`:contains('x')`，组合符 `>`(子)、空格(后代)、`+`(相邻)、`~`(后续兄弟)。
///
/// 不支持项抛 [SoNovelSelectorException]（诚实报错，不静默产空，符合"禁止静默降级"）。
class SoNovelSelectorException implements Exception {
  SoNovelSelectorException(this.message, [this.selector = '']);
  final String message;
  final String selector;
  @override
  String toString() =>
      'SoNovelSelector: $message${selector.isEmpty ? '' : ' 在 [$selector]'}';
}

/// 从 root 子树按 so-novel 选择器取元素（文档顺序、去重）。
List<Element> soNovelSelect(Node root, String selector) {
  final sel = selector.trim();
  if (sel.isEmpty) return const [];
  // so-novel 判定（HtmlExtractor.java:37-43）：`^(/|//|\()` → XPath。
  // （so-novel 规则串里 `@` 是步骤边界，选择器部分不会含 @attr 后缀——
  // XPath 一律返回**元素**，内容由调用方按内容类型取。）
  if (sel.startsWith('/') || sel.startsWith('(')) {
    final node = root is Element
        ? root
        : root is Document
            ? root.documentElement ?? root
            : root;
    final result = HtmlXPath.node(node).query(sel);
    final out = <Element>[];
    for (final n in result.nodes) {
      final el = n.node;
      if (el is Element) out.add(el);
    }
    return out;
  }
  final parts = _parseSelector(sel);
  var current = _matchCompound(root, parts.first.compound, sel);
  for (var i = 1; i < parts.length; i++) {
    final step = parts[i];
    final next = <Element>[];
    for (final el in current) {
      next.addAll(_related(el, step.combinator)
          .where((e) => _compoundMatches(e, step.compound, sel)));
    }
    current = _dedupe(next);
  }
  return current;
}

class _Step {
  _Step(this.combinator, this.compound);
  final String combinator; // '', '>', '+', '~'
  final String compound;
}

/// 顶层按组合符切分（尊重引号/括号/方括号内的空格与符号）。
/// 产出 [(combinator, compound)]，首个 combinator 为空；`>`/`+`/`~` 显式优先，
/// 其余空白视为后代 `' '`。
List<_Step> _parseSelector(String sel) {
  final steps = <_Step>[];
  final buf = StringBuffer();
  var depth = 0;
  var comb = '';
  var havePrev = false;
  String? quote;
  void flush() {
    final c = buf.toString().trim();
    buf.clear();
    if (c.isEmpty) return;
    steps.add(_Step(havePrev ? comb : '', c));
    havePrev = true;
    comb = '';
  }

  for (var i = 0; i < sel.length; i++) {
    final ch = sel[i];
    if (quote != null) {
      buf.write(ch);
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == '(' || ch == '[') {
      depth++;
      buf.write(ch);
      continue;
    }
    if (ch == ')' || ch == ']') {
      depth--;
      buf.write(ch);
      continue;
    }
    if (depth == 0 && (ch == '>' || ch == '+' || ch == '~')) {
      flush();
      comb = ch;
      continue;
    }
    if (depth == 0 && ch == ' ') {
      if (buf.toString().trim().isNotEmpty) flush();
      continue;
    }
    buf.write(ch);
  }
  flush();
  if (steps.isEmpty) throw SoNovelSelectorException('空选择器', sel);
  return steps;
}

List<Element> _matchCompound(Node root, String compound, String sel) {
  final out = <Element>[];
  void walk(Node n) {
    for (final c in n.children) {
      if (_compoundMatches(c, compound, sel)) out.add(c);
      walk(c);
    }
  }

  if (root is Element) {
    // root 自身也可能是候选（如从某元素起 select）——但 so-novel 总是在文档/子树内取，
    // 保持只遍历后代，避免把 root 自己算进去。
    walk(root);
  } else {
    walk(root);
  }
  return out;
}

/// combinator 语义下 el 的相关元素。
List<Element> _related(Element el, String combinator) {
  switch (combinator) {
    case '>':
      return el.children;
    case '+':
      return _following(el).take(1).toList();
    case '~':
      return _following(el);
    default: // ' ' 后代
      final out = <Element>[];
      void walk(Node n) {
        for (final c in n.children) {
          out.add(c);
          walk(c);
        }
      }

      walk(el);
      return out;
  }
}

List<Element> _following(Element el) {
  final parent = el.parent;
  if (parent == null) return const [];
  final siblings = parent.children;
  final idx = siblings.indexOf(el);
  return idx < 0 ? const [] : siblings.sublist(idx + 1);
}

bool _compoundMatches(Element el, String compound, String sel) {
  final s = _Simple.parse(compound, sel);
  if (s.tag != null && s.tag != '*' && el.localName?.toLowerCase() != s.tag) {
    return false;
  }
  if (s.id != null && el.id != s.id) return false;
  final classes = el.className.split(RegExp(r'\s+'));
  for (final c in s.classes) {
    if (!classes.contains(c)) return false;
  }
  for (final a in s.attrs) {
    if (!_attrMatches(el, a)) return false;
  }
  for (final p in s.pseudos) {
    if (!_pseudoMatches(el, p, compound, sel)) return false;
  }
  return true;
}

bool _attrMatches(Element el, _Attr a) {
  final v = el.attributes[a.name];
  if (v == null) return false; // 属性不存在
  if (a.value == null) return true; // [attr] 存在即可
  switch (a.op) {
    case '=':
      return v == a.value;
    case '^=':
      return v.startsWith(a.value!);
    case r'$=':
      return v.endsWith(a.value!);
    case '*=':
      return v.contains(a.value!);
    case '~=':
      return v.split(RegExp(r'\s+')).contains(a.value);
    default:
      return v == a.value;
  }
}

bool _pseudoMatches(Element el, _Pseudo p, String compound, String sel) {
  switch (p.name) {
    case 'nth-of-type':
      return _nth(p.arg)(_typeIndex(el));
    case 'nth-child':
      return _nth(p.arg)(_childIndex(el));
    case 'not':
      // 仅支持简单 compound（不含组合符）；嵌套 not/nth 不支持。
      if (p.arg.contains('>') ||
          p.arg.contains(' ') ||
          p.arg.contains('+') ||
          p.arg.contains('~') ||
          p.arg.contains('nth-') ||
          p.arg.contains('contains')) {
        throw SoNovelSelectorException(':not 仅支持简单选择器: ${p.arg}', sel);
      }
      return !_compoundMatches(el, p.arg, sel);
    case 'contains':
      return el.text.contains(_unquote(p.arg));
    default:
      throw SoNovelSelectorException('不支持的伪类 :${p.name}', sel);
  }
}

int _typeIndex(Element el) {
  final parent = el.parent;
  if (parent == null) return 1;
  var i = 0;
  for (final s in parent.children) {
    if (s.localName == el.localName) {
      i++;
      if (s == el) return i;
    }
  }
  return i;
}

int _childIndex(Element el) {
  final parent = el.parent;
  if (parent == null) return 1;
  return parent.children.indexOf(el) + 1;
}

/// 解析 `anb+/-c` / `odd` / `even` / 整数 → 1-based 序号判定函数。
bool Function(int) _nth(String arg) {
  final a = arg.trim().toLowerCase();
  if (a == 'odd') return (i) => i.isOdd;
  if (a == 'even') return (i) => i.isEven;
  if (a == 'n') return (i) => i >= 1;
  // 纯整数
  final asInt = int.tryParse(a);
  if (asInt != null) return (i) => i == asInt;
  // an+b 形式（支持 '2n', '2n+1', '-n+3', '3n-2'）
  final m = RegExp(r'^(-?\d*)n([+-]\d+)?$').firstMatch(a.replaceAll(' ', ''));
  if (m == null) throw SoNovelSelectorException('无法解析 nth 参数: $arg', arg);
  final aStr = m.group(1) ?? '';
  final coeff = aStr.isEmpty
      ? 1
      : (aStr == '-' ? -1 : int.parse(aStr));
  final b = m.group(2) != null ? int.parse(m.group(2)!) : 0;
  return (i) {
    if (coeff == 0) return i == b;
    final k = i - b;
    return k % coeff == 0 && k ~/ coeff >= 0;
  };
}

List<Element> _dedupe(List<Element> els) {
  final seen = <Element>{};
  final out = <Element>[];
  for (final e in els) {
    if (seen.add(e)) out.add(e);
  }
  return out;
}

String _unquote(String s) {
  final t = s.trim();
  if (t.length >= 2 &&
      ((t.startsWith('"') && t.endsWith('"')) ||
          (t.startsWith("'") && t.endsWith("'")))) {
    return t.substring(1, t.length - 1);
  }
  return t;
}

// ---- compound 解析 ----

class _Simple {
  _Simple._();
  String? tag;
  String? id;
  final classes = <String>[];
  final attrs = <_Attr>[];
  final pseudos = <_Pseudo>[];

  static _Simple parse(String compound, String sel) {
    final s = _Simple._();
    var i = 0;
    final n = compound.length;
    // 起始 tag（直到遇到 # . [ : 或结束）
    var start = 0;
    while (i < n &&
        compound[i] != '#' &&
        compound[i] != '.' &&
        compound[i] != '[' &&
        compound[i] != ':') {
      i++;
    }
    start = i;
    if (start > 0) s.tag = compound.substring(0, start).toLowerCase();

    while (i < n) {
      final ch = compound[i];
      if (ch == '#') {
        var j = i + 1;
        while (j < n && compound[j] != '.' && compound[j] != '[' && compound[j] != ':') {
          j++;
        }
        s.id = compound.substring(i + 1, j);
        i = j;
      } else if (ch == '.') {
        var j = i + 1;
        while (j < n && compound[j] != '.' && compound[j] != '[' && compound[j] != ':') {
          j++;
        }
        s.classes.add(compound.substring(i + 1, j));
        i = j;
      } else if (ch == '[') {
        var j = i + 1;
        String? quote;
        while (j < n) {
          if (quote != null) {
            if (compound[j] == quote) quote = null;
          } else if (compound[j] == '"' || compound[j] == "'") {
            quote = compound[j];
          } else if (compound[j] == ']') {
            break;
          }
          j++;
        }
        s.attrs.add(_Attr.parse(compound.substring(i + 1, j), sel));
        i = j + 1;
      } else if (ch == ':') {
        var j = i + 1;
        // 跳过可能的 `:`（:: 伪元素，不支持）
        if (j < n && compound[j] == ':') {
          throw SoNovelSelectorException('不支持伪元素 ::', sel);
        }
        var k = j;
        while (k < n && compound[k] != '(' && compound[k] != '.' &&
            compound[k] != '[' && compound[k] != ':') {
          k++;
        }
        final name = compound.substring(j, k);
        if (k < n && compound[k] == '(') {
          var depth = 1;
          var m = k + 1;
          String? q;
          while (m < n && depth > 0) {
            final c = compound[m];
            if (q != null) {
              if (c == q) q = null;
            } else if (c == '"' || c == "'") {
              q = c;
            } else if (c == '(') {
              depth++;
            } else if (c == ')') {
              depth--;
            }
            m++;
          }
          s.pseudos.add(_Pseudo(name, compound.substring(k + 1, m - 1)));
          i = m;
        } else {
          throw SoNovelSelectorException('伪类需带参数: :$name', sel);
        }
      } else {
        i++;
      }
    }
    return s;
  }
}

class _Attr {
  _Attr(this.name, this.op, this.value);
  final String name;
  final String? op;
  final String? value;

  factory _Attr.parse(String inner, String sel) {
    final eq = RegExp(r'([~^*\$]?=)').firstMatch(inner);
    if (eq == null) return _Attr(inner.trim(), null, null);
    final name = inner.substring(0, eq.start).trim();
    final op = eq.group(1)!;
    final raw = inner.substring(eq.end).trim();
    return _Attr(name, op, _unquote(raw));
  }
}

class _Pseudo {
  _Pseudo(this.name, this.arg);
  final String name;
  final String arg;
}
