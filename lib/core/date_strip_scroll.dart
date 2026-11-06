/// 横向日期条的居中滚动计算（纯函数，便于单测）。
///
/// 列表左右各加 `_sidePad` 的空白，让**首尾**日期也能滚到视口正中，
/// 而不是被 clamp 到 0 / maxScrollExtent 后贴边。
double dateStripSidePad(
  double viewport,
  double itemWidth, {
  double minPad = 12,
}) {
  if (viewport <= 0) return minPad;
  final pad = (viewport - itemWidth) / 2;
  return pad < minPad ? minPad : pad;
}

/// 第 [index] 个日期项居中时，列表应滚动到的 offset。
double dateStripCenterOffset({
  required double viewport,
  required double itemWidth,
  required int index,
  required double maxScrollExtent,
}) {
  final side = dateStripSidePad(viewport, itemWidth);
  final raw = side + (index + 0.5) * itemWidth - viewport / 2;
  if (raw < 0) return 0;
  if (raw > maxScrollExtent) return maxScrollExtent;
  return raw;
}
