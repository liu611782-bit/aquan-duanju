import 'playback_failure.dart';

/// 播放失败后的自动恢复决策（纯逻辑，[player_screen] 集成方执行动作）。
///
/// 语义（与既有行为对齐，见 playback-robustness 契约）：
/// - [RecoveryAction.none]：晚期错误（本条线路已播出「早期窗口」以上）——
///   不自动换线，只提示；播放确实停了再进错误面板；
/// - [RecoveryAction.immediateFallback]：永久性错误 → 立即换下一条候选；
/// - [RecoveryAction.debounceFallback]：瞬时/未知错误 → 保留防抖（2s），
///   期间位置前进就取消换线；
/// - [RecoveryAction.finalize]：候选耗尽或**自动恢复预算耗尽** → 走收尾
///   （过期重解析恰好一次，再失败进错误面板）。
enum RecoveryAction { none, immediateFallback, debounceFallback, finalize }

/// 单集自动恢复预算。
///
/// 候选规划上限由 `planPlaybackCandidates(maxCandidates: 4)` 决定；这里额外
/// 约束「同一集内自动换线总次数」，防止错误→防抖→换线→又错误的循环在长片
/// 里反复折腾（每次都保留位置的换线对用户仍是打扰）。
class PlaybackRecoveryBudget {
  PlaybackRecoveryBudget({int maxAttempts = defaultMaxAttempts})
      : maxAttempts = maxAttempts < 1 ? defaultMaxAttempts : maxAttempts;

  static const int defaultMaxAttempts = 6;

  /// 单集自动换线次数上限（不含用户手动操作与过期重解析）。
  final int maxAttempts;

  int attempts = 0;

  bool get exhausted => attempts >= maxAttempts;

  /// 记一次已执行的自动换线。
  void recordAttempt() => attempts++;
}

/// 判定一次播放错误该怎么自动恢复。
///
/// - [playedAheadOfAttempt]：当前线路开播位置之后已前进超过早期窗口
///   （player 侧的「晚期错误」判定，本条线路算基本可用）；
/// - [hasCandidates]：还有未尝试的候选线路；
/// - [budgetExhausted]：本集自动换线预算是否已用完。
RecoveryAction decideRecovery({
  required PlaybackFailureKind kind,
  required bool playedAheadOfAttempt,
  required bool hasCandidates,
  required bool budgetExhausted,
}) {
  if (playedAheadOfAttempt) return RecoveryAction.none;
  if (!hasCandidates || budgetExhausted) return RecoveryAction.finalize;
  return kind == PlaybackFailureKind.permanent
      ? RecoveryAction.immediateFallback
      : RecoveryAction.debounceFallback;
}
