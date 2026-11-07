import 'dart:async';

import 'source_adapter.dart';

/// 聚合搜索编排：并发池 + 单源超时 + 总预算 + 流式事件 + 去重分组。
///
/// 参数默认值（设置可覆盖）：并发 4、单源 5s、总预算 12s；
/// 正缓存 5min（sourceId+query+page）、负缓存 90s。
sealed class SearchEvent {
  const SearchEvent();
}

class SearchStarted extends SearchEvent {
  const SearchStarted(this.totalSources);
  final int totalSources;
}

/// 单源一批命中（UI 立即并入分组）。
class SourceResult extends SearchEvent {
  const SourceResult({
    required this.sourceId,
    required this.sourceName,
    required this.items,
    required this.page,
    this.hasMore = false,
    this.notice = '',
  });
  final String sourceId;
  final String sourceName;
  final List<UnifiedSeries> items;
  final int page;
  final bool hasMore;

  /// 源备注（来自 [SourceHits.notice]，如「已按 X 检索」）；空串即无。
  final String notice;
}

/// 单源失败（显角标，计入健康；不影响其它源）。
class SourceFailedEvent extends SearchEvent {
  const SourceFailedEvent(this.sourceId, this.sourceName, this.code, this.detail);
  final String sourceId;
  final String sourceName;
  final SourceExceptionCode code;
  final String detail;
}

class SearchDoneEvent extends SearchEvent {
  const SearchDoneEvent(this.groupCount, this.tookMs);
  final int groupCount;
  final int tookMs;
}

/// 跨源去重后的一组结果：同一部剧在 N 个源的命中。
class SourceGroup {
  final List<UnifiedSeries> _hits = [];

  UnifiedSeries get primary => _hits.first;
  List<UnifiedSeries> get hits => List.unmodifiable(_hits);
  /// 命中该剧的**不同源**数量：同一个源返回多条命中只算一个。
  int get sourceCount => _hits.map((h) => h.sourceKey).toSet().length;
  String get title => primary.title;
  String get coverUrl => primary.coverUrl;
  String get remarks => primary.remarks;

  bool get exactMatch => _hits.any((h) => h.normalizedTitle == h.title.trim());

  void add(UnifiedSeries series) => _hits.add(series);

  /// 组内排序（钉选 > 健康分等由调用方注入排名函数）。
  void sortBy(int Function(UnifiedSeries a, UnifiedSeries b) compare) {
    _hits.sort(compare);
  }
}

/// 编排器（无状态实例可复用；缓存挂在实例上）。
class SearchOrchestrator {
  SearchOrchestrator({this.positiveTtl = const Duration(minutes: 5)});

  final Duration positiveTtl;

  final Map<String, _CacheEntry> _cache = {};
  final Map<String, DateTime> _negativeCache = {};
  int _seq = 0;

  /// 聚合续页账本：query → sourceId → ledger。search() 重开时重置并播种第 1 页。
  final Map<String, Map<String, SearchPageLedger>> _pagingLedgers = {};

  /// 续页代际：search() 重开或新的 searchMore() 都会自增，
  /// 晚到的续页事件按代际丢弃（VenHM SearchSession 语义）。
  int _pagingGen = 0;

  static const negativeTtl = Duration(seconds: 90);
  static const totalBudget = Duration(seconds: 12);

