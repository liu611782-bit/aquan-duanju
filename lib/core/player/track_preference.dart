/// 音轨/字幕选择按剧记忆（Pathfin ContinuousTrackSelection 简化口径）。
///
/// 序号口径 = 轨道面板展示序：media_kit 的轨道列表过滤掉 `auto`/`no` 后的
/// 下标（与 [showPlayerTracksSheet] 渲染顺序一致），保证「面板里选第 2 条」
/// 和「换集自动套第 2 条」指同一条轨。
///
/// 匹配策略 v1：按同类序号，越界/未设置 → null（保持播放器默认）。
/// 语言/标题模糊匹配留待真实多轨源出现结构漂移时再加——同剧各集的轨道
/// 结构通常一致，臆想匹配反而会把字幕错配到错误语言。
abstract final class TrackPreference {
  /// 字幕偏好特殊值：用户明确关闭字幕（换集保持关闭，不被默认字幕顶掉）。
  static const int subtitleOff = -1;

  /// 序号是否可直接套用（列表存在且在界内）。
  static bool applicable(int? index, int trackCount) {
    if (index == null) return false;
    if (index == subtitleOff) return true; // 关闭字幕不依赖轨道列表
    return index >= 0 && index < trackCount;
  }
}
