import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/search_orchestrator.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

UnifiedSeries _s(String sourceKey, String id, String title,
        {String year = '2024'}) =>
    UnifiedSeries(
      sourceKey: sourceKey,
      sourceItemId: id,
      title: title,
      normalizedTitle: title,
      year: year,
    );

/// 按页脚本回放的伪适配器；[gate] 非空时 search 先等门（晚到测试用）。
class _PagedAdapter implements SourceAdapter {
  _PagedAdapter(
    this.id,
    this.name, {
    this.pages = const {},
    this.hasMoreByPage = const {},
    this.gate,
  });

  @override
  final String id;
  @override
  final String name;
  final Map<int, List<UnifiedSeries>> pages;
  final Map<int, bool> hasMoreByPage;
  Completer<void>? gate;

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
    // 只拦续页（page>1）：晚到测试里重开搜索的第 1 页必须能走通。
    if (gate != null && page > 1) await gate!.future;
    yield SourceHits(
      items: pages[page] ?? const [],
      page: page,
      hasMore: hasMoreByPage[page] ?? false,
    );
    yield const SourceSearchDone();
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async =>
      pages.values.expand((e) => e).first;

  @override
  Future<String> probePlayable({String? itemId}) async => '';
}

void main() {
  group('SearchPageLedger', () {
    test('跨页去重：已见条目不再返回', () {
      final ledger = SearchPageLedger();
      final p1 = ledger.accept(1, [_s('a', '1', '剧A'), _s('a', '2', '剧B')]);
      expect(p1.map((s) => s.sourceItemId), ['1', '2']);
      final p2 = ledger.accept(2, [_s('a', '2', '剧B'), _s('a', '3', '剧C')]);
      expect(p2.map((s) => s.sourceItemId), ['3']);
      expect(ledger.lastPage, 2);
      expect(ledger.wantsMore, isTrue);
    });

    test('整页重复 → 游标耗尽；后续 accept 恒空', () {
      final ledger = SearchPageLedger();
      ledger.accept(1, [_s('a', '1', '剧A')]);
      final dup = ledger.accept(2, [_s('a', '1', '剧A')]);
      expect(dup, isEmpty);
      expect(ledger.wantsMore, isFalse, reason: '防死循环翻页');
      expect(ledger.accept(3, [_s('a', '9', '剧X')]), isEmpty,
          reason: '耗尽后不再放行');
    });

    test('空页不算重复页（结尾交给 hasMore）', () {
      final ledger = SearchPageLedger();
      ledger.accept(1, [_s('a', '1', '剧A')]);
      expect(ledger.accept(2, const []), isEmpty);
      expect(ledger.wantsMore, isTrue);
    });

    test('短页不视为结尾', () {
      final ledger = SearchPageLedger();
      ledger.accept(1, [
        _s('a', '1', '剧A'),
        _s('a', '2', '剧B'),
        _s('a', '3', '剧C'),
      ]);
      final short = ledger.accept(2, [_s('a', '4', '剧D')]);
      expect(short, hasLength(1));
      expect(ledger.wantsMore, isTrue);
    });

    test('reset 清空去重与耗尽状态', () {
      final ledger = SearchPageLedger();
      ledger.accept(1, [_s('a', '1', '剧A')]);
      ledger.accept(2, [_s('a', '1', '剧A')]);
      expect(ledger.wantsMore, isFalse);
      ledger.reset();
      expect(ledger.wantsMore, isTrue);
      expect(ledger.lastPage, 0);
      expect(ledger.accept(1, [_s('a', '1', '剧A')]), hasLength(1));
    });
  });

  group('SearchOrchestrator.searchMore', () {
    test('续页只回新增条目；hasMore 透传', () async {
      final orch = SearchOrchestrator();
      final adapter = _PagedAdapter('a', '源A', pages: {
        1: [_s('a', '1', '剧A'), _s('a', '2', '剧B')],
        2: [_s('a', '2', '剧B'), _s('a', '3', '剧C')],
      }, hasMoreByPage: {
        1: true,
        2: true,
      });
      await orch.search('三体', adapters: [adapter]).toList();

      final events = await orch
          .searchMore('三体', adapters: [adapter])
          .toList();
      final results = events.whereType<SourceResult>().toList();
      expect(results, hasLength(1));
      expect(results.single.page, 2);
      expect(results.single.items.map((s) => s.sourceItemId), ['3'],
          reason: '跨页去重后只回新增');
      expect(results.single.hasMore, isTrue);
      expect(events.last, isA<SearchDoneEvent>());
    });

    test('整页重复 → items 空 + hasMore false（该源耗尽）', () async {
      final orch = SearchOrchestrator();
      final adapter = _PagedAdapter('a', '源A', pages: {
        1: [_s('a', '1', '剧A')],
        2: [_s('a', '1', '剧A')],
      }, hasMoreByPage: {
        1: true,
        2: true,
      });
      await orch.search('三体', adapters: [adapter]).toList();

      final events = await orch
          .searchMore('三体', adapters: [adapter])
          .toList();
      final result = events.whereType<SourceResult>().single;
      expect(result.items, isEmpty);
      expect(result.hasMore, isFalse);

      // 耗尽后再续页：没有 pending 源 → 直接结束，不发事件。
      final again =
          await orch.searchMore('三体', adapters: [adapter]).toList();
      expect(again.whereType<SourceResult>(), isEmpty);
    });

    test('短页 + hasMore 继续可翻第三页', () async {
      final orch = SearchOrchestrator();
      final adapter = _PagedAdapter('a', '源A', pages: {
        1: [_s('a', '1', '剧A'), _s('a', '2', '剧B'), _s('a', '3', '剧C')],
        2: [_s('a', '4', '剧D')],
        3: [_s('a', '5', '剧E')],
      }, hasMoreByPage: {
        1: true,
        2: true,
        3: false,
      });
      await orch.search('三体', adapters: [adapter]).toList();

      final page2 =
          await orch.searchMore('三体', adapters: [adapter]).toList();
      expect(page2.whereType<SourceResult>().single.items, hasLength(1));
      expect(page2.whereType<SourceResult>().single.hasMore, isTrue,
          reason: '短页不视为结尾');

      final page3 =
          await orch.searchMore('三体', adapters: [adapter]).toList();
      final r3 = page3.whereType<SourceResult>().single;
      expect(r3.page, 3);
      expect(r3.hasMore, isFalse);
    });

    test('晚到代际：search() 重开后，旧续页流整体丢弃', () async {
      final orch = SearchOrchestrator();
      final gate = Completer<void>();
      final adapter = _PagedAdapter('a', '源A', pages: {
        1: [_s('a', '1', '剧A')],
        2: [_s('a', '2', '剧B')],
      }, hasMoreByPage: {
        1: true,
        2: true,
      }, gate: gate);

      await orch.search('三体', adapters: [adapter]).toList();

      final late = <SearchEvent>[];
      final sub = orch.searchMore('三体', adapters: [adapter]).listen(
            late.add,
          );
      // 等续页 worker 卡在 gate 上，然后重开搜索（代际自增）。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await orch.search('三体', adapters: [adapter]).toList();
      gate.complete();
      await sub.cancel();

      expect(late.whereType<SourceResult>(), isEmpty,
          reason: '重开搜索后，卡在门上的旧续页结果必须按代际丢弃');
    });

    test('新搜索重置账本：耗尽后重搜可再次续页', () async {
      final orch = SearchOrchestrator();
      final adapter = _PagedAdapter('a', '源A', pages: {
        1: [_s('a', '1', '剧A')],
        2: [_s('a', '1', '剧A')],
      }, hasMoreByPage: {
        1: true,
        2: true,
      });

      await orch.search('三体', adapters: [adapter]).toList();
      await orch.searchMore('三体', adapters: [adapter]).toList();

      final before =
          await orch.searchMore('三体', adapters: [adapter]).toList();
      expect(before.whereType<SourceResult>(), isEmpty, reason: '已耗尽');

      // 重开同 query 搜索（正缓存命中走回放路径也要重置+播种账本）。
      await orch.search('三体', adapters: [adapter]).toList();
      final after =
          await orch.searchMore('三体', adapters: [adapter]).toList();
      expect(after.whereType<SourceResult>(), hasLength(1),
          reason: '账本重置后，续页应重新从第 2 页拉起');
    });
  });
}
