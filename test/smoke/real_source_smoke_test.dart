// 真实公网源端到端冒烟：内置索引站 → 源市场扫描管线（提取+逐源探测）→
// 存活 CMS 源全链路（分类/列表/详情/搜索/试播），输出存活矩阵。
//
// 这是**联调工具**，不是确定性单测：真实站点随时可能挂。默认 skip；显式
// `AQUAN_SMOKE_REAL=1` 才跑。断言保持最弱（扫描出候选且有存活 CMS；全挂时不
// 阻塞——存活断言只打日志）。运行：env -u http_proxy … AQUAN_SMOKE_REAL=1
// flutter test test/smoke
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/cms_json_adapter.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_market.dart';

const _smokeEnv = 'AQUAN_SMOKE_REAL';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 的 binding 把 HttpClient 换成「一律 400」的 mock；
  // 真实源冒烟跑真实网络，必须恢复真实实现。
  setUp(() => HttpOverrides.global = null);

  test('真实公网 CMS 源全链路冒烟', () async {
    if (Platform.environment[_smokeEnv] != '1') {
      markTestSkipped('真实源冒烟默认跳过：设 $_smokeEnv=1 运行（依赖公网）');
      return;
    }

    // 1) 源市场扫描管线（生产同款）：内置索引站 → 提取 → 逐源探测。
    final scanner = MarketScanner();
    MarketScanDone? done;
    await for (final e in scanner.scan(builtinMarketSites)) {
      if (e is MarketScanDone) done = e;
    }
    done ??= const MarketScanDone(<MarketCandidateResult>[]);
    final okCandidates =
        done.results.where((r) => r.isOk).toList(growable: false);
    // ignore: avoid_print
    print('=== 扫描 === 索引站 ${builtinMarketSites.length} 个 → '
        '候选 ${done.results.length}，探测存活 ${okCandidates.length}');
    for (final r in okCandidates.take(5)) {
      // ignore: avoid_print
      print('  ${r.latencyMs}ms [${r.candidate.kind.name}] ${r.candidate.name}');
    }
    expect(done.results, isNotEmpty, reason: '索引站应至少提取 1 个候选源');
    expect(
      okCandidates.where((r) => r.candidate.kind == SourceKind.cmsJson),
      isNotEmpty,
      reason: '应有存活的 CMS JSON 源（本轮冒烟对象）',
    );

    // 2) 全链路：存活 CMS 候选的前 3 个跑 分类→列表→详情→搜索→试播。
    final picked = okCandidates
        .where((r) => r.candidate.kind == SourceKind.cmsJson)
        .take(3)
        .map((r) => SourceConfig(
              id: 'smoke_${r.candidate.name.hashCode}',
              name: r.candidate.name,
              apis: [r.candidate.api],
              kind: SourceKind.cmsJson,
              headers: r.candidate.headers,
            ))
        .toList();
    var fullChainSurvivors = 0;
    for (final config in picked) {
      final adapter = CmsJsonAdapter(config);
      final buf = StringBuffer('  [${config.name}] ${config.api}\n    ');
      try {
        final sw = Stopwatch()..start();
        final cats = await adapter.categories().timeout(const Duration(seconds: 10));
        buf.write(' 分类${cats.length}(${sw.elapsedMilliseconds}ms)');
        sw.reset();
        final page = await adapter
            .list(categoryId: cats.isEmpty ? null : cats.first.id, page: 1)
            .timeout(const Duration(seconds: 10));
        buf.write(' 列表${page.items.length}(${sw.elapsedMilliseconds}ms)');
        if (page.items.isEmpty) throw StateError('列表为空');
        sw.reset();
        final series = await adapter
            .detail(page.items.first.sourceItemId)
            .timeout(const Duration(seconds: 10));
        buf.write(
            ' 详情「${series.title}」线路${series.lines.length}(集${series.lines.fold<int>(0, (n, l) => n + l.episodes.length)})(${sw.elapsedMilliseconds}ms)');
        sw.reset();
        final hits = await adapter
            .search(page.items.first.title, page: 1)
            .timeout(const Duration(seconds: 10))
            .toList();
        final hitCount = hits
            .whereType<SourceHits>()
            .fold<int>(0, (n, e) => n + e.items.length);
        buf.write(' 搜索$hitCount(${sw.elapsedMilliseconds}ms)');
        sw.reset();
        final play = await adapter
            .probePlayable()
            .timeout(const Duration(seconds: 12));
        buf.write(' 试播${play.startsWith('http') ? '✓' : '✗'}(${sw.elapsedMilliseconds}ms)');
        fullChainSurvivors++;
      } catch (e) {
        buf.write(' ✗ $e');
      }
      // ignore: avoid_print
      print(buf);
    }
    // ignore: avoid_print
    print('=== 结论 === 全链路存活 $fullChainSurvivors/${picked.length}');
  });
}
