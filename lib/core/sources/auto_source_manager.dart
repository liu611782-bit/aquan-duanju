import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../store/stores.dart';
import '../error_log.dart';
import '../ops_switches.dart';
import 'merged_source.dart';
import 'source_adapter.dart';
import 'source_discovery.dart';
import 'source_seed.dart';
import 'source_validator.dart';

/// 自动找源对外状态（配置管理页订阅）。
class AutoSourceState {
  const AutoSourceState({
    this.running = false,
    this.message = '',
    this.nextRunAt,
    this.usableConfigs = 0,
  });

  final bool running;
  final String message;
  final DateTime? nextRunAt;
  final int usableConfigs;

  AutoSourceState copyWith({
    bool? running,
    String? message,
    DateTime? nextRunAt,
    int? usableConfigs,
  }) =>
      AutoSourceState(
        running: running ?? this.running,
        message: message ?? this.message,
        nextRunAt: nextRunAt ?? this.nextRunAt,
        usableConfigs: usableConfigs ?? this.usableConfigs,
      );
}

typedef DiscoverFn = Future<DiscoveryReport> Function({
  CancelToken? cancel,
  String githubToken,
});
typedef ValidateFn = Future<ConfigValidation> Function(String url);

/// 自动找源：发现 → 验证 → 同步配置列表 → 重建合并快照。
///
/// 调度语义对齐 TVBox `AutoSourceManager`：
/// - 首次启动延迟 [firstDelay]，避免和首屏抢带宽；
/// - 上次成功 1h / 失败 15min / 缓存超 24h 立即刷新；
/// - 只在「可用配置 < [minUsableBeforeOnline]」时才自动联网，否则只按计划重排；
/// - 一轮全失败时不动任何配置（失败不清缓存）。
class AutoSourceManager {
  AutoSourceManager({
    required this.seeds,
    required this.sources,
    required this.discovery,
    required this.marketSites,
    required this.settings,
    SourceDiscovery? discoveryClient,
    SourceValidator? validator,
    MergedSourceStore? mergedStore,
    DiscoverFn? discover,
    ValidateFn? validate,
  })  : _discover = discover ??
            (discoveryClient ?? SourceDiscovery()).discover,
        _validate =
            validate ?? (validator ?? SourceValidator()).validate,
        _mergedStore = mergedStore ?? MergedSourceStore();

  final SeedStore seeds;
  final SourcesStore sources;
  final SourceDiscoveryStore discovery;
  final MarketSitesStore marketSites;
  final SettingsStore settings;

  final DiscoverFn _discover;
  final ValidateFn _validate;
  final MergedSourceStore _mergedStore;

  /// 上次成功后多久再查（设置可调，默认 60 分钟）。
  Duration get successInterval =>
      Duration(minutes: settings.autoSourceIntervalMinutes);

  /// 上次失败后多久重试。
  static const Duration retryInterval = Duration(minutes: 15);

  /// 缓存超过该时长立即刷新（不等待间隔）。
  static const Duration staleInterval = Duration(hours: 24);

  /// 启动后首次触发的延迟。
  static const Duration firstDelay = Duration(seconds: 60);

  /// 可用配置少于该数量时才自动联网发现。
  static const int minUsableBeforeOnline = 5;

  /// 验证并发数。
  static const int concurrency = 3;

  /// 单候选验证的兜底超时。
  static const Duration candidateTimeout = Duration(seconds: 90);

  final ValueNotifier<AutoSourceState> state =
      ValueNotifier<AutoSourceState>(const AutoSourceState());

  Timer? _timer;
  bool _started = false;
  bool _running = false;
  bool _disposed = false;

  bool get running => _running;

  int get usableCount =>
      discovery.all.where((entry) => entry.usable).length;

  /// 幂等启动：进程内只装一次定时器。
  void start() {
    if (_started || _disposed) return;
    _started = true;
    if (OpsSwitches.disableAutoSource) {
      state.value = AutoSourceState(
        message: '运维急停：自动找源已停用',
        usableConfigs: usableCount,
      );
      return;
    }
    _schedule(_firstDelayOrImmediate());
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    // 不 dispose state：在途一轮可能已进入收尾，向已释放的 notifier 写值会断言；
    // manager 本身随进程存活，交给 GC 更安全。
  }

