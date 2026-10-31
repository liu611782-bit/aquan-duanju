/// 下一集提示条（播完前引导，参照 Pathfin `nextEpisodePromptRemainingSeconds`
/// 的「这是提示出现阈值，不伪称剩余秒数后一定自动换集」语义）。
///
/// 与片尾跳过互斥：设置了片尾（endingMs）的分集由片尾路径处理（自然越过
/// 阈值时直接切/停），提示条只服务「没有片尾配置」的场景——调用方传
/// [outroConfigured] 即可。
///
/// 防重与取消语义（一次播放内）：
/// - 提示条对同一集只自动出现一次（[consumed] 由播放器持有、换集重置）；
/// - 用户点「取消」→ [consumePrompt] 永久消费，本集不再出现；
/// - 用户 seek 回退离开阈值区 → 播放器收起提示条并 [releasePrompt]，
///   再次接近末尾允许重新出现（用户可能只是想回看）。
class NextEpisodePrompt {
  const NextEpisodePrompt({required this.remainingMs, required this.autoAdvance});

  /// 距「自然播完」的剩余毫秒（倒计时显示与 autoAdvance 定时共用）。
  final int remainingMs;

  /// 自动连播开启时为 true：倒计时到点由播放器切下一集。
  final bool autoAdvance;
}

/// 默认提前量：未设片尾时，剩余时长低于该值出提示。
const Duration kNextEpisodeLeadTime = Duration(seconds: 15);

/// seek 回退多少距离以内视为「用户想回看」而不是抖动，收起提示。
const Duration kNextPromptSeekBackGrace = Duration(seconds: 2);

/// 判定当前是否应显示下一集提示条。
///
/// - [hasNext]：还有下一集（最后一集不出）；
/// - [outroConfigured]：本集已配置片尾跳过（走片尾路径，提示条不出）；
/// - [consumed]：本集已消费过提示的键集合（播放器持有，换集重置）；
/// - [key]：本集提示键（同一集内恒定即可）。
NextEpisodePrompt? nextEpisodePrompt({
  required Duration position,
  required Duration duration,
  required bool hasNext,
  required bool autoNext,
  required bool outroConfigured,
  required Set<String> consumed,
  String key = 'next',
  Duration leadTime = kNextEpisodeLeadTime,
}) {
  if (!hasNext || consumed.contains(key)) return null;
  if (outroConfigured) return null;
  if (duration <= Duration.zero || position < Duration.zero) return null;
  if (position >= duration) return null;
  final trigger = duration - leadTime;
  if (trigger <= Duration.zero) return null; // 片子太短，不做提示
  if (position < trigger) return null;
  return NextEpisodePrompt(
    remainingMs: (duration - position).inMilliseconds,
    autoAdvance: autoNext,
  );
}

/// 用户 seek 回退是否应收起提示条（回到阈值区之前并超过防抖距离）。
bool shouldHideNextPromptOnSeek({
  required Duration position,
  required Duration duration,
  required bool outroConfigured,
  Duration leadTime = kNextEpisodeLeadTime,
  Duration grace = kNextPromptSeekBackGrace,
}) {
  if (outroConfigured || duration <= Duration.zero) return false;
  final trigger = duration - leadTime;
  if (trigger <= Duration.zero) return false;
  return position < trigger - grace;
}

/// 永久消费（用户点了「取消」）：本集不再出现。
void consumePrompt(Set<String> consumed, {String key = 'next'}) =>
    consumed.add(key);

/// 临时释放（seek 回退）：再次接近末尾可重新出现。
void releasePrompt(Set<String> consumed, {String key = 'next'}) =>
    consumed.remove(key);
