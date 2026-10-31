// Venera 33 源批量探活矩阵：逐源（fresh 引擎）加载 → explore[0].load 真网络，
// 输出存活/数量/耗时汇总。联调工具：默认 skip，AQUAN_SMOKE_REAL=1 显式开启；
// 需本地克隆 D:/IdeaProjects/venera-configs。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/venera/venera_js_runtime.dart';
import 'package:aquan_duanju/core/sources/venera/venera_manga_source.dart';

import '../spider/native_lib_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('Venera 源批量探活矩阵', () async {
    if (Platform.environment['AQUAN_SMOKE_REAL'] != '1') {
      markTestSkipped('批量探活默认跳过：设 AQUAN_SMOKE_REAL=1 运行');
      return;
    }
    if (!ensureFlutterQjsLibrary()) return;
    final dir = Directory('D:/IdeaProjects/venera-configs');
    if (!dir.existsSync()) {
      markTestSkipped('本地无 venera-configs 克隆');
      return;
    }
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.js'))
        .where((f) => !f.path.contains('_venera_') &&
            !f.path.contains('_template_'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final rows = <(String, String, int, int)>[]; // name, state, comics, ms
    var okCount = 0;
    for (final f in files) {
      final name = f.uri.pathSegments.last.replaceAll('.js', '');
      final sw = Stopwatch()..start(); // 单引擎共存 = app 真实场景（多源同引擎）。
      var state = 'OK';
      var count = 0;
      try {
        final source = VeneraMangaSource(f.readAsStringSync());
        await source.load();
        final comics = await source
            .exploreLoad(0)
            .timeout(const Duration(seconds: 12));
        count = comics.length;
        if (count == 0) {
          state = 'EMPTY';
          // EMPTY 时打印 explore 原始返回形态（映射诊断）。
          final raw = await VeneraJsRuntime.instance
              .callMethod(source.key, 'explore.0.load', [])
              .timeout(const Duration(seconds: 12));
          var head = const JsonEncoder.withIndent('').convert(raw);
          if (head.length > 240) head = head.substring(0, 240);
          // ignore: avoid_print
          print('[$name] EMPTY raw: $head');
        }
      } catch (e) {
        state = 'FAIL';
        rows.add((name, '$state: ${'$e'.toString().substring(0, e.toString().length.clamp(0, 60))}', count, sw.elapsedMilliseconds));
        continue;
      }
      sw.stop();
      if (state == 'OK') okCount++;
      rows.add((name, state, count, sw.elapsedMilliseconds));
      // ignore: avoid_print
      print('[$name] $state comics=$count ${sw.elapsedMilliseconds}ms');
    }
    // ignore: avoid_print
    print('=== 矩阵汇总 === 存活 $okCount/${rows.length}');
    for (final r in rows) {
      // ignore: avoid_print
      print('  ${r.$1.padRight(20)} ${r.$2.padRight(8)} ${r.$3.toString().padLeft(4)} ${r.$4}ms');
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
