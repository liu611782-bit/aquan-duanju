import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/search_orchestrator.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

UnifiedSeries _series(String sourceKey, String title,
        {String year = '2024'}) =>
    UnifiedSeries(
      sourceKey: sourceKey,
      sourceItemId: '$sourceKey-$title',
      title: title,
      normalizedTitle: title,
      year: year,
    );

/// 伪适配器：按脚本发事件。
class _FakeAdapter implements SourceAdapter {
  _FakeAdapter(this.id, this.name, {this.hits = const [], this.fail = false});

  @override
  final String id;
  @override
  final String name;
  final List<UnifiedSeries> hits;
  final bool fail;

  @override
  SourceCaps get caps => const SourceCaps();

  @override
  Future<List<SourceCategory>> categories() async => const [];

  @override
  Future<SourcePage<UnifiedSeries>> list(
          {String? categoryId, required int page}) async =>
      const SourcePage(items: [], page: 1);

  @override
  Stream<SourceSearchEvent> search(String query, {int page = 1, CancelToken? cancel}) async* {
    if (fail) {
      yield const SourceSearchFailed(
          SourceExceptionCode.network, '模拟失败');
      return;
    }
    yield SourceHits(items: hits, page: 1);
    yield const SourceSearchDone();
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async => hits.first;

  @override
  Future<String> probePlayable({String? itemId}) async => '';
}

void main() {
  test('流式事件：每源一批命中；跨源按标题+年份合并分组', () async {
    final orch = SearchOrchestrator();
    final events = <SearchEvent>[];
    await for (final e in orch.search('三体', adapters: [
      _FakeAdapter('a', '源A',
          hits: [_series('a', '三体'), _series('a', '其他剧')]),
      _FakeAdapter('b', '源B', hits: [_series('b', '三体')]),
    ])) {
      events.add(e);
    }

    expect(events.first, isA<SearchStarted>());
    final results = events.whereType<SourceResult>().toList();
    expect(results.length, 2);
    expect(results.every((r) => r.items.isNotEmpty), isTrue);

    final done = events.whereType<SearchDoneEvent>().single;
    expect(done.groupCount, 2, reason: '三体(2源) + 其他剧(1源)');
  });

  test('失败源发 SourceFailedEvent 且不影响其它源', () async {
    final orch = SearchOrchestrator();
    final events = await orch
        .search('三体', adapters: [
          _FakeAdapter('a', '源A', hits: [_series('a', '三体')]),
          _FakeAdapter('bad', '坏源', fail: true),
        ])
        .toList();
    expect(events.whereType<SourceFailedEvent>().single.sourceId, 'bad');
    expect(events.whereType<SourceResult>().single.items.single.title, '三体');
  });

  test('正缓存：第二次搜索直接回放缓存结果', () async {
    final orch = SearchOrchestrator();
    final adapters = [_FakeAdapter('a', '源A', hits: [_series('a', '三体')])];
    await orch.search('三体', adapters: adapters).toList();
    final second = await orch.search('三体', adapters: adapters).toList();
    final result = second.whereType<SourceResult>().single;
    expect(result.items.single.title, '三体');
  });

  test('排序：命中源数多的组在前', () {
    final g1 = SourceGroup()..add(_series('a', '三体'));
    final g2 = SourceGroup()
      ..add(_series('b', '流浪地球'))
      ..add(_series('c', '流浪地球'));
    final sorted = sortGroups([g1, g2]);
    expect(sorted.first.title, '流浪地球');
  });
}
