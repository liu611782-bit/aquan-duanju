import 'dart:async';
import 'dart:math';

import 'package:meta/meta.dart';

import 'config_decoder.dart';
import 'market_classify.dart';
import 'source_adapter.dart';
import 'source_fetch.dart';
import 'source_import.dart';
import 'source_probe.dart';
import 'source_seed.dart';

/// 极简 worker 池：限制同时运行的异步任务数（IO 密集即可真并发，
/// 不需要 Isolate）。任务完成按等待序放行下一个。
class _Pool {
  _Pool(this.size);

  final int size;
  var _active = 0;
  final _waiters = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() task) async {
    if (_active >= size) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
    }
    _active++;
    try {
      return await task();
    } finally {
      _active--;
      if (_waiters.isNotEmpty) _waiters.removeAt(0).complete();
    }
  }
}

/// 扫描事件。
sealed class MarketScanEvent {
  const MarketScanEvent();
}

/// JS 渲染页的失败原因标记（UI 据此显示专门文案）。
const String kJsRendered = 'JS_RENDERED';

/// 兼容旧界面：索引站开始抓取。
class MarketSiteStarted extends MarketScanEvent {
  const MarketSiteStarted(this.site);

  final MarketSite site;
}

/// 兼容旧界面：索引站完成。
class MarketSiteDone extends MarketScanEvent {
  const MarketSiteDone({
    required this.site,
    this.configCount = 0,
    this.candidateCount = 0,
    this.error = '',
  });

  final MarketSite site;
  final int configCount;
  final int candidateCount;
  final String error;

  bool get jsRendered => error == kJsRendered;
}

/// 兼容旧界面：单条结果进度。
class MarketProbeProgress extends MarketScanEvent {
  const MarketProbeProgress(
    this.candidate,
    this.outcome,
    this.done,
    this.total,
  );

  final SourceCandidate candidate;
  final ProbeOutcome outcome;
  final int done;
  final int total;
}

/// 单个种子开始。
class MarketSeedStarted extends MarketScanEvent {
  const MarketSeedStarted(this.seed);

  final SourceSeed seed;
}

/// 单个种子结束。
class MarketSeedDone extends MarketScanEvent {
  const MarketSeedDone({
    required this.seed,
    this.nodeCount = 0,
    this.error = '',
  });

  final SourceSeed seed;
  final int nodeCount;
  final String error;
}

/// 一个节点抓取并解析完成（可流式显示）。
class MarketNodeScanned extends MarketScanEvent {
  const MarketNodeScanned(this.node, this.done, this.total);

  final MarketNode node;
  final int done;
  final int total;
}

/// 扫描完成。
class MarketScanDone extends MarketScanEvent {
  const MarketScanDone(
    this.results, {
    this.parses = const <ParseApi>[],
    this.lives = const <LiveConfig>[],
    this.nodes = const <MarketNode>[],
    this.stats = const MarketStats.empty(),
  });

  /// 兼容旧 UI：扁平候选 + 测速结论。
  final List<MarketCandidateResult> results;
  final List<ParseApi> parses;
  final List<LiveConfig> lives;

  /// 新增：多仓树。
  final List<MarketNode> nodes;
  final MarketStats stats;
}

/// 扫描统计。
class MarketStats {
  const MarketStats({
    required this.seeds,
    required this.scannedSeeds,
    required this.nodes,
    required this.available,
    required this.singles,
    required this.multis,
    required this.avgLatencyMs,
  });

  const MarketStats.empty()
      : seeds = 0,
        scannedSeeds = 0,
        nodes = 0,
        available = 0,
        singles = 0,
        multis = 0,
        avgLatencyMs = 0;

  final int seeds;
  final int scannedSeeds;
  final int nodes;
  final int available;
  final int singles;
  final int multis;
  final int avgLatencyMs;
}

/// 一个扫描节点（多仓会有 children）。
class MarketNode {
  MarketNode({
    required this.id,
    required this.name,
    required this.url,
    this.kind = SeedKind.line,
    this.shape = RepoShape.unknown,
    this.available = false,
    this.ttfbMs,
    this.totalMs,
    this.sizeKb,
    this.speedKbps,
    this.siteCount = 0,
    this.format = PayloadFormat.unknown,
    this.flags = const <SecurityFlag>{},
    this.error = '',
    this.depth = 0,
    this.samples = 1,
    List<MarketNode>? children,
    List<SourceCandidate>? candidates,
  })  : children = children ?? <MarketNode>[],
        candidates = candidates ?? <SourceCandidate>[];

