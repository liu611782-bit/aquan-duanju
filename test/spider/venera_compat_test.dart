// Venera 源契约兼容探活：库加载 → 真源（18漫画）实例化 → explore 真网络调用。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/venera/venera_js_runtime.dart';

import 'native_lib_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('Venera 源加载协议 + explore 真网络', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final runtime = VeneraJsRuntime.instance;
    addTearDown(runtime.dispose);
    final js =
        File('test/spider/fixtures/venera_baozi.js').readAsStringSync();
    final info = await runtime.loadSource(js);
    expect(info['key'], 'baozi');
    expect(info['version'], isNotEmpty);

    // explore[0].load() 真网络（返回分类页对象，含 title/comics）。
    final result = await runtime
        .callMethod('baozi', 'explore.0.load', [])
        .timeout(const Duration(seconds: 30));
    // ignore: avoid_print
    print('explore → ${result.runtimeType} '
        '${result is Map ? result.keys.toList() : result}');
    expect(result, isA<Map>(), reason: 'explore 应返回对象（title/comics 等）');
    final comics = (result as Map)['comics'];
    expect(comics, isA<List>(), reason: 'explore 应返回漫画列表');
    if (comics is List && comics.isNotEmpty) {
      // ignore: avoid_print
      print('首部 → ${jsonEncode(comics.first)}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
