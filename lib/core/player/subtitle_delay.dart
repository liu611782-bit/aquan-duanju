/// 字幕时差（秒；mpv `sub-delay` 语义：正 = 字幕延后显示，负 = 提前）。
///
/// Pathfin 字幕体系残余增量：时差可调 + 按剧记忆。步进固定 0.5s——
/// 手感与常见错位量级匹配；范围 ±30s 足够覆盖错误字幕源。
abstract final class SubtitleDelay {
  static const double stepSeconds = 0.5;
  static const double minSeconds = -30;
  static const double maxSeconds = 30;

  static double clamp(double v) => v.clamp(minSeconds, maxSeconds);

  /// 步进并吸附到 0.1s 网格（防 0.1+0.2 浮点毛刺进持久化）。
  static double step(double current, int direction) {
    final next = current + direction * stepSeconds;
    return clamp((next * 10).roundToDouble() / 10);
  }

  /// 面板/OSD 文案：0 显示「同步」，正数带 +。
  static String label(double v) =>
      v == 0 ? '同步' : '${v > 0 ? '+' : ''}${v.toStringAsFixed(1)}s';
}