  final String id;

  /// 名称可能来自配置自身（`name` 字段），因此不是 final。
  String name;
  final String url;
  final SeedKind kind;

  RepoShape shape;
  bool available;
  int? ttfbMs;
  int? totalMs;
  double? sizeKb;
  double? speedKbps;
  int siteCount;
  PayloadFormat format;
  Set<SecurityFlag> flags;
  String error;
  final int depth;
  int samples;

  final List<MarketNode> children;
  final List<SourceCandidate> candidates;

  bool get isMulti => shape.isMulti;

  /// 多仓的可用性由子仓聚合：任一子可用即可用。
  bool get aggregatedAvailable =>
      available || children.any((c) => c.aggregatedAvailable);

  int? get bestLatencyMs {
    final values = <int>[
      if (ttfbMs != null && available) ttfbMs!,
      for (final child in children)
        if (child.bestLatencyMs != null) child.bestLatencyMs!,
    ];
    if (values.isEmpty) return null;
    return values.reduce((a, b) => a < b ? a : b);
  }

  /// 展开出所有「可用单仓叶子」。
  List<MarketNode> leaves({bool onlyAvailable = true}) {
    final out = <MarketNode>[];
    void walk(MarketNode node) {
      if (node.isMulti) {
        for (final child in node.children) {
          walk(child);
        }
        return;
      }
      if (!onlyAvailable || node.available) out.add(node);
    }

    walk(this);
    return out;
  }
}

/// 一条测速完成的候选源（兼容旧界面）。
class MarketCandidateResult implements Comparable<MarketCandidateResult> {
  const MarketCandidateResult({
    required this.candidate,
    required this.outcome,
  });

  final SourceCandidate candidate;
  final ProbeOutcome outcome;

  bool get isOk => outcome.isOk;
  int? get latencyMs => outcome.latencyMs;

  @override
  int compareTo(MarketCandidateResult other) {
    int rank(ProbeState s) =>
        s == ProbeState.ok ? 0 : s == ProbeState.timeout ? 1 : 2;
    final byRank = rank(outcome.state).compareTo(rank(other.outcome.state));
    if (byRank != 0) return byRank;
    return (latencyMs ?? 1 << 30).compareTo(other.latencyMs ?? 1 << 30);
  }
}

/// 扫描器。
class MarketScanner {
  /// 每个种子/页面最多提取的配置地址数。
  static const int maxConfigUrlsPerSite = 60;

  /// 一次扫描最多保留的节点数（防爆炸）。
  static const int maxNodes = 400;

  static const int maxDepth = 3;

  static final RegExp _urlPattern = RegExp(r'''https?://[^\s"'<>()\[\]{}\\]+''');

  /// 只过滤真正的静态资源；`.txt` / `.json` 是多仓配置的常见载体，必须保留。
  static final RegExp _junkExtension = RegExp(
    r'\.(css|js|png|jpe?g|gif|webp|svg|ico|woff2?|ttf|otf|apk|mp4|m3u8|html?|htm)(\?|#|$)',
    caseSensitive: false,
  );

  static final RegExp _lineKeyword = RegExp(
    r'(/tv$|/tv/|\.json|\.txt|kstore|catvod|仓库|线路|/raw/)',
    caseSensitive: false,
  );

  final Map<String, Future<FetchResult>> _inFlight =
      <String, Future<FetchResult>>{};

  /// 主流杀软报毒（Trojan/JS.Redirector 类）的地址：扫描过程中不去请求，
  /// 避免用户杀软弹窗拦截应用流量。聚合页里提取到这类地址直接丢弃。
  static const _blockedHosts = <String>{
    'js.134584.xyz', // pp87.json，Trojan/JS.Redirector.bx
  };

  static bool _isBlockedUrl(String url) {
    // 全文包含而非仅 host 段：聚合页常见「代理前缀包裹」形态
    // （https://g.xxx/https://js.134584.xyz/json/pp87.json），host 是代理域
    // 但最终仍会请求报毒地址——杀软照样拦截用户流量。
    final lower = url.toLowerCase();
    for (final host in _blockedHosts) {
      if (lower.contains(host)) return true;
    }
    return false;
  }

