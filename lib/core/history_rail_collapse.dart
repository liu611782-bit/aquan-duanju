/// 发现页历史条（继续观看 / 最近在读）的自动折叠判定。
///
/// 这里只放纯计算，滚动监听在 `discover_screen` 里；拆出来是为了能单测边界，
/// 也避免把阈值散落在两处。
library;

/// 上滑超过该偏移 → 自动折叠。
const double kHistoryFoldOffset = 120;

/// 回到顶部（≤ 该偏移）→ 自动展开。
const double kHistoryUnfoldOffset = 8;

/// 这次滚动后是否应该折叠。
///
/// [manualExpand] 为真表示用户刚手动展开：此时不再自动折叠，直到滚回顶部
/// 把标记清掉（否则「刚点开就被下一次滚动收起」）。
bool shouldFoldHistoryRail({
  required double offset,
  required bool collapsed,
  required bool manualExpand,
}) {
  if (collapsed || manualExpand) return false;
  return offset > kHistoryFoldOffset;
}

/// 是否应该自动展开（只在已折叠且回到顶部时成立）。
bool shouldUnfoldHistoryRail({
  required double offset,
  required bool collapsed,
}) {
  if (!collapsed) return false;
  return offset <= kHistoryUnfoldOffset;
}
