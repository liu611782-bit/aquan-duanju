import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_probe.dart';
import 'package:aquan_duanju/core/sources/source_registry.dart';

SourceConfig _cfg(String id,
    {bool pinned = false,
    bool enabled = true,
    int score = 0,
    int latency = 0}) {
  final c = SourceConfig(id: id, name: id, apis: ['http://x/$id'])
    ..pinned = pinned
    ..enabled = enabled;
  return c;
}

void main() {
  group('sortSourcesForDisplay', () {
    test('钉选 > 启用 > 健康分 > 延迟', () {
      final a = _cfg('a', score: 500);
      final b = _cfg('b', pinned: true, score: -100);
      final c = _cfg('c', enabled: false, score: 9999);
      final d = _cfg('d', score: 500, latency: 50);
      final e = _cfg('e', score: 500, latency: 10);

      final sorted = sortSourcesForDisplay([a, b, c, d, e],
          scoreOf: (s) => s.id == 'a' || s.id == 'e'
              ? 500
              : s.id == 'd'
                  ? 500
                  : s.id == 'b'
                      ? -100
                      : 9999,
          latencyOf: (s) => s.id == 'd' ? 50 : s.id == 'e' ? 10 : 100);

      expect(sorted.map((s) => s.id).toList(), ['b', 'e', 'd', 'a', 'c']);
    });

    test('本轮测速成功排到历史高分源之前', () {
      final old = _cfg('old');
      final fast = _cfg('fast');
      final sorted = sortSourcesForDisplay([old, fast],
          scoreOf: (s) => s.id == 'old' ? 9000 : 0,
          latencyOf: (s) => s.id == 'old' ? 20 : 0,
          probeOf: (s) => s.id == 'fast'
              ? const ProbeOutcome(
                  sourceId: 'fast', state: ProbeState.ok, ttfbMs: 800)
              : null);
      expect(sorted.map((s) => s.id).toList(), ['fast', 'old']);
    });

    test('本轮测速状态序：成功 > 超时 > 失败 > 未测', () {
      final ok = _cfg('ok');
      final timeout = _cfg('timeout');
      final failed = _cfg('failed');
      final none = _cfg('none');
      final probes = <String, ProbeOutcome>{
        'ok': const ProbeOutcome(
            sourceId: 'ok', state: ProbeState.ok, ttfbMs: 1500),
        'timeout': const ProbeOutcome(
            sourceId: 'timeout', state: ProbeState.timeout, reason: '超时'),
        'failed': const ProbeOutcome(
            sourceId: 'failed', state: ProbeState.failed, reason: '失败'),
      };
      final sorted = sortSourcesForDisplay([none, failed, timeout, ok],
          // 未测源健康分最高，也不能插到测过的源前面。
          scoreOf: (s) => s.id == 'none' ? 9999 : 0,
          latencyOf: (_) => 0,
          probeOf: (s) => probes[s.id]);
      expect(
          sorted.map((s) => s.id).toList(), ['ok', 'timeout', 'failed', 'none']);
    });

    test('同为成功按 TTFB 升序，健康分不参与', () {
      final slow = _cfg('slow');
      final fast = _cfg('fast');
      final sorted = sortSourcesForDisplay([slow, fast],
          scoreOf: (s) => s.id == 'slow' ? 9000 : 0,
          latencyOf: (_) => 0,
          probeOf: (s) => ProbeOutcome(
              sourceId: s.id,
              state: ProbeState.ok,
              ttfbMs: s.id == 'slow' ? 900 : 120));
      expect(sorted.map((s) => s.id).toList(), ['fast', 'slow']);
    });

    test('钉选源即使测速失败也排最前', () {
      final pinned = _cfg('pinned', pinned: true);
      final ok = _cfg('ok');
      final sorted = sortSourcesForDisplay([ok, pinned],
          scoreOf: (_) => 0,
          latencyOf: (_) => 0,
          probeOf: (s) => ProbeOutcome(
              sourceId: s.id,
              state: s.id == 'ok' ? ProbeState.ok : ProbeState.failed));
      expect(sorted.map((s) => s.id).toList(), ['pinned', 'ok']);
    });

    test('完全同分时保持入参顺序（稳定 tie-break）', () {
      final x = _cfg('x');
      final y = _cfg('y');
      final z = _cfg('z');
      List<String> run(List<SourceConfig> input) => sortSourcesForDisplay(input,
              scoreOf: (_) => 0, latencyOf: (_) => 0)
          .map((s) => s.id)
          .toList();
      expect(run([x, y, z]), ['x', 'y', 'z']);
      expect(run([z, x, y]), ['z', 'x', 'y']);
    });
  });

  group('dedupeCandidates', () {
    test('按 kind+api 归一化去重，不可用候选剔除', () {
      final out = dedupeCandidates([
        SourceCandidate(name: 'A', api: 'http://x/api/'),
        SourceCandidate(name: 'A2', api: 'http://x/api'),
        const SourceCandidate(
            name: 'S', api: 'csp_X', kind: SourceKind.spider, unsupportedReason: 'x'),
        SourceCandidate(name: 'B', api: 'http://y/api'),
      ]);
      expect(out.length, 2);
      expect(out[0].name, 'A');
      expect(out[1].name, 'B');
    });
  });

  test('dedupeKeyForSeries：标题+年份', () {
    expect(dedupeKeyForSeries('三体', '2024'), '三体@2024');
  });
}