  /// 流式聚合搜索：[adapters] 是参与搜索的源（含红果桥接）。
  ///
  /// 新搜索替换旧搜索（单调 [SearchOrchestrator._seq] + CancelToken）。
  Stream<SearchEvent> search(
    String query, {
    required List<SourceAdapter> adapters,
    int parallelism = 4,
    Duration perSourceTimeout = const Duration(seconds: 5),
    CancelToken? cancel,
  }) async* {
    final seq = ++_seq;
    final internal = CancelToken();
    cancel?.whenCancelled(internal.cancel);
    final started = DateTime.now();
    final q = query.trim();
    if (q.isEmpty || adapters.isEmpty) {
      yield SearchDoneEvent(0, 0);
      return;
    }
    // 新搜索重置换页状态：账本清空（第 1 页下面重新播种）、续页代际自增
    // （正在跑的 searchMore 流整体作废）。
    _pagingGen++;
    final ledgers = _pagingLedgers.putIfAbsent(q, () => {});
    ledgers.clear();
    yield SearchStarted(adapters.length);

    String cacheKey(String sourceId) => '$sourceId|$q|1';
    final fresh = <SourceAdapter>[];
    for (final a in adapters) {
      final hit = _cache[cacheKey(a.id)];
      final negativeAt = _negativeCache[cacheKey(a.id)];
      if (negativeAt != null &&
          DateTime.now().difference(negativeAt) < negativeTtl) {
        yield SourceFailedEvent(a.id, a.name, SourceExceptionCode.searchTimeout,
            '负缓存命中');
        continue;
      }
      if (hit != null && DateTime.now().difference(hit.at) < positiveTtl) {
        // 播种续页账本：第 1 页条目参与后续页去重。
        ledgers.putIfAbsent(a.id, SearchPageLedger.new).accept(1, hit.items);
        yield SourceResult(
            sourceId: a.id,
            sourceName: a.name,
            items: hit.items,
            page: 1,
            hasMore: hit.hasMore,
            notice: hit.notice);
        continue;
      }
      fresh.add(a);
    }

    final groups = <SourceGroup>[];
    if (fresh.isEmpty) {
      // 全部命中缓存：直接补一个 Done（结果已在上面回放）。
      yield SearchDoneEvent(
          groups.length, DateTime.now().difference(started).inMilliseconds);
      return;
    }

    final collect = StreamController<SearchEvent>();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (internal.isCancelled) return;
        final i = next++;
        if (i >= fresh.length) return;
        final adapter = fresh[i];
        try {
          final events = await adapter
              .search(q, cancel: internal)
              .timeout(perSourceTimeout)
              .toList();
          if (internal.isCancelled || seq != _seq) return;
          final hits = <UnifiedSeries>[];
          var failed = false;
          SourceExceptionCode failCode = SourceExceptionCode.network;
          var failDetail = '';
          var hasMore = false;
          var notice = '';
          for (final e in events) {
            if (e is SourceHits) {
              hits.addAll(e.items);
              hasMore = hasMore || e.hasMore;
              if (e.notice.isNotEmpty) notice = e.notice;
            } else if (e is SourceSearchFailed) {
              failed = true;
              failCode = e.code;
              failDetail = e.detail;
            }
          }
          if (hits.isEmpty && failed) {
            _negativeCache[cacheKey(adapter.id)] = DateTime.now();
            collect.add(SourceFailedEvent(
                adapter.id, adapter.name, failCode, failDetail));
          } else if (hits.isEmpty) {
            // 空结果不进正缓存也不进负缓存（下一页/下一次再试）。
            collect.add(SourceResult(
                sourceId: adapter.id,
                sourceName: adapter.name,
                items: const [],
                page: 1));
          } else {
            ledgers
                .putIfAbsent(adapter.id, SearchPageLedger.new)
                .accept(1, hits);
            _cache[cacheKey(adapter.id)] = _CacheEntry(
                items: hits, at: DateTime.now(), hasMore: hasMore, notice: notice);
            collect.add(SourceResult(
                sourceId: adapter.id,
                sourceName: adapter.name,
                items: hits,
                page: 1,
                hasMore: hasMore,
                notice: notice));
          }
        } on TimeoutException {
          if (internal.isCancelled || seq != _seq) return;
          _negativeCache[cacheKey(adapter.id)] = DateTime.now();
          collect.add(SourceFailedEvent(adapter.id, adapter.name,
              SourceExceptionCode.searchTimeout, '单源超时 ${perSourceTimeout.inMilliseconds}ms'));
        } on SourceException catch (e) {
          if (internal.isCancelled || seq != _seq) return;
          _negativeCache[cacheKey(adapter.id)] = DateTime.now();
          collect.add(
              SourceFailedEvent(adapter.id, adapter.name, e.code, e.detail));
        } catch (e) {
          if (internal.isCancelled || seq != _seq) return;
          collect.add(SourceFailedEvent(adapter.id, adapter.name,
              SourceExceptionCode.network, e.toString()));
        }
      }
    }

    final workers = <Future<void>>[];
    final workerCount = parallelism.clamp(1, fresh.length);
    for (var i = 0; i < workerCount; i++) {
      workers.add(worker());
    }

    // 总预算：到点取消未完成源（MoonTVPlus/CineFlow 同策略）。
    final budget = Timer(totalBudget, internal.cancel);
    unawaited(Future.wait(workers).whenComplete(() {
      if (!collect.isClosed) collect.close();
    }));

    await for (final event in collect.stream) {
      if (seq != _seq) break; // 已被新搜索替换。
      if (event is SourceResult && event.items.isNotEmpty) {
        for (final series in event.items) {
          _addToGroup(groups, series);
        }
      }
      yield event;
    }
    budget.cancel();
    if (seq != _seq) return;
    _pruneCache();
    yield SearchDoneEvent(groups.length, DateTime.now().difference(started).inMilliseconds);
  }

  /// 聚合搜索续页：对 [query] 已有第 1 页账本的源继续拉下一页。
  ///
  /// 语义（VenHM SearchSession）：
  /// - 跨页按 `sourceKey:sourceItemId` 去重，只回新增条目；
  /// - 某页返回条目**全部**重复 → 该源游标耗尽（结果 hasMore=false，防死循环翻页）；
  /// - 晚到保护：期间发生新的 search()/searchMore()，旧流整体按代际丢弃；
  /// - 短页不视为结尾（是否继续由上游 hasMore 与账本共同决定）。
  /// - 续页失败不发负缓存（不应毒化第 1 页正缓存），调用方可重试。
  ///
  /// [SearchDoneEvent.groupCount] 恒为 0：分组合并由调用方负责。
  Stream<SearchEvent> searchMore(
    String query, {
    required List<SourceAdapter> adapters,
    int parallelism = 4,
    Duration perSourceTimeout = const Duration(seconds: 5),
    CancelToken? cancel,
  }) async* {
    final q = query.trim();
    if (q.isEmpty || adapters.isEmpty) return;
    final gen = ++_pagingGen;
    final ledgers = _pagingLedgers.putIfAbsent(q, () => {});
    final pending = <(SourceAdapter, SearchPageLedger)>[];
    for (final a in adapters) {
      final ledger = ledgers[a.id];
      if (ledger == null || !ledger.wantsMore) continue;
      pending.add((a, ledger));
    }
    if (pending.isEmpty) return;
    yield SearchStarted(pending.length);

    final internal = CancelToken();
    cancel?.whenCancelled(internal.cancel);

    final collect = StreamController<SearchEvent>();
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (internal.isCancelled || gen != _pagingGen) return;
        final i = next++;
        if (i >= pending.length) return;
        final (adapter, ledger) = pending[i];
        final page = ledger.lastPage + 1;
        try {
          final events = await adapter
              .search(q, page: page, cancel: internal)
              .timeout(perSourceTimeout)
              .toList();
          if (internal.isCancelled || gen != _pagingGen) return;
          final hits = <UnifiedSeries>[];
          var failed = false;
          SourceExceptionCode failCode = SourceExceptionCode.network;
          var failDetail = '';
          var rawHasMore = false;
          for (final e in events) {
            if (e is SourceHits) {
              hits.addAll(e.items);
              rawHasMore = rawHasMore || e.hasMore;
            } else if (e is SourceSearchFailed) {
              failed = true;
              failCode = e.code;
              failDetail = e.detail;
            }
          }
          if (hits.isEmpty && failed) {
            collect.add(SourceFailedEvent(
                adapter.id, adapter.name, failCode, failDetail));
          } else {
            final fresh = ledger.accept(page, hits);
            collect.add(SourceResult(
              sourceId: adapter.id,
              sourceName: adapter.name,
              items: fresh,
              page: page,
              hasMore: rawHasMore && ledger.wantsMore,
            ));
          }
        } on TimeoutException {
          if (internal.isCancelled || gen != _pagingGen) return;
          collect.add(SourceFailedEvent(adapter.id, adapter.name,
              SourceExceptionCode.searchTimeout,
              '单源超时 ${perSourceTimeout.inMilliseconds}ms'));
        } on SourceException catch (e) {
          if (internal.isCancelled || gen != _pagingGen) return;
          collect.add(
              SourceFailedEvent(adapter.id, adapter.name, e.code, e.detail));
        } catch (e) {
          if (internal.isCancelled || gen != _pagingGen) return;
          collect.add(SourceFailedEvent(adapter.id, adapter.name,
              SourceExceptionCode.network, e.toString()));
        }
      }
    }

    final workers = <Future<void>>[];
    final workerCount = parallelism.clamp(1, pending.length);
    for (var i = 0; i < workerCount; i++) {
      workers.add(worker());
    }
    unawaited(Future.wait(workers).whenComplete(() {
      if (!collect.isClosed) collect.close();
    }));

    await for (final event in collect.stream) {
      if (gen != _pagingGen) break;
      yield event;
    }
    if (gen != _pagingGen) return;
    yield const SearchDoneEvent(0, 0);
  }

  /// 归一化标题 + 年份去重合并（tvbox mergeMovies 同键）。
  void _addToGroup(List<SourceGroup> groups, UnifiedSeries series) {
    final key = '${series.normalizedTitle}@${series.year}';
    for (final g in groups) {
      final primaryKey =
          '${g.primary.normalizedTitle}@${g.primary.year}';
      if (primaryKey == key) {
        g.add(series);
        return;
      }
    }
    final group = SourceGroup()..add(series);
    groups.add(group);
  }

  void _pruneCache() {
    final now = DateTime.now();
    _cache.removeWhere((_, e) => now.difference(e.at) > positiveTtl * 4);
    _negativeCache
        .removeWhere((_, at) => now.difference(at) > negativeTtl * 4);
  }

  /// 清空缓存（源管理页「清缓存」）。
  void clearCache() {
    _cache.clear();
    _negativeCache.clear();
  }
}

