import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_runtime.dart';
import 'package:aquan_duanju/core/books/legado_js/legado_js_crypto.dart';
import 'package:aquan_duanju/core/books/legado_js/legado_js_engine.dart';

import '../spider/native_lib_guard.dart';
import 'rsa_test_keys.dart';

/// LegadoJsEngine 集成测试：真 QuickJS（flutter_qjs）+ 真 FFI syncHttp（Go 核心）
/// + 本地 HTTP 夹具——与生产完全同路径（isolate 内同步通道，无测试桩）。
///
/// 默认 skip（与 spider 集成测试同范式）：`AQUAN_SPIDER_TESTS=1` +
/// `flutter build windows --debug` 产出原生库后运行（tool/run_spider_tests.ps1）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late int port;
  late String profile;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    port = server.port;
    profile =
        '${Directory.systemTemp.path}/legado_js_profile_${DateTime.now().millisecondsSinceEpoch}.json';
    server.listen((req) async {
      final p = req.uri.path;
      final q = req.uri.queryParameters;
      Future<void> reply(String body, {int status = 200}) async {
        req.response.statusCode = status;
        req.response.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        req.response.write(body);
        await req.response.close();
      }

      if (p == '/search') {
        // 夹具校验签名：sign 必须等于 md5(key)（js 引擎真实计算）。
        if (q['sign'] != _md5Of(q['key'] ?? '')) {
          await reply('bad sign', status: 403);
          return;
        }
        await reply('<div class="hit"><a href="/book/1">斗罗</a></div>');
      } else if (p == '/content') {
        await reply(
            '<div id="c">${base64.encode(utf8.encode('第一段\n第二段'))}</div>');
      } else if (p == '/api') {
        await reply(jsonEncode({'code': 200, 'data': 'ok'}));
      } else {
        await reply('nf', status: 404);
      }
    });
  });

  tearDown(() async => server.close(force: true));

  bool ensureNative() {
    if (!ensureFlutterQjsLibrary()) return false;
    // Go 核心（syncHttp 通道）：预加载失败则 skip。
    final aqua = findNativeLibrary('aquan_core.dll');
    if (aqua == null) {
      return false;
    }
    try {
      DynamicLibrary.open(aqua);
    } catch (_) {
      return false;
    }
    return true;
  }

  test('S0：md5/base64/绑定变量（真 QuickJS）', () async {
    if (!ensureNative()) return;
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final res = await engine.eval(
      'java.md5Encode("abc") + "|" + java.base64Encode("斗罗") + "|" + key + "|" + page',
      bindings: {'key': '斗罗', 'page': 2, 'result': '', 'baseUrl': 'http://x/'},
    );
    expect(res.value, '900150983cd24fb0d6963f7d28e17f72|5paX572X|斗罗|2');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('S0：java.getString 递归（纯选择器 + 嵌套 js）', () async {
    if (!ensureNative()) return;
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final res = await engine.eval(
      r'java.getString("class.hit@tag.a@text") + "|" + java.getString("<js>1+1</js>")',
      bindings: {
        'result': '<div class="hit"><a href="/b">斗罗</a></div>',
        'baseUrl': 'http://x/',
      },
    );
    expect(res.value, '斗罗|2');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('cache/java.put-get 跨 eval（cacheIn/Out 信封）', () async {
    if (!ensureNative()) return;
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final r1 = await engine.eval('java.put("k", "v1"); cache.put("c", "v2");');
    expect(r1.cacheOut['__java__k'], jsonEncode('v1'));
    expect(r1.cacheOut['c'], 'v2');
    final r2 = await engine.eval(
      'java.get("k") + "|" + cache.get("c")',
      cacheIn: r1.cacheOut,
    );
    expect(r2.value, 'v1|v2');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('java.ajax 同步网络（FFI syncHttp → 本地夹具）', () async {
    if (!ensureNative()) return;
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final res = await engine.eval(
      'var r = java.get(baseUrl + "/api", {}); r.body() + "|" + r.code()',
      bindings: {
        'result': '',
        'baseUrl': 'http://127.0.0.1:$port',
      },
    );
    expect(res.value, '{"code":200,"data":"ok"}|200');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('端到端：@js: 签名搜索 URL + <js> base64 正文解码（BookSourceRuntime）',
      () async {
    if (!ensureNative()) return;
    final source = BookSource(
      url: 'http://127.0.0.1:$port',
      name: 'js夹具',
      searchUrl:
          '@js:baseUrl + "/search?key=" + encodeURIComponent(key) + "&sign=" + java.md5Encode(key)',
      ruleSearch: const BookRuleGroup(
          bookList: 'class.hit', name: 'tag.a', bookUrl: 'tag.a@href'),
      ruleContent: const BookContentRule(
          content: r'<js>java.base64Decode(java.getString("id.c"))</js>'),
    );
    final rt = BookSourceRuntime(
      enforceSsrf: false,
      jsEngine: LegadoJsEngine(enforceSsrf: false, profilePath: profile),
    );
    final hits = await rt.search(source, '斗罗');
    expect(hits, hasLength(1), reason: '签名由 js 引擎真实计算，夹具校验通过才有结果');
    expect(hits.single.name, '斗罗');
    final text = await rt.content(source, 'http://127.0.0.1:$port/content');
    expect(text, '第一段\n第二段');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('createAsymmetricCrypto：js 内 RSA 加密 → Dart 私钥解密', () async {
    if (!ensureNative()) return;
    final (pub, priv) = rsaTestKeygen();
    final pubPem = rsaPublicPem(pub);
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final res = await engine.eval(
      'var c = java.createAsymmetricCrypto("RSA/ECB/PKCS1Padding"); '
      'c.setPublicKey(${jsonEncode(pubPem)}); '
      'c.encrypt("js 里的 RSA 明文")',
      bindings: {'result': '', 'baseUrl': ''},
    );
    // 用 Dart 侧私钥解开 js 的密文 → 证明 shim 与密钥材料解析全链路正确。
    final dec = LegadoJsCrypto.createAsymmetricCrypto('RSA/ECB/PKCS1Padding')
      ..setPrivateKey(rsaPrivatePem(priv));
    expect(dec.decryptStr('${res.value}'), 'js 里的 RSA 明文');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('java.getElement/getElements：DOM 句柄 .text()/.attr()/.selectAll()', () async {
    if (!ensureNative()) return;
    final engine = LegadoJsEngine(enforceSsrf: false, profilePath: profile);
    final res = await engine.eval(
      'var e = java.getElement("div.hit"); '
      'var links = e.selectAll("a"); '
      'e.text() + "|" + links[0].attr("href")',
      bindings: {
        'result':
            '<div class="hit"><a href="/b/1">书名甲</a><a href="/b/2">书名乙</a></div>',
        'baseUrl': 'http://x/',
      },
    );
    expect(res.value, '书名甲书名乙|/b/1');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

/// 与生产同源的 md5（crypto 包），供夹具期望值。
String _md5Of(String input) => crypto.md5.convert(utf8.encode(input)).toString();
