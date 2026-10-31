import 'dart:async';

import 'package:http/http.dart' as http;

import 'source_adapter.dart';
import 'source_fetch.dart';
import 'spider_js_adapter.dart';
import 'spider_js_runtime.dart';

/// 主动测速结论。
enum ProbeState { ok, timeout, failed }

/// 单源测速结论。
///
/// `ttfbMs` 是旧版 `latencyMs` 的语义（响应头到达耗时），保留 [latencyMs]
/// 作为别名，避免既有 UI 改动。
class ProbeOutcome {
  const ProbeOutcome({
    required this.sourceId,
    required this.state,
    int? ttfbMs,
    int? latencyMs,
    this.totalMs,
    this.sizeKb,
    this.speedKbps,
    this.siteCount,
    this.format = PayloadFormat.unknown,
    this.flags = const <SecurityFlag>{},
    this.samples = 1,
    this.reason = '',
  }) : ttfbMs = ttfbMs ?? latencyMs;

  final String sourceId;
  final ProbeState state;

  /// 响应头到达耗时（毫秒）。
  final int? ttfbMs;

  /// body 读完耗时（毫秒）。
  final int? totalMs;
  final double? sizeKb;
  final double? speedKbps;
  final int? siteCount;
  final PayloadFormat format;
  final Set<SecurityFlag> flags;
  final int samples;
  final String reason;

  int? get latencyMs => ttfbMs;

  bool get isOk => state == ProbeState.ok;
}

/// 展示分级：<500 绿（快）/ <2000 正常 / 其余偏慢。
enum ProbeLevel { fast, normal, slow }

ProbeLevel probeLevel(int latencyMs) => latencyMs < 500
    ? ProbeLevel.fast
    : latencyMs < 2000
        ? ProbeLevel.normal
        : ProbeLevel.slow;

/// 测速事件：每源完成即发（UI 边测边显示）。
sealed class ProbeEvent {
  const ProbeEvent();
}

class ProbeProgress extends ProbeEvent {
  const ProbeProgress(this.outcome, this.done, this.total);
  final ProbeOutcome outcome;
  final int done;
  final int total;
}

class ProbeFinished extends ProbeEvent {
  const ProbeFinished(this.outcomes);
  final List<ProbeOutcome> outcomes;
}

/// 探测 URL：JSON 源探 `{api}?ac=videolist&pg=1`，XML 源探 api 本身；
/// spider 源没有直连接口，探测配置 URL 无意义，直接返回 failed。
String probeUrlFor(SourceConfig config) {
  final api = config.api;
  if (config.kind == SourceKind.cmsJson && !api.contains('ac=')) {
    return api.contains('?') ? '$api&ac=videolist&pg=1' : '$api?ac=videolist&pg=1';
  }
  return api;
}