  /// 扫描种子清单。
  Stream<MarketScanEvent> scanSeeds(
    List<SourceSeed> seeds, {
    CancelToken? cancel,
    int samples = 1,
    Duration connectTimeout = const Duration(milliseconds: 4500),
    Duration readTimeout = const Duration(milliseconds: 5500),
    int maxBytes = kMaxProbeBytes,
    int concurrency = 12,
  }) {
    final controller = StreamController<MarketScanEvent>();
    unawaited(_run(
      controller,
      seeds,
      cancel,
      samples,
      connectTimeout,
      readTimeout,
      maxBytes,
      concurrency,
    ));
    return controller.stream;
  }

  /// 兼容旧入口：把索引站当成种子扫一遍，并把新事件映射回旧事件。
  Stream<MarketScanEvent> scan(
    List<MarketSite> sites, {
    CancelToken? cancel,
    Duration fetchTimeout = const Duration(seconds: 10),
  }) {
    final byId = <String, MarketSite>{for (final site in sites) site.id: site};
    MarketSite siteOf(SourceSeed seed) =>
        byId[seed.id] ??
        MarketSite(id: seed.id, name: seed.name, url: seed.url);
    return scanSeeds(
      <SourceSeed>[
        for (final site in sites)
          SourceSeed(
            id: site.id,
            name: site.name,
            url: site.url,
            kind: SeedKind.list,
            builtin: site.builtin,
          ),
      ],
      cancel: cancel,
      readTimeout: fetchTimeout,
    ).asyncMap((event) {
      if (event is MarketSeedStarted) {
        return MarketSiteStarted(siteOf(event.seed));
      }
      if (event is MarketSeedDone) {
        return MarketSiteDone(
          site: siteOf(event.seed),
          configCount: event.nodeCount,
          candidateCount: event.nodeCount,
          error: event.error,
        );
      }
      if (event is MarketNodeScanned) {
        final node = event.node;
        final outcome = ProbeOutcome(
          sourceId: node.url,
          state: node.available ? ProbeState.ok : ProbeState.failed,
          ttfbMs: node.ttfbMs,
          totalMs: node.totalMs,
          sizeKb: node.sizeKb,
          speedKbps: node.speedKbps,
          siteCount: node.siteCount,
          format: node.format,
          flags: node.flags,
          samples: node.samples,
          reason: node.error,
        );
        final candidate = SourceCandidate(
          name: node.name.isEmpty ? node.url : node.name,
          api: node.url,
        );
        return MarketProbeProgress(
          candidate,
          outcome,
          event.done,
          event.total,
        );
      }
      return event;
    });
  }

