import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/playback_failure.dart';
import 'package:aquan_duanju/core/playback_recovery.dart';

void main() {
  group('decideRecovery', () {
    test('晚期错误一律不自动换线（无论类型与预算）', () {
      for (final kind in PlaybackFailureKind.values) {
        expect(
          decideRecovery(
            kind: kind,
            playedAheadOfAttempt: true,
            hasCandidates: true,
            budgetExhausted: false,
          ),
          RecoveryAction.none,
          reason: '$kind 晚期错误应只提示',
        );
      }
    });

    test('永久性错误：预算内立即换线', () {
      expect(
        decideRecovery(
          kind: PlaybackFailureKind.permanent,
          playedAheadOfAttempt: false,
          hasCandidates: true,
          budgetExhausted: false,
        ),
        RecoveryAction.immediateFallback,
      );
    });

    test('瞬时与未知错误：预算内保留防抖', () {
      for (final kind in [PlaybackFailureKind.transient, PlaybackFailureKind.unknown]) {
        expect(
          decideRecovery(
            kind: kind,
            playedAheadOfAttempt: false,
            hasCandidates: true,
            budgetExhausted: false,
          ),
          RecoveryAction.debounceFallback,
          reason: '$kind 应走防抖',
        );
      }
    });

    test('候选耗尽 → 收尾（过期重解析路径）', () {
      for (final kind in PlaybackFailureKind.values) {
        expect(
          decideRecovery(
            kind: kind,
            playedAheadOfAttempt: false,
            hasCandidates: false,
            budgetExhausted: false,
          ),
          RecoveryAction.finalize,
          reason: '$kind 无候选应收尾',
        );
      }
    });

    test('预算耗尽 → 收尾（即使还有候选）', () {
      for (final kind in PlaybackFailureKind.values) {
        expect(
          decideRecovery(
            kind: kind,
            playedAheadOfAttempt: false,
            hasCandidates: true,
            budgetExhausted: true,
          ),
          RecoveryAction.finalize,
          reason: '$kind 预算耗尽应停止自动换线',
        );
      }
    });
  });

  group('PlaybackRecoveryBudget', () {
    test('默认预算 6 次，计满即耗尽', () {
      final budget = PlaybackRecoveryBudget();
      expect(budget.exhausted, isFalse);
      for (var i = 0; i < PlaybackRecoveryBudget.defaultMaxAttempts; i++) {
        expect(budget.exhausted, isFalse, reason: '第 ${i + 1} 次前不应耗尽');
        budget.recordAttempt();
      }
      expect(budget.exhausted, isTrue);
    });

    test('非法上限回退默认值', () {
      expect(PlaybackRecoveryBudget(maxAttempts: 0).maxAttempts,
          PlaybackRecoveryBudget.defaultMaxAttempts);
      expect(PlaybackRecoveryBudget(maxAttempts: -3).maxAttempts,
          PlaybackRecoveryBudget.defaultMaxAttempts);
    });
  });
}
