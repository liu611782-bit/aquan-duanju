import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/seek_gate.dart';

void main() {
  group('SeekGate', () {
    test('未就绪时 seek 被忽略并上报 ignored，不触达播放器', () async {
      final executed = <Duration>[];
      final events = <SeekGateEvent>[];
      final gate = SeekGate(
        run: (p) async => executed.add(p),
        onEvent: (e, _, _, _) => events.add(e),
      );

      await gate.seek(const Duration(seconds: 1));

      expect(executed, isEmpty);
      expect(events, [SeekGateEvent.ignored]);
    });

    test('open 后单次 seek 正常执行，发起/完成事件按序上报', () async {
      final executed = <Duration>[];
      final events = <(SeekGateEvent, Duration)>[];
      final gate = SeekGate(
        run: (p) async => executed.add(p),
        onEvent: (e, p, _, _) => events.add((e, p)),
      )..open();

      const target = Duration(seconds: 3);
      await gate.seek(target);

      expect(executed, [target]);
      expect(events.map((e) => e.$1),
          [SeekGateEvent.dispatch, SeekGateEvent.applied]);
      expect(events.every((e) => e.$2 == target), isTrue);
    });

    test('执行中的连发合并成最新目标（中间目标丢弃，最终位置不丢）', () async {
      final executed = <Duration>[];
      final release = Completer<void>();
      final gate = SeekGate(
        run: (p) async {
          executed.add(p);
          await release.future;
        },
      )..open();

      final f1 = gate.seek(const Duration(seconds: 1));
      final f2 = gate.seek(const Duration(seconds: 2));
      final f3 = gate.seek(const Duration(seconds: 3));
      // 让事件循环把连发都收进闸门。
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await f1;
      await f2;
      await f3;

      // 1s 是正在执行的那次；2s 被 3s 顶掉；最终必须落在 3s。
      expect(executed, [
        const Duration(seconds: 1),
        const Duration(seconds: 3),
      ]);
    });

    test('close 后丢弃待执行目标；正在跑的调用自然结束不吞异常', () async {
      final executed = <Duration>[];
      final release = Completer<void>();
      final gate = SeekGate(
        run: (p) async {
          executed.add(p);
          await release.future;
        },
      )..open();

      final f1 = gate.seek(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      gate.close();
      final f2 = gate.seek(const Duration(seconds: 2));
      release.complete();
      await f1;
      await f2;

      expect(executed, [const Duration(seconds: 1)],
          reason: 'close 时 1s 在跑放它结束，2s 被丢弃');
      expect(gate.isOpen, isFalse);
    });

    test('execute 抛异常不外抛，继续带上最新目标，error 事件携带异常', () async {
      var calls = 0;
      final errors = <Object?>[];
      final gate = SeekGate(
        run: (p) async {
          calls++;
          if (calls == 1) {
            throw StateError('mpv boom');
          }
        },
        onEvent: (e, _, err, _) {
          if (e == SeekGateEvent.error) errors.add(err);
        },
      )..open();

      await gate.seek(const Duration(seconds: 1));
      await gate.seek(const Duration(seconds: 2));

      expect(calls, 2, reason: '第一次失败不能挡住后续目标');
      expect(errors.single, isA<StateError>());
    });

    test('发起/完成事件按窗口节流；error / ignored 永不节流', () async {
      var now = DateTime(2026, 1, 1, 12);
      final dispatches = <Duration>[];
      final errors = <Duration>[];
      final gate = SeekGate(
        run: (p) async {
          throw StateError('boom');
        },
        onEvent: (e, p, _, _) {
          if (e == SeekGateEvent.dispatch) dispatches.add(p);
          if (e == SeekGateEvent.error) errors.add(p);
        },
        now: () => now,
        eventInterval: const Duration(milliseconds: 800),
      )..open();

      await gate.seek(const Duration(seconds: 1));
      now = now.add(const Duration(milliseconds: 100));
      await gate.seek(const Duration(seconds: 2));
      now = now.add(const Duration(milliseconds: 100));
      await gate.seek(const Duration(seconds: 3));

      expect(dispatches, [const Duration(seconds: 1)],
          reason: '800ms 窗口内的其余发起事件被节流');
      expect(errors, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 3),
      ], reason: '异常证据永不节流');
    });

    test('close 后 seek 走 ignored（不再触达播放器）', () async {
      final executed = <Duration>[];
      final events = <SeekGateEvent>[];
      final gate = SeekGate(
        run: (p) async => executed.add(p),
        onEvent: (e, _, _, _) => events.add(e),
      )..open();

      gate.close();
      await gate.seek(const Duration(seconds: 1));

      expect(executed, isEmpty);
      expect(events, [SeekGateEvent.ignored]);
    });
  });
}