  Future<void> _run(
    StreamController<MarketScanEvent> controller,
    List<SourceSeed> seeds,
    CancelToken? cancel,
    int samples,
    Duration connectTimeout,
    Duration readTimeout,
    int maxBytes,
    int concurrency,
  ) async {
    final roots = <MarketNode>[];
    final parses = <ParseApi>[];
    final lives = <LiveConfig>[];
    final seenUrls = <String>{};
    final seenParseUrls = <String>{};
    final seenLiveUrls = <String>{};
    var idSeq = 0;

    Future<FetchResult> fetch(String url) {
      // 唯一网络入口：报毒地址（含代理前缀包裹形态）在此彻底封堵。
      // 之前只在提取/种子两处过滤，漏了多仓嵌套子配置（info.children）。
      if (_isBlockedUrl(url)) {
        return Future.value(FetchResult(
            ok: false, error: '该地址被主流杀软报毒，已跳过'));
      }
      final key = normalizeSeedUrl(url);
      return _inFlight.putIfAbsent(key, () {
        final future = fetchProbe(
          url,
          connectTimeout: connectTimeout,
          readTimeout: readTimeout,
          maxBytes: maxBytes,
          cancel: cancel,
        );
        // 这里只合并「同一轮并发抓取」：请求结束即移出 memo。
        // 否则同一会话内重扫会永远复用第一次的结果（连失败都被缓存），
        // 多点采样也退化成只打一次网络。
        unawaited(future.then<void>(
          (_) => _inFlight.remove(key),
          onError: (Object _) => _inFlight.remove(key),
        ));
        return future;
      });
    }

    Future<MarketNode> scanNode(
      String name,
      String url,
      int depth,
      SeedKind kind,
    ) async {
      final node = MarketNode(
        id: 'node_${++idSeq}',
        name: name,
        url: url,
        kind: kind,
        depth: depth,
      );
      final samplesToRun = samples.clamp(1, 3);
      final ttfbList = <int>[];
      final totalList = <int>[];
      FetchResult? last;
      for (var i = 0; i < samplesToRun; i++) {
        last = await fetch(url);
        if (!last.ok) break;
        ttfbList.add(last.ttfbMs);
        totalList.add(last.totalMs);
      }
      final result = last;
      if (result == null || !result.ok) {
        node
          ..available = false
          ..error = result?.error ?? '抓取失败'
          ..ttfbMs = result?.ttfbMs
          ..totalMs = result?.totalMs
          ..flags = <SecurityFlag>{
            if (result != null && !result.isHttps) SecurityFlag.cleartextHttp,
          };
        return node;
      }

      node
        ..ttfbMs = _median(ttfbList)
        ..totalMs = _median(totalList)
        ..sizeKb = result.sizeKb
        ..speedKbps = result.speedKbps
        ..samples = ttfbList.length
        ..flags = <SecurityFlag>{
          if (result.isHttps) SecurityFlag.httpsSafe else SecurityFlag.cleartextHttp,
        };

      final raw = result.text;
      node.format = detectPayloadFormat(raw);

      Map<String, dynamic>? config;
      try {
        config = ConfigDecoder.decode(raw);
      } on SourceException catch (e) {
        node
          ..available = false
          ..error = e.detail.isEmpty ? '载荷无法解码' : '载荷无法解码：${e.detail}';
        return node;
      } catch (_) {
        node
          ..available = false
          ..error = '载荷无法解码';
        return node;
      }

      final info = classifyConfig(config);
      if (info == null || !info.known) {
        node
          ..available = false
          ..error = '无法识别的配置结构';
        return node;
      }
      node
        ..shape = info.shape
        ..siteCount = info.siteCount
        ..name = name.isNotEmpty ? name : info.name;
      if (info.cleartextSpiderJar) {
        node.flags = <SecurityFlag>{...node.flags, SecurityFlag.cleartextSpiderJar};
      }

      if (info.shape.isMulti) {
        if (depth >= maxDepth) {
          node
            ..available = false
            ..error = '多仓嵌套超过 $maxDepth 层';
          return node;
        }
        for (final child in info.children.take(maxConfigUrlsPerSite)) {
          if (cancel?.isCancelled ?? false) break;
          if (roots.length + idSeq > maxNodes) break;
          final childNode =
              await scanNode(child.name, child.url, depth + 1, SeedKind.line);
          node.children.add(childNode);
        }
        node.available = node.children.any((c) => c.aggregatedAvailable);
        if (!node.available && node.error.isEmpty) {
          node.error = '所有子仓均不可用';
        }
        return node;
      }

      // 单仓：提取候选源 + 解析接口 + 直播清单。
      final extracted = SourceImporter.extractSites(config, sourceUrl: url);
      node.candidates.addAll(extracted);
      for (final p in SourceImporter.extractParses(config)) {
        if (seenParseUrls.add(p.url)) parses.add(p);
      }
      for (final l in extractLives(config, sourceUrl: url)) {
        if (seenLiveUrls.add(l.url)) lives.add(l);
      }
      node.available = extracted.isNotEmpty;
      if (!node.available) node.error = '配置里没有可用站点';
      return node;
    }

    // 种子级并发（IO 密集，事件循环内 await 即可真并发）：顺序扫 60+ 种子
    // 一次要十几分钟，池宽 12 缩到一分多钟。节点事件按完成序推送。
    final seedList = seeds;
    var seedsDone = 0;
    Future<void> runSeed(SourceSeed seed) async {
      controller.add(MarketSeedStarted(seed));
      var nodeCount = 0;
      String error = '';
      try {
        if (_isBlockedUrl(seed.url)) {
          error = '该地址被主流杀软报毒，已跳过';
        } else if (seed.kind == SeedKind.line) {
          if (seenUrls.add(normalizeSeedUrl(seed.url))) {
            final node = await scanNode(seed.name, seed.url, 0, seed.kind);
            roots.add(node);
            nodeCount = 1;
            controller.add(MarketNodeScanned(
              node,
              seedsDone,
              seedList.length,
            ));
          }
        } else {
          final page = await fetch(seed.url);
          if (!page.ok) {
            error = page.error;
          } else {
            final urls = extractConfigUrls(page.text);
            if (urls.isEmpty) {
              error = page.text.contains('<script')
                  ? kJsRendered
                  : '页面里没有配置地址';
            }
            // 种子内的配置地址也并发，但宽度收敛为总并发的一部分，
            // 避免一个大聚合页把整条扫描带宽吃光。
            final nodePool = _Pool(max(1, concurrency ~/ 3));
            final tasks = <Future<void>>[];
            for (final url in urls) {
              if (cancel?.isCancelled ?? false) break;
              if (!seenUrls.add(normalizeSeedUrl(url))) continue;
              if (roots.length > maxNodes) break;
              tasks.add(nodePool.run(() async {
                final node = await scanNode('', url, 0, SeedKind.line);
                roots.add(node);
                nodeCount++;
                controller.add(MarketNodeScanned(
                  node,
                  seedsDone,
                  seedList.length,
                ));
              }));
            }
            await Future.wait(tasks);
          }
        }
      } catch (e) {
        error = friendlyFetchError(e);
      }
      seedsDone++;
      controller.add(MarketSeedDone(
        seed: seed,
        nodeCount: nodeCount,
        error: error,
      ));
    }

    final seedPool = _Pool(max(1, concurrency));
    await Future.wait([
      for (final seed in seedList) seedPool.run(() => runSeed(seed)),
    ]);

    // 取消不再清空结果：已扫到的节点照常汇总，勾选导入照常可用
    // （「停止后扫到的信息全没了」就是这条提前返回干的）。

    roots.sort(_compareNodes);

    final flat = <MarketNode>[];
    for (final root in roots) {
      flat.addAll(root.leaves(onlyAvailable: false));
    }
    final results = <MarketCandidateResult>[];
    final seenApi = <String>{};
    for (final node in flat) {
      if (!node.available) continue;
      final outcome = ProbeOutcome(
        sourceId: node.url,
        state: ProbeState.ok,
        ttfbMs: node.ttfbMs,
        totalMs: node.totalMs,
        sizeKb: node.sizeKb,
        speedKbps: node.speedKbps,
        siteCount: node.siteCount,
        format: node.format,
        flags: node.flags,
        samples: node.samples,
      );
      for (final candidate in node.candidates) {
        // 多份配置常常互相包含同一批站点，按 kind+api 去重。
        final key = '${candidate.kind.name}|${candidate.api}';
        if (!seenApi.add(key)) continue;
        results.add(MarketCandidateResult(candidate: candidate, outcome: outcome));
      }
    }
    results.sort();

    final availableLeaves = flat.where((n) => n.available).toList();
    final latencies = <int>[
      for (final node in availableLeaves)
        if (node.ttfbMs != null) node.ttfbMs!,
    ];
    final stats = MarketStats(
      seeds: seeds.length,
      scannedSeeds: seedsDone,
      nodes: flat.length,
      available: availableLeaves.length,
      singles: availableLeaves.where((n) => !n.isMulti).length,
      multis: roots.where((n) => n.isMulti && n.aggregatedAvailable).length,
      avgLatencyMs: latencies.isEmpty
          ? 0
          : latencies.reduce((a, b) => a + b) ~/ latencies.length,
    );

    controller.add(MarketScanDone(
      results,
      parses: parses,
      lives: lives,
      nodes: roots,
      stats: stats,
    ));
    await controller.close();
  }

