/// CatVod JS 源码的 async 改写（纯函数）。
///
/// 背景：spider 的 `req()` 等宿主调用需要「同步」拿到 HTML，但纯 Dart 无法在
/// QuickJS 执行期间同步等 IO。解法：把宿主 API 全部 Promise 化，并改写源码——
/// 裸函数调用包成 `(await call(...))`，`function` 声明 async 化，整体包 async
/// IIFE。`await` 任意值透传，因此对非 Promise 调用无副作用。
///
/// 关键实现：**平衡括号扫描**。`await req(...).body` 的 await 会错误地只作用于
/// `.body`（优先级），因此「标识符调用 + 后续成员链（`.x`/`[…]`/`(…)`）」必须
/// 包成 `(await ident(...)).chain`——await 打在调用上，成员链留在 await 外。
///
/// 已知限制（语法错误由 evaluate 抛出并归为「该源不支持」）：
/// - 只改写**裸标识符**调用（`req(...)`）；`x.req(...)` 等成员调用不改写；
/// - 宿主调用出现在对象字面量简写方法内不受支持。
class SpiderAsyncRewrite {
  SpiderAsyncRewrite._();

  /// 需要保证可 await 的宿主 API（spider 运行时注入的全局函数）。
  static const hostFunctions = [
    'req',
    'pdfh',
    'pdfa',
    'pd',
    'setResult',
    'setHomeResult',
    'setCategory',
    'setDetail',
    'getHtml',
    'post',
    'fetch',
    'local',
  ];

  /// JS 关键字（标识符后跟 `(` 但不是函数调用）。
  static const _keywords = {
    'if', 'for', 'while', 'switch', 'catch', 'return', 'typeof', 'new',
    'function', 'else', 'do', 'delete', 'void', 'instanceof', 'in', 'of',
    'await', 'async', 'with', 'throw', 'let', 'const', 'var', 'class',
    'super', 'this', 'try', 'finally', 'case', 'break', 'continue',
    'default', 'extends', 'static', 'get', 'set',
  };

  /// 模块模式改写：只做 async 化（函数声明 + await 插入），不包 IIFE——
  /// 供运行时把爬虫源码 eval 进隔离作用域后按函数名调用。
  static String rewriteModule(String source) => _insertAwaits(source);

  /// 改写入口：返回 async 化源码（包 async IIFE + 结果 JSON 化）。
  /// 注意：QuickJS 顶层 eval 不允许 `return` 语句，IIFE 直接作为表达式求值。
  static String rewrite(String source) {
    final rewritten = _insertAwaits(source);
    return '(async () => {\n$rewritten\n})()'
        '.then(r => JSON.stringify({__ok: true, __data: r === undefined ? null : r}))'
        '.catch(e => JSON.stringify({__ok: false, __error: String(e)}));';
  }

  // ---------- 扫描实现 ----------

  static bool _isIdentStart(String ch) =>
      RegExp(r'[A-Za-z_$]').hasMatch(ch);
  static bool _isIdentPart(String ch) =>
      RegExp(r'[A-Za-z0-9_$]').hasMatch(ch);

