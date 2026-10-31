import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/sources/spider_async_rewrite.dart';

void main() {
  group('SpiderAsyncRewrite.rewrite', () {
    test('宿主调用加 await + function 声明 async 化 + 包 async IIFE', () {
      const src = '''
function homeContent() {
  var html = req('http://x/home');
  return setResult([]);
}
function searchContent(key) {
  var d = pdfh(getHtml(), '.list&&.item');
  return d;
}
''';
      final out = SpiderAsyncRewrite.rewrite(src);
      expect(out, contains('(async () => {'));
      expect(out, contains('async function homeContent()'));
      expect(out, contains('async function searchContent(key)'));
      expect(out, contains('await req('));
      expect(out, contains('await setResult('));
      expect(out, contains('await pdfh('));
      expect(out, contains('await getHtml('));
      // 调用点之间也要 await（async 函数间互调）。
      expect(out, isNot(contains('var html = req(')));
    });

    test('字符串与注释内的宿主函数名不受影响', () {
      const src = '''
function a() {
  var s = 'req(不是调用)';
  // req(注释里也不加)
  var t = "pdfh(x)";
  return s + t;
}
''';
      final out = SpiderAsyncRewrite.rewrite(src);
      expect(out, contains("'req(不是调用)'"));
      expect(out, contains('// req(注释里也不加)'));
      expect(out, contains('"pdfh(x)"'));
      expect(out, isNot(contains("await 'req(")));
    });

    test('关键字与 new / 方法链 / 属性访问不加 await', () {
      const src = '''
function b(obj) {
  if (obj.x) { }
  var d = new Date();
  var n = obj.num(1);
  var t = typeof obj;
  for (var i = 0; i < 3; i++) { }
  return t;
}
var r = b(obj);
''';
      final out = SpiderAsyncRewrite.rewrite(src);
      expect(out, isNot(contains('await if ')));
      expect(out, isNot(contains('await new Date()')));
      expect(out, isNot(contains('await obj.num')));
      expect(out, isNot(contains('await typeof')));
      expect(out, isNot(contains('await for')));
      expect(out, contains('await b(obj)'), reason: '普通函数互调也要 await');
    });

    test('成员链：await 打在调用上，链留在 await 外（端到端抓出的括号 bug）', () {
      const src = 'function c() { var h = req({url: 1}).body; return h; }';
      final out = SpiderAsyncRewrite.rewrite(src);
      expect(out, contains("(await req({url: 1})).body"),
          reason: '(await req(...).body) 会 await 属性访问，得到 undefined');
      expect(out, isNot(contains('await req({url: 1}).body')));
    });

    test('await 幂等：已含 await 的调用不重复', () {
      const src = 'function c() { await req("http://x"); }';
      final out = SpiderAsyncRewrite.rewrite(src);
      expect('await await'.allMatches(out).length, 0);
      expect(out, contains('await req('));
    });

    test('方法简写与箭头函数体存在时语法可能失败（已知限制），但不崩溃', () {
      const src = '''
var obj = {
  m() { return req('http://x'); }
};
var f = () => { return req('http://y'); };
''';
      // 不抛异常；简写方法内 m() 调用是普通函数互调会被加 await。
      final out = SpiderAsyncRewrite.rewrite(src);
      expect(out, isNotEmpty);
    });

    test('模板串内的插值表达式会改写（宿主调用在代码区）', () {
      const src = 'function d() { var s = `x=1&u=\${req("http://a")}`; return s; }';
      final out = SpiderAsyncRewrite.rewrite(src);
      // 插值内的宿主调用需加 await（${} 包裹由 tokenizer 消化，语义等价）。
      expect(out, contains('await req('));
    });
  });
}
