/// 电视大屏的尺寸参数。
///
/// 电视是 10-foot UI：同屏列数比手机/桌面少一档，封面更大，聚焦还要再放大。
/// 这里只放纯数值，不依赖 Flutter 上下文，方便单测。
library;

/// TV 上网格列数（按窗口宽度分档）。
///
/// 电视盒子输出通常是 1280×720 或 1920×1080 逻辑像素，4~5 列是「一眼能扫完」
/// 的上限；再多焦点移动会变成体力活。
int tvColumnsFor(double width) {
  if (width >= 1600) return 6;
  if (width >= 1200) return 5;
  if (width >= 900) return 4;
  return 3;
}

/// 电视上卡片聚焦时的放大倍数。
///
/// 电视观看距离远，纯描边不够醒目；1.06 的放大配合主色描边在 3 米外也能看清。
const double kTvFocusScale = 1.06;