  static String _insertAwaits(String source) {
    final out = StringBuffer();
    var i = 0;
    String? prev; // 上一个非空白代码记号（单词/字符）。

    while (i < source.length) {
      final ch = source[i];

      // 字符串与模板串：模板串的 ${…} 插值递归改写。
      if (ch == '\'' || ch == '"' || ch == '`') {
        final start = i;
        i++;
        var handledInterp = false;
        while (i < source.length) {
          if (source[i] == r'\\') {
            i += 2;
            continue;
          }
          if (ch == '`' &&
              source[i] == r'$' &&
              i + 1 < source.length &&
              source[i + 1] == '{') {
            out.write(source.substring(start, i));
            out.write(r'${');
            i += 2;
            var depth = 1;
            final innerStart = i;
            while (i < source.length && depth > 0) {
              if (source[i] == '{') {
                depth++;
              } else if (source[i] == '}') {
                depth--;
              }
              i++;
            }
            out.write(_insertAwaits(source.substring(innerStart, i - 1)));
            out.write('}');
            handledInterp = true;
            break;
          }
          if (source[i] == ch) {
            i++;
            break;
          }
          i++;
        }
        if (!handledInterp) {
          out.write(source.substring(start, i));
        } else {
          // 插值后模板串继续：重新从当前位扫到下一个插值/闭合。
          out.write(_scanTemplateRest(source, i, prev));
          i = _lastScan;
        }
        prev = 'str';
        continue;
      }

      // 注释。
      if (ch == '/' && i + 1 < source.length) {
        final next = source[i + 1];
        if (next == '/') {
          final end = source.indexOf('\n', i);
          final stop = end < 0 ? source.length : end;
          out.write(source.substring(i, stop));
          i = stop;
          continue;
        }
        if (next == '*') {
          final end = source.indexOf('*/', i + 2);
          final stop = end < 0 ? source.length : end + 2;
          out.write(source.substring(i, stop));
          i = stop;
          continue;
        }
      }

      // 标识符：async function / (await call(...).chain)。
      if (_isIdentStart(ch)) {
        final start = i;
        while (i < source.length && _isIdentPart(source[i])) {
          i++;
        }
        final word = source.substring(start, i);
        if (word == 'function' &&
            prev != '.' &&
            prev != 'async' &&
            prev != 'await') {
          out.write('async ');
          out.write(word);
          prev = 'function';
          continue;
        }
        final j = _skipSpaces(source, i);
        final isCall = j < source.length &&
            source[j] == '(' &&
            !_keywords.contains(word) &&
            prev != '.' &&
            prev != 'new' &&
            prev != 'await' &&
            prev != 'function' &&
            prev != 'async';
        if (isCall) {
          final close = _matchParen(source, j);
          if (close > 0) {
            final chainEnd = _extendChain(source, close + 1);
            // 拆分：头部（标识符+'('）+ 递归改写的参数 + 闭合 + 成员链后缀。
            // await 必须打在**调用**上：`(await req(...)).body`——包成
            // `(await req(...).body)` 会 await 属性访问（Promise.body =
            // undefined），这是首次端到端联调抓出的括号位置 bug。
            out.write('(await ');
            out.write(source.substring(start, j + 1));
            out.write(_insertAwaits(source.substring(j + 1, close)));
            out.write(source.substring(close, close + 1));
            out.write(')');
            out.write(source.substring(close + 1, chainEnd));
            i = chainEnd;
            prev = ')';
            continue;
          }
        }
        out.write(word);
        prev = word;
        continue;
      }

      if (!ch.startsWith(RegExp(r'\s'))) {
        prev = ch;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  /// 处理模板串插值之后的部分；[_lastScan] 记录扫描结束位置。
  static int _lastScan = 0;
  static String _scanTemplateRest(String source, int i, String? prev) {
    final out = StringBuffer();
    final start = i;
    while (i < source.length) {
      if (source[i] == r'\\') {
        i += 2;
        continue;
      }
      if (source[i] == r'$' &&
          i + 1 < source.length &&
          source[i + 1] == '{') {
        out.write(source.substring(start, i));
        out.write(r'${');
        i += 2;
        var depth = 1;
        final innerStart = i;
        while (i < source.length && depth > 0) {
          if (source[i] == '{') {
            depth++;
          } else if (source[i] == '}') {
            depth--;
          }
          i++;
        }
        out.write(_insertAwaits(source.substring(innerStart, i - 1)));
        out.write('}');
        _lastScan = i;
        return out.toString() + _scanTemplateRest(source, i, prev);
      }
      if (source[i] == '`') {
        i++;
        break;
      }
      i++;
    }
    out.write(source.substring(start, i));
    _lastScan = i;
    return out.toString();
  }

  static int _skipSpaces(String s, int i) {
    while (i < s.length && s[i].trim().isEmpty) {
      i++;
    }
    return i;
  }

  /// 从 `(` 位置找匹配的 `)`；跳过字符串与注释。找不到返回 -1。
  static int _matchParen(String s, int openPos) {
    var depth = 0;
    var i = openPos;
    while (i < s.length) {
      final ch = s[i];
      if (ch == '\'' || ch == '"' || ch == '`') {
        i = _skipString(s, i);
        continue;
      }
      if (ch == '/' && i + 1 < s.length && s[i + 1] == '/') {
        final end = s.indexOf('\n', i);
        i = end < 0 ? s.length : end;
        continue;
      }
      if (ch == '/' && i + 1 < s.length && s[i + 1] == '*') {
        final end = s.indexOf('*/', i + 2);
        i = end < 0 ? s.length : end + 2;
        continue;
      }
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) return i;
      }
      i++;
    }
    return -1;
  }

  /// 从调用结束处延伸成员链：`.ident`、`[…]`、`(…)`。
  static int _extendChain(String s, int pos) {
    var i = pos;
    while (i < s.length) {
      final ch = s[i];
      if (ch == '.') {
        // .identifier
        var j = i + 1;
        while (j < s.length && s[j].trim().isEmpty) {
          j++;
        }
        final start = j;
        while (j < s.length && _isIdentPart(s[j])) {
          j++;
        }
        if (j == start) return i;
        i = j;
        continue;
      }
      if (ch == '[') {
        var depth = 0;
        var j = i;
        var inStr = false;
        String? quote;
        while (j < s.length) {
          final c = s[j];
          if (inStr) {
            if (c == r'\\') {
              j += 2;
              continue;
            }
            if (c == quote) {
              inStr = false;
            }
          } else if (c == '\'' || c == '"' || c == '`') {
            inStr = true;
            quote = c;
          } else if (c == '[') {
            depth++;
          } else if (c == ']') {
            depth--;
            if (depth == 0) {
              break;
            }
          }
          j++;
        }
        if (j >= s.length) return i;
        i = j + 1;
        continue;
      }
      if (ch == '(') {
        final close = _matchParen(s, i);
        if (close < 0) return i;
        i = close + 1;
        continue;
      }
      break;
    }
    return i;
  }

  /// 跳过字符串（含模板串余下部分，简化处理）。
  static int _skipString(String s, int start) {
    final quote = s[start];
    var i = start + 1;
    while (i < s.length) {
      if (s[i] == r'\\') {
        i += 2;
        continue;
      }
      if (s[i] == quote) return i + 1;
      i++;
    }
    return s.length;
  }
}