class _CacheEntry {
  const _CacheEntry({
    required this.items,
    required this.at,
    required this.hasMore,
    this.notice = '',
  });
  final List<UnifiedSeries> items;
  final DateTime at;
  final bool hasMore;

  /// 源备注（退化重试等），随正缓存一起回放。
  final String notice;
}

/// 单源分页账本（聚合续页 / 单源浏览共用）：跨页去重 + 重复页终止。
///
/// VenHM SearchSession 语义：已见条目（`sourceKey:sourceItemId`）不再返回；
/// 某页返回条目**全部**与已见集合重复 → 游标耗尽（[wantsMore] 置 false，
/// 防部分站点永远重复同一页）；空页不算重复页（结尾交给 hasMore）；
/// 短页**不**视为结尾。
class SearchPageLedger {
  final Set<String> _seen = <String>{};

  /// 最后接受的页码（searchMore 以此 +1 续拉）。
  int lastPage = 0;

  bool _exhausted = false;

  /// 是否还需要继续翻页。
  bool get wantsMore => !_exhausted;

  /// 清空账本（重开浏览/换分类/新搜索时）。
  void reset() {
    _seen.clear();
    lastPage = 0;
    _exhausted = false;
  }

  /// 收下一页：返回新增条目；整页重复时置耗尽并返回空表。
  List<UnifiedSeries> accept(int page, List<UnifiedSeries> items) {
    lastPage = page;
    if (_exhausted) return const [];
    final fresh = <UnifiedSeries>[];
    for (final s in items) {
      if (_seen.add('${s.sourceKey}:${s.sourceItemId}')) fresh.add(s);
    }
    if (items.isNotEmpty && fresh.isEmpty) _exhausted = true;
    return fresh;
  }
}

/// 组排序：命中源数 ↓ > 精确匹配 > 保持流式到达序（CineFlow mergeHits 同策略）。
List<SourceGroup> sortGroups(List<SourceGroup> groups) {
  final list = List.of(groups);
  list.sort((a, b) {
    if (a.sourceCount != b.sourceCount) return b.sourceCount.compareTo(a.sourceCount);
    if (a.exactMatch != b.exactMatch) return a.exactMatch ? -1 : 1;
    return 0;
  });
  return list;
}
