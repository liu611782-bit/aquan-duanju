/// 播放页底栏的布局阈值。
///
/// 底栏固定子项：上一集 / 播放 / 下一集 / 选集 / 更多 / 睡眠定时 / 倍速 /
/// 横竖屏。IconButton 默认 48dp，睡眠与倍速另有文本内边距，合计约 394dp。
/// 可用宽度低于 [kCompactPlayerBarWidth] 时把睡眠定时与倍速收进「更多」，
/// 否则最右侧的横竖屏按钮会被裁出屏幕（用户实测「一半在屏幕外」）。
library;

const double kCompactPlayerBarWidth = 420;

/// 是否使用紧凑底栏。桌面端窗口足够宽，永远不紧凑。
bool useCompactPlayerBar({required bool desktop, required double width}) =>
    !desktop && width < kCompactPlayerBarWidth;