  /// 手动「立即找源」。
  Future<void> runNow() async {
    if (OpsSwitches.disableAutoSource) {
      state.value = AutoSourceState(
        message: '运维急停：自动找源已停用',
        usableConfigs: usableCount,
      );
      return;
    }
    await _run(manual: true);
  }

  Duration _firstDelayOrImmediate() => firstDelay;

  /// 设置里的开关变化后重新排期（关闭时清掉下一次计划）。
  void rescheduleOnSettingsChanged() {
    if (_disposed) return;
    if (!settings.autoDiscovery) {
      _timer?.cancel();
      _timer = null;
      state.value = AutoSourceState(
        message: state.value.message,
        usableConfigs: usableCount,
      );
      return;
    }
    _schedule(_nextDelay());
  }

  Duration _nextDelay() {
    if (!settings.autoDiscovery) return successInterval;
    final lastRun = discovery.lastRunAt;
    if (lastRun == null) return firstDelay;
    final lastOk = discovery.lastOkAt;
    // 从未成功过：按失败间隔重试，绝不能返回 0（会变成热循环）。
    if (lastOk == null) return retryInterval;
    if (DateTime.now().difference(lastOk) > staleInterval) {
      return Duration.zero;
    }
    final base = discovery.lastError.isEmpty ? successInterval : retryInterval;
    final due = lastRun.add(base);
    final remaining = due.difference(DateTime.now());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  void _schedule(Duration delay) {
    if (_disposed) return;
    _timer?.cancel();
    if (!settings.autoDiscovery) {
      _timer = null;
      return;
    }
    _timer = Timer(delay, () {
      unawaited(_run(manual: false));
    });
    state.value = state.value.copyWith(
      nextRunAt: DateTime.now().add(delay),
      usableConfigs: usableCount,
    );
  }

  Future<void> _run({required bool manual}) async {
    if (_disposed) return;
    if (_running) return;
    if (OpsSwitches.disableAutoSource) {
      state.value = AutoSourceState(
        message: '运维急停：自动找源已停用',
        usableConfigs: usableCount,
      );
      return;
    }
    if (!manual && !settings.autoDiscovery) {
      _schedule(successInterval);
      return;
    }
    // 已有足够可用配置且刚成功过：本轮跳过联网，只重排下一次。
    if (!manual &&
        usableCount >= minUsableBeforeOnline &&
        discovery.lastOkAt != null &&
        DateTime.now().difference(discovery.lastOkAt!) < staleInterval) {
      _schedule(successInterval);
      return;
    }

    _running = true;
    state.value = state.value.copyWith(
      running: true,
      message: manual ? '正在找源…' : '后台找源中…',
    );
    try {
      final report = await _discover(
        githubToken: settings.githubToken,
      );
      final validations = await _validateAll(report.configs);
      final usable = validations.where((v) => v.usable).toList();

      if (usable.isEmpty && validations.isNotEmpty) {
        // 全灭：保留旧配置，只记失败（TVBox 同语义）。
        await discovery.markRun(
          ok: false,
          error: '本轮没有验证到可用配置（${validations.length} 条）',
        );
        state.value = state.value.copyWith(
          running: false,
          message: '没有找到可用配置，保留原有配置',
        );
        return;
      }

      await _apply(validations, report);
      await discovery.markRun(
        ok: usable.isNotEmpty,
        error: usable.isEmpty ? '没有发现可用配置' : '',
      );
      if (usable.isNotEmpty) {
        await _rebuildMerged();
      }
      state.value = AutoSourceState(
        running: false,
        message: usable.isEmpty
            ? '没有发现可用配置'
            : '已更新 ${usable.length} 条可用配置',
        usableConfigs: usableCount,
      );
    } catch (e, stack) {
      ErrorLog.instance.record('自动找源', e, stack);
      try {
        await discovery.markRun(ok: false, error: '自动找源失败');
      } catch (_) {}
      state.value = state.value.copyWith(
        running: false,
        message: '自动找源失败，稍后重试',
      );
    } finally {
      _running = false;
      if (!_disposed) _schedule(_nextDelay());
    }
  }

  Future<List<ConfigValidation>> _validateAll(
    List<DiscoveredConfig> configs,
  ) async {
    final results = <ConfigValidation>[];
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= configs.length) return;
        final config = configs[index];
        try {
          final validation = await _validate(config.url)
              .timeout(candidateTimeout, onTimeout: () {
            return ConfigValidation(
              url: config.url,
              usable: false,
              name: config.name,
              siteCount: 0,
              cmsSiteCount: 0,
              verifiedSites: 0,
              latencyMs: 0,
              message: '验证超时',
              checkedAt: DateTime.now(),
            );
          });
          results.add(validation);
        } catch (_) {
          results.add(ConfigValidation(
            url: config.url,
            usable: false,
            name: config.name,
            siteCount: 0,
            cmsSiteCount: 0,
            verifiedSites: 0,
            latencyMs: 0,
            message: '验证失败',
            checkedAt: DateTime.now(),
          ));
        }
      }
    }

    final workers = <Future<void>>[
      for (var i = 0; i < concurrency; i++) worker(),
    ];
    await Future.wait(workers);
    return results;
  }

  Future<void> _apply(
    List<ConfigValidation> validations,
    DiscoveryReport report,
  ) async {
    final origins = <String, DiscoveryOrigin>{
      for (final config in report.configs)
        normalizeSeedUrl(config.url): config.origin,
    };
    final checkedAt = DateTime.now();
    final entries = <DiscoveryEntry>[];
    for (final validation in validations) {
      final url = validation.url;
      final existing = discovery.entryOf(url);
      entries.add(DiscoveryEntry(
        name: validation.name.isEmpty
            ? (existing?.name ?? url)
            : validation.name,
        url: url,
        origin: origins[normalizeSeedUrl(url)] ??
            existing?.origin ??
            DiscoveryOrigin.manual,
        // 手动配置永远保持 auto=false：它是用户资产，不能被自动剔除。
        auto: existing?.auto ?? true,
        usable: validation.usable,
        siteCount: validation.siteCount,
        verifiedSites: validation.verifiedSites,
        latencyMs: validation.latencyMs,
        checkedAt: checkedAt,
        message: validation.message,
      ));
    }
    await discovery.upsertAll(entries);

    // 可用 → 写入配置列表（自定义种子，按 URL 去重）。
    final existingSeeds = seeds.seeds;
    final seedUrls = <String>{
      for (final seed in existingSeeds) normalizeSeedUrl(seed.url),
    };
    for (final validation in validations.where((v) => v.usable)) {
      final norm = normalizeSeedUrl(validation.url);
      if (norm.isEmpty || !seedUrls.add(norm)) continue;
      await seeds.add(
        validation.name.isEmpty ? norm : validation.name,
        validation.url,
        SeedKind.line,
      );
    }

    // 失效 → 只剔除「本轮验证过 + auto」的条目对应的自定义种子。
    final deadUrls = <String>{
      for (final validation in validations.where((v) => !v.usable))
        normalizeSeedUrl(validation.url),
    };
    if (deadUrls.isEmpty) return;
    final autoDead = discovery.autoEntries
        .where((entry) =>
            !entry.usable && deadUrls.contains(normalizeSeedUrl(entry.url)))
        .toList();
    for (final entry in autoDead) {
      final norm = normalizeSeedUrl(entry.url);
      for (final seed in existingSeeds) {
        if (seed.builtin) continue;
        if (normalizeSeedUrl(seed.url) != norm) continue;
        await seeds.remove(seed.id);
        break;
      }
    }
  }

  Future<void> _rebuildMerged() async {
    // 设置里关掉自动合并、或运维急停要求冻结快照时，保留现有文件不动。
    if (!settings.autoMergeSources || OpsSwitches.disableAutoMerge) return;
    final result = MergedSourceBuilder.build(
      sources.enabled,
      parses: marketSites.parses,
    );
    if (!result.ok) return;
    final written = await _mergedStore.write(result.json);
    if (!written) return;
    await discovery.markMerged(result.siteCount);
  }
}
