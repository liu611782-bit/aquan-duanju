/// 播放页长按手势的横向分区。
enum LongPressZone {
  /// 左 1/3：快退。
  rewind,

  /// 中 1/3：不响应。
  none,

  /// 右 1/3：快进。
  forward,
}

/// 判断长按落点属于哪个分区。
///
/// 移动端双击已经让给「暂停/继续」，快进快退改成长按左右各三分之一；中间留空，
/// 避免用户想双击暂停却长按误跳。抽成纯函数是为了能单测 1/3、2/3 两个边界。
LongPressZone longPressZoneAt({
  required double dx,
  required double width,
}) {
  if (width <= 0) return LongPressZone.none;
  final x = dx.clamp(0.0, width);
  if (x < width / 3) return LongPressZone.rewind;
  if (x > width * 2 / 3) return LongPressZone.forward;
  return LongPressZone.none;
}
