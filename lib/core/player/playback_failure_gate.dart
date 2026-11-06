/// 播放失败判定门控。
///
/// mpv 的 `stream.error` 里混有大量**非致命**错误：某个 HLS 分片、音轨、
/// 字幕或广告段失败后自行回退，主画面随后仍能正常出画。旧实现一收到
/// error 就弹「播放失败」并换线，于是出现「电影正在播却提示失败」。
///
/// 规则：只有「确实没有任何出画信号」且经过 [playbackErrorGrace] 宽限期
/// 仍未出画，才允许判定失败。
const Duration playbackErrorGrace = Duration(seconds: 6);

bool hasVisiblePlayback({
  required bool playingConfirmed,
  required bool playing,
  required Duration position,
  required bool buffering,
}) =>
    playingConfirmed ||
    playing ||
    position > Duration.zero ||
    buffering;