/// 测速单个源：流式 GET，同时得到 TTFB / 总耗时 / 体积。
Future<ProbeOutcome> probeSource(
  SourceConfig config, {
  Duration timeout = const Duration(seconds: 8),
  http.Client? client,
}) async {
  if (config.kind == SourceKind.spider) {
    return ProbeOutcome(
      sourceId: config.id,
      state: ProbeState.failed,
      reason: '需要爬虫引擎',
    );
  }
  if (config.kind == SourceKind.spiderJs) {
    // spider JS 源真探测：下载 JS + 跑 home（分类非空即存活）。
    final sw = Stopwatch()..start();
    try {
      final adapter = SpiderJsAdapter(config);
      final cats = await adapter.categories().timeout(timeout);
      sw.stop();
      if (cats.isEmpty) {
        return ProbeOutcome(
            sourceId: config.id, state: ProbeState.failed, reason: 'home 无分类');
      }
      return ProbeOutcome(
        sourceId: config.id,
        state: ProbeState.ok,
        ttfbMs: sw.elapsedMilliseconds,
        flags: <SecurityFlag>{
          config.api.startsWith('https')
              ? SecurityFlag.httpsSafe
              : SecurityFlag.cleartextHttp,
        },
      );
    } on SpiderLoadException catch (e) {
      return ProbeOutcome(
          sourceId: config.id, state: ProbeState.failed, reason: '$e');
    } on TimeoutException {
      return ProbeOutcome(
          sourceId: config.id, state: ProbeState.timeout, reason: '探测超时');
    } on Exception catch (e) {
      return ProbeOutcome(
          sourceId: config.id, state: ProbeState.failed, reason: '$e');
    }
  }
  final url = probeUrlFor(config);
  final result = await fetchProbe(
    url,
    connectTimeout: timeout,
    readTimeout: timeout,
    headers: config.headers,
    client: client,
    // 已入库的源是用户主动添加的，测速不再过导入期的 SSRF 守卫。
    enforceSsrf: false,
  );
  if (result.ok) {
    return ProbeOutcome(
      sourceId: config.id,
      state: ProbeState.ok,
      ttfbMs: result.ttfbMs,
      totalMs: result.totalMs,
      sizeKb: result.sizeKb,
      speedKbps: result.speedKbps,
      format: detectPayloadFormat(result.text),
      flags: <SecurityFlag>{
        if (result.isHttps) SecurityFlag.httpsSafe else SecurityFlag.cleartextHttp,
      },
    );
  }
  final timeoutLike = result.error.contains('超时');
  return ProbeOutcome(
    sourceId: config.id,
    state: timeoutLike ? ProbeState.timeout : ProbeState.failed,
    ttfbMs: result.ttfbMs == 0 ? null : result.ttfbMs,
    totalMs: result.totalMs == 0 ? null : result.totalMs,
    reason: result.error,
  );
}

/// 批量测速：并发 [concurrency]，每源完成即发 [ProbeProgress]，全部完成后发
/// [ProbeFinished]（按 成功→超时→失败、延迟升序 排好）。「扫描中」可经
/// [CancelToken] 中止（未测的源跳过，返回空列表）。
Stream<ProbeEvent> probeSources(
  List<SourceConfig> configs, {
  int concurrency = 6,
  Duration? timeout,
  CancelToken? cancel,
  http.Client? client,
}) async* {
  final outcomes = <ProbeOutcome>[];
  final total = configs.length;
  var next = 0;
  var done = 0;

  final progress = StreamController<ProbeOutcome>();
  Future<void> worker() async {
    while (true) {
      if (cancel?.isCancelled ?? false) return;
      final i = next++;
      if (i >= configs.length) return;
      final outcome = await probeSource(
        configs[i],
        timeout: timeout ?? const Duration(seconds: 8),
        client: client,
      );
      outcomes.add(outcome);
      done++;
      progress.add(outcome);
    }
  }

  final workers = <Future<void>>[];
  final workerCount = total == 0 ? 0 : concurrency.clamp(1, total);
  for (var i = 0; i < workerCount; i++) {
    workers.add(worker());
  }
  final all = Future.wait(workers);

  // 由 worker 全部结束时关闭控制器（不依赖下面的 await-for 先退出，
  // 否则 0 候选时互相等待造成死锁）。
  unawaited(all.whenComplete(() {
    if (!progress.isClosed) progress.close();
  }));

  var received = 0;
  await for (final outcome in progress.stream) {
    received++;
    yield ProbeProgress(outcome, done, total);
    if (received >= total) break;
  }
  await all;
  if (!progress.isClosed) await progress.close();
  if (cancel?.isCancelled ?? false) {
    yield const ProbeFinished(<ProbeOutcome>[]);
    return;
  }
  int stateRank(ProbeState s) =>
      s == ProbeState.ok ? 0 : s == ProbeState.timeout ? 1 : 2;
  outcomes.sort((a, b) {
    final aMs = a.latencyMs ?? 1 << 30;
    final bMs = b.latencyMs ?? 1 << 30;
    final byRank = stateRank(a.state).compareTo(stateRank(b.state));
    return byRank != 0 ? byRank : aMs.compareTo(bMs);
  });
  yield ProbeFinished(outcomes);
}