  static int _compareNodes(MarketNode a, MarketNode b) {
    final aa = a.bestLatencyMs ?? 1 << 30;
    final bb = b.bestLatencyMs ?? 1 << 30;
    return aa.compareTo(bb);
  }

  static int _median(List<int> values) {
    if (values.isEmpty) return 0;
    final sorted = List<int>.of(values)..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  /// 页面 → 候选配置地址：过滤静态资源与导航链接，保序去重。
  @visibleForTesting
  List<String> extractConfigUrls(String page) {
    final out = <String>[];
    final seen = <String>{};
    for (final match in _urlPattern.allMatches(page)) {
      if (out.length >= maxConfigUrlsPerSite) break;
      var url = match.group(0)!;
      while (url.endsWith(',') || url.endsWith(';') || url.endsWith('=')) {
        url = url.substring(0, url.length - 1);
      }
      if (url.isEmpty) continue;
      if (_junkExtension.hasMatch(url)) continue;
      if (url.contains('beian.') || url.contains('analytics')) continue;
      if (_isBlockedUrl(url)) continue;
      if (!seen.add(url)) continue;
      // 只收看起来像配置的地址；纯导航链接会把候选池冲爆。
      if (!_lineKeyword.hasMatch(url) && !url.contains('raw')) continue;
      out.add(url);
    }
    return out;
  }
}
