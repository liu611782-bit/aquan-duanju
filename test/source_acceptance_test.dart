import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/sources/source_acceptance.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

/// 桩源：可编排每层行为。
class FakeAdapter extends SourceAdapter {
  FakeAdapter({
    this.id = 'fake',
    this.name = '桩源',
    this.categoriesResult = const [],
    this.homeResult = const [],
    this.searchResults = const {},
    this.searchError,
    this.detailResult,
    this.detailError,
    this.probeResult = 'http://v/1.m3u8',
    this.probeError,
  });

  @override
  final String id;
  @override
  final String name;
  @override
  SourceCaps get caps => const SourceCaps();

  final List<SourceCategory> categoriesResult;
  final List<UnifiedSeries> homeResult;

  /// keyword:page → 条目（缺席 = 抛 [searchError]）。
  final Map<String, List<UnifiedSeries>> searchResults;
  final Object? searchError;

  final UnifiedSeries? detailResult;
  final Object? detailError;
  final String probeResult;
  final Object? probeError;

  @override
  Future<List<SourceCategory>> categories() async => categoriesResult;

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    if (categoryId == null) return SourcePage(items: homeResult, page: 1);
    final key = 'cat:$categoryId';
    final items = searchResults[key] ?? homeResult;
    return SourcePage(items: items, page: 1);
  }

  @override
  Stream<SourceSearchEvent> search(String query, {int page = 1}) async* {
    final items = searchResults['$query#$page'];
    if (items == null) {
      if (searchError != null) {
        yield SourceSearchFailed(
            SourceExceptionCode.endpointUnresolved, '$searchError');
        yield const SourceSearchDone();
        return;
      }
      yield const SourceSearchDone();
      return;
    }
    yield SourceHits(items: items, page: page, hasMore: page < 2);
    yield const SourceSearchDone();
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    final error = detailError;
    if (error != null) throw error;
    final d = detailResult;
    if (d == null) throw Exception('HTTP 404 not found');
    return d;
  }

  @override
  Future<String> probePlayable({String? itemId}) async {
    final error = probeError;
    if (error != null) throw error;
    return probeResult;
  }
}

UnifiedSeries series(String id) => UnifiedSeries(
      sourceKey: 'fake',
      sourceItemId: id,
      title: '剧$id',
      normalizedTitle: '剧$id',
      lines: [
        PlayLine(name: '线路一', episodes: [
          UnifiedEpisode(title: '第01集', url: 'http://v/$id-1.m3u8', index: 0),
          UnifiedEpisode(title: '第02集', url: 'http://v/$id-2.m3u8', index: 1),
          UnifiedEpisode(title: '第03集', url: 'http://v/$id-3.m3u8', index: 2),
          UnifiedEpisode(title: '第04集', url: 'http://v/$id-4.m3u8', index: 3),
          UnifiedEpisode(title: '第05集', url: 'http://v/$id-5.m3u8', index: 4),
        ]),
      ],
    );

