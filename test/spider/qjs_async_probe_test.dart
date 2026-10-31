// flutter_qjs 异步桥基线探针（spider 运行时的技术基线回归）。
// 运行前置：flutter build windows --debug 后把 runner/Debug 加入 PATH
// （flutter_qjs_plugin.dll + quickjs_c_bridge.dll），AQUAN_SPIDER_TESTS=1。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_qjs/flutter_qjs.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'native_lib_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      req.response.write('<html><body><div class="item">A</div>'
          '<div class="item">B</div><div class="item">C</div></body></html>');
      await req.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  test('异步桥基线：通道 await / 嵌套 hop / 同步混用 / 改写产物', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final rt = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    addTearDown(rt.dispose);
    rt.enableHandlePromises();
    rt.onMessage('spReq', (args) async {
      final url = ((args as Map)['url'] ?? '').toString();
      final res = await http.get(Uri.parse(url));
      return jsonEncode({'body': res.body, 'statusCode': res.statusCode});
    });
    rt.onMessage('spEcho', (args) {
      final map = args is Map ? args : <String, dynamic>{};
      return 'echo:${map['v']}';
    });
    rt.evaluate('''
function spNormalize(v) { return typeof v === 'string' ? JSON.parse(v) : v; }
async function req2(o) { return spNormalize(await sendMessage('spReq', JSON.stringify(o))); }
''');

    // 1) 纯 JS promise（无通道）。
    final r1 =
        await rt.handlePromise(await rt.evaluateAsync('Promise.resolve(42)'));
    expect(r1.stringResult, '42');

    // 2) async 通道：await 到 Dart Future（body 长度 = 夹具 101 字符）。
    final r2 = await rt.handlePromise(await rt.evaluateAsync('''
(async () => {
  var v = spNormalize(await sendMessage('spReq', JSON.stringify({url: 'http://127.0.0.1:${server.port}/a'})));
  return v.body.length;
})().catch(e => 'ERR:' + String(e))
'''));
    expect(r2.stringResult, '101');

    // 3) 嵌套 hop：具名 async 函数内 await 通道，外层再 await 该函数。
    final r3 = await rt.handlePromise(await rt.evaluateAsync('''
(async () => {
  var a = await req2({url: 'http://127.0.0.1:${server.port}/n1'});
  return typeof a.body;
})().catch(e => 'ERR:' + String(e))
'''));
    expect(r3.stringResult, 'string');

    // 4) 同步 handler 与异步 handler 混用。
    final r4 = await rt.handlePromise(await rt.evaluateAsync('''
(async () => {
  var e1 = await sendMessage('spEcho', JSON.stringify({v: 'a'}));
  var q = await req2({url: 'http://127.0.0.1:${server.port}/mix'});
  return JSON.stringify({e1: e1, q: typeof q});
})().catch(e => 'ERR:' + String(e))
'''));
    expect(r4.stringResult, contains('"e1":"echo:a"'));

    // 5) 改写产物原样执行（synthetic 同形：load IIFE + snapshot + call IIFE）。
    rt.evaluate('''
(function(){
var base = 'http://127.0.0.1:${server.port}';
async function cat3(tid) {
  var html = (await req2({url: base + '/list?tid=' + tid})).body;
  return JSON.stringify({len: html.length});
}
globalThis.__sp = globalThis.__sp || {};
var ns = {};
try { if (typeof cat3 === 'function') ns['cat3'] = cat3; } catch(e) {}
globalThis.__sp['k1'] = ns;
})();
''');
    final r5 = await rt.handlePromise(await rt.evaluateAsync('''
(async () => {
  var f = globalThis.__sp['k1'].cat3;
  return await f('1');
})().catch(e => 'ERR:' + String(e))
'''));
    expect(r5.stringResult, contains('"len":101'));
  });
}
