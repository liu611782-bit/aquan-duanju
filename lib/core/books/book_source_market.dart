import 'dart:async';
import 'dart:convert';

import '../sources/source_fetch.dart';
import 'book_source_checker.dart';
import 'book_source_model.dart';
import 'book_source_runtime.dart';
import 'book_source_seed.dart';

/// 书源仓库扫描事件（对齐影视 `source_market` 的事件流范式）。
sealed class BookMarketEvent {}

class BookSeedStarted extends BookMarketEvent {
  BookSeedStarted(this.seed);
  final BookSeed seed;
}

/// 种子不可达 / 不是可解析的 legado 书源数组（网页型聚合站即归此类，诚实标注）。
class BookSeedFailed extends BookMarketEvent {
  BookSeedFailed(this.seed, this.error);
  final BookSeed seed;
  final String error;
}

class BookSeedParsed extends BookMarketEvent {
  BookSeedParsed(this.seed, this.sourceCount);
  final BookSeed seed;
  final int sourceCount;
}

/// 单个书源三连校验结果（含 ok/阶段/原因）。
class BookSourceChecked extends BookMarketEvent {
  BookSourceChecked(this.seed, this.check);
  final BookSeed seed;
  final BookSourceCheck check;
}

class BookScanDone extends BookMarketEvent {
  BookScanDone(this.stats);
  final BookMarketStats stats;
}

class BookMarketStats {
  const BookMarketStats(
      {this.seeds = 0, this.sources = 0, this.ok = 0, this.failedSeeds = 0});
  final int seeds;
  final int sources;
  final int ok;
  final int failedSeeds;
}

/// 书源仓库扫描编排：抓种子（镜像回退）→ 解析 legado 数组 → 逐源三连校验（并发）。
///
/// 可达性预检就在这里发生（抓取失败即 `BookSeedFailed`）；稳定判定 = 三连通过且非 js。
/// 与影视 `_Pool` 并发一致：按 concurrency 分批 `Future.wait`，批内完成即产出。
class BookSourceMarket {
  BookSourceMarket({
    this.enforceSsrf = true,
    this.connectTimeout,
    this.readTimeout,
  }) {
    _runtime = BookSourceRuntime(
      enforceSsrf: enforceSsrf,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
    );
    _checker = BookSourceChecker(runtime: _runtime);
  }

  final bool enforceSsrf;
  final Duration? connectTimeout;
  final Duration? readTimeout;
  late final BookSourceRuntime _runtime;
  late final BookSourceChecker _checker;

  Stream<BookMarketEvent> scan({
    required List<BookSeed> seeds,
    required String query,
    bool Function()? cancel,
    int concurrency = 12,
    bool fetchContent = false,
  }) async* {
    var seedsDone = 0, sources = 0, ok = 0, failedSeeds = 0;
    for (final seed in seeds) {
      if (cancel?.call() == true) break;
      yield BookSeedStarted(seed);
      final decoded = await _fetchSeed(seed);
      if (decoded == null) {
        failedSeeds++;
        yield BookSeedFailed(seed, '不可达或不是有效 JSON');
        continue;
      }
      final parsed = BookSource.listFromJson(decoded);
      if (parsed.isEmpty) {
        failedSeeds++;
        yield BookSeedFailed(seed, '无 legado 书源数组（网页型站点请手填导出地址）');
        continue;
      }
      sources += parsed.length;
      seedsDone++;
      yield BookSeedParsed(seed, parsed.length);
      await for (final check
          in _checkAll(parsed, query, cancel, concurrency, fetchContent)) {
        if (check.ok) ok++;
        yield BookSourceChecked(seed, check);
      }
    }
    yield BookScanDone(BookMarketStats(
        seeds: seedsDone, sources: sources, ok: ok, failedSeeds: failedSeeds));
  }

  /// 依次试种子的等价地址，取第一个能连通且可 JSON 解析的。
  Future<Object?> _fetchSeed(BookSeed seed) async {
    for (final url in seed.urls) {
      final result = await fetchProbe(
        url,
        enforceSsrf: enforceSsrf,
        connectTimeout: connectTimeout ?? const Duration(seconds: 8),
        readTimeout: readTimeout ?? const Duration(seconds: 12),
        maxBytes: 8 * 1024 * 1024,
      );
      if (!result.ok || result.bytes == null) continue;
      try {
        return jsonDecode(utf8.decode(result.bytes!, allowMalformed: true));
      } catch (_) {/* 换下一个镜像再试 */}
    }
    return null;
  }

  Stream<BookSourceCheck> _checkAll(
    List<BookSource> sources,
    String query,
    bool Function()? cancel,
    int concurrency,
    bool fetchContent,
  ) async* {
    final width = concurrency < 1 ? 1 : concurrency;
    for (var i = 0; i < sources.length; i += width) {
      if (cancel?.call() == true) return;
      final batch = sources.skip(i).take(width);
      final results = await Future.wait([
        for (final s in batch)
          s.requiresJs
              ? Future.value(BookSourceCheck(
                  source: s,
                  ok: false,
                  stage: BookCheckStage.none,
                  reason: '含脚本规则（js:），暂不支持',
                ))
              : _checker.check(s, query, fetchContent: fetchContent),
      ]);
      for (final r in results) {
        yield r;
      }
    }
  }
}