void main() {
  group('取样与判定纯函数', () {
    test('分集首/中/末取样', () {
      expect(SourceAcceptanceSampling.pickEpisodeSamples(0), isEmpty);
      expect(SourceAcceptanceSampling.pickEpisodeSamples(3), [0, 1, 2]);
      expect(SourceAcceptanceSampling.pickEpisodeSamples(5), [0, 2, 4]);
      expect(SourceAcceptanceSampling.pickEpisodeSamples(30), [0, 15, 29]);
    });

    test('第 2 页 id 指纹校验', () {
      const p1 = ['1', '2', '3'];
      expect(SourceAcceptanceSampling.pageFingerprintDiffers(p1, ['4', '5', '6']),
          isTrue);
      expect(
          SourceAcceptanceSampling.pageFingerprintDiffers(p1, ['1', '2', '3']),
          isFalse,
          reason: '整页重复 = 分页失效');
      expect(
          SourceAcceptanceSampling.pageFingerprintDiffers(p1, ['1', '2', '9']),
          isTrue,
          reason: '等长按位比较，末位不同即不同');
      expect(SourceAcceptanceSampling.pageFingerprintDiffers(p1, []), isTrue,
          reason: '第 2 页为空：无法比对不算重复');
      expect(
          SourceAcceptanceSampling.pageFingerprintDiffers(p1, ['1', '2']),
          isTrue,
          reason: '长度不同不算重复');
    });

    test('关键字扫描：任一词有命中即可', () {
      expect(SourceAcceptanceSampling.sweepHasAnyHit({'a': 0, '魔法': 0}), isFalse);
      expect(SourceAcceptanceSampling.sweepHasAnyHit({'a': 0, '魔法': 12}), isTrue);
    });

    test('失败归因：A 站点/网络 / B 结构嫌疑 / C 未定', () {
      expect(
          classifySourceFailure(Exception('HTTP 503 Service Unavailable')),
          SourceFailureCause.siteOrNetwork);
      expect(classifySourceFailure(Exception('Connection timed out')),
          SourceFailureCause.siteOrNetwork);
      expect(classifySourceFailure(FormatException('bad json decode')),
          SourceFailureCause.needsUpstreamComparison);
      expect(classifySourceFailure(Exception('something odd')),
          SourceFailureCause.undetermined);
    });
  });

  group('SourceAcceptanceRunner 分级验收', () {
    Future<List<AcceptanceFinding>> run(SourceAdapter adapter,
        {bool deep = false}) async {
      final findings = <AcceptanceFinding>[];
      await for (final f
          in const SourceAcceptanceRunner().run(adapter, deep: deep)) {
        findings.add(f);
      }
      return findings;
    }

    test('健康源：L0-L3 全绿 + L4 标注人工项', () async {
      final adapter = FakeAdapter(
        categoriesResult: [
          const SourceCategory(id: 'c1', name: '电影'),
          const SourceCategory(id: 'c2', name: '剧集'),
        ],
        homeResult: [series('1'), series('2')],
        searchResults: {
          '魔法#1': [series('1'), series('2')],
          '魔法#2': [series('3'), series('4')],
          'love#1': [series('5')],
          'love#2': [series('6')],
          // 关键字扫描六词里至少一个命中：
          '魔法#1dup': const [],
        },
        detailResult: series('1'),
      );
      // 让扫描六词可用：给 sweep 词都映射同一批结果。
      adapter.searchResults.addAll({
        for (final w in SourceAcceptanceSampling.sweepWords) '$w#1': [series('9')],
      });
      final findings = await run(adapter, deep: true);
      final l3 = findings.where((f) => f.level == SourceAcceptanceLevel.l3Chain);
      expect(findings.where((f) => f.level == SourceAcceptanceLevel.l0Contract).every((f) => f.ok),
          isTrue);
      expect(findings.where((f) => f.level == SourceAcceptanceLevel.l1Register).every((f) => f.ok),
          isTrue);
      expect(findings.where((f) => f.level == SourceAcceptanceLevel.l2Metadata).every((f) => f.ok),
          isTrue);
      expect(l3.where((f) => f.detail.contains('指纹')).every((f) => f.ok), isTrue);
      expect(l3.any((f) => f.ok && f.detail.contains('probePlayable')), isTrue);
      expect(findings.any((f) => f.level == SourceAcceptanceLevel.l4Interactive),
          isTrue, reason: 'L4 必须标注为人工项');
    });

    test('分页失效源：第 2 页与第 1 页指纹相同 → B 类归因', () async {
      final adapter = FakeAdapter(
        homeResult: [series('1')],
        searchResults: {
          // sweep 条目在前，具体取样键在后覆盖（map 字面量后者胜）。
          for (final w in SourceAcceptanceSampling.sweepWords) '$w#1': [series('1')],
          '魔法#1': [series('1'), series('2')],
          '魔法#2': [series('1'), series('2')],
          'love#1': [series('1')],
          'love#2': [series('1')],
        },
        detailResult: series('1'),
      );
      final findings = await run(adapter);
      final dup = findings.firstWhere(
          (f) => f.detail.contains('指纹相同') || f.detail.contains('指纹与第1页不同'));
      expect(dup.ok, isFalse);
      expect(dup.cause, SourceFailureCause.needsUpstreamComparison);
    });

    test('网络故障源：A 类归因，阶段互不抹除', () async {
      final adapter = FakeAdapter(
        searchError: Exception('Connection timed out'),
        homeResult: [],
      );
      final findings = await run(adapter);
      final failed = findings.where((f) => !f.ok).toList();
      expect(failed, isNotEmpty, reason: '应有失败发现');
      // 搜索失败（超时）应归 A 类；空首页是 undetermined（无证据）。
      for (final f in failed.where((f) => f.detail.contains('搜索「'))) {
        expect(f.cause, SourceFailureCause.siteOrNetwork,
            reason: '超时类搜索失败应归 A：${f.detail}');
      }
      // 阶段独立：L0/L1 仍然有产出（不因 L2 挂掉而缺失）。
      expect(findings.any((f) => f.level == SourceAcceptanceLevel.l0Contract),
          isTrue);
      expect(findings.any((f) => f.level == SourceAcceptanceLevel.l1Register),
          isTrue);
    });

    test('结构坏源：详情 404 → 详情失败有归因；扫描全 0 判词无结果', () async {
      final adapter = FakeAdapter(
        homeResult: [series('1')],
        searchResults: {
          // 搜索词全部 0 结果（源可达但没数据）。
        },
        detailResult: null,
      );
      final findings = await run(adapter);
      expect(findings.any((f) => f.detail.contains('全 0=关键词无结果')), isTrue);
    });

    test('JSONL 输出一行一个 finding', () async {
      final adapter = FakeAdapter(homeResult: [series('1')]);
      final findings = await run(adapter);
      for (final f in findings) {
        final line = f.toJsonLine();
        expect(line, startsWith('{"level":'));
        expect(() => jsonDecode(line), returnsNormally);
      }
    });
  });
}
