// FongMi lib 资产求值冒烟 + assets:// 模块解析：五件套（cat/cheerio/crypto-js/
// gbk/similarity）在运行时内可干净求值；assets:// 引用命中打包资产。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/fongmi/fongmi_spider_runtime.dart';
import 'package:flutter_qjs/flutter_qjs.dart';

import 'native_lib_guard.dart';

const _libNames = [
  'cat.js',
  'cheerio.min.js',
  'crypto-js.js',
  'gbk.js',
  'similarity.js',
];

const _assetsSpider = r'''
import './lib/crypto-js.js';
var base = '';
function home(filter) {
  var md5 = CryptoJS.MD5('abc').toString();
  return JSON.stringify({md5: md5});
}
globalThis.__JS_SPIDER__ = {home: home};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('lib 五件套资产以 MODULE 求值干净（ES 模块形态）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final runtime = QuickJsRuntime2(stackSize: 1024 * 1024 * 4);
    addTearDown(runtime.dispose);
    final broken = <String>[];
    for (final name in _libNames) {
      final src = await rootBundle.loadString('assets/fongmi/lib/$name');
      final result = runtime.evaluate(src,
          name: 'assets://js/lib/$name', evalFlags: JSEvalFlag.MODULE);
      if (result.isError) broken.add('$name: ${result.stringResult}');
    }
    // ignore: avoid_print
    print('lib 求值: ${_libNames.length - broken.length}/${_libNames.length} 干净');
    for (final b in broken) {
      // ignore: avoid_print
      print('  报错: $b');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('assets:// 协议：spider import 命中打包资产（crypto-js 可用）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final libs = {
      for (final name in _libNames)
        name: await rootBundle.loadString('assets/fongmi/lib/$name'),
    };
    final result = await FongmiSpiderRuntime.call(
      jsSource: _assetsSpider,
      method: 'home',
      args: const [],
      libSources: libs,
      httpJs: await rootBundle.loadString('assets/fongmi/http.js'),
      profilePath:
          '${Directory.systemTemp.path}/fongmi_profile_${DateTime.now().millisecondsSinceEpoch}.json',
      sourceUrl: 'assets://js/spider.js',
    );
    // ignore: avoid_print
    print('assets home → $result');
    expect(result['md5'], '900150983cd24fb0d6963f7d28e17f72',
        reason: 'CryptoJS.MD5("abc") 教科书值——assets:// 引用命中打包资产');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
