import 'dart:async';
import 'dart:ui';

/// 漫画阅读器九宫格点击分区（Legado 语义，参考
/// VenHM `docs/LEGADO_READER_INTERACTION_20261023.md`，只取交互合同不搬 UI）。
///
/// 默认九宫格（按**整个阅读窗口** 0.33/0.66 分界，不按单图、不随缩放；
/// **按下位置**判区，松手抖动不影响）：
///
/// |      | 左   | 中   | 右   |
/// |------|------|------|------|
/// | 上   | 上一页 | 上一页 | 下一页 |
/// | 中   | 上一页 | **菜单** | 下一页 |
/// | 下   | 上一页 | 下一页 | 下一页 |
enum MangaTapAction { prev, next, menu }

/// 窗口归一化坐标（0..1）→ 九宫格动作。
MangaTapAction mangaTapActionFor(Offset normalized) {
  final dx = normalized.dx.clamp(0.0, 1.0);
  final dy = normalized.dy.clamp(0.0, 1.0);
  final col = dx < 1 / 3 ? 0 : (dx < 2 / 3 ? 1 : 2);
  final row = dy < 1 / 3 ? 0 : (dy < 2 / 3 ? 1 : 2);
  const grid = [
    [MangaTapAction.prev, MangaTapAction.prev, MangaTapAction.next],
    [MangaTapAction.prev, MangaTapAction.menu, MangaTapAction.next],
    [MangaTapAction.prev, MangaTapAction.next, MangaTapAction.next],
  ];
  return grid[row][col];
}

/// 取消待定单击的原因（取消矩阵：这些事件发生时 200ms 内的单击不算数）。
enum MangaTapCancelReason {
  /// 拖动 / 滚动（TapGestureRecognizer 因移动超过 slop 而取消）。
  drag,

  /// 双击命中（缩放优先，单击让路）。
  doubleTap,

  /// 翻页动画中（双页模式 onPageChanged）。
  pageTurn,

  /// 内容加载中 / 出错（点击不产生翻页）。
  contentNotReady,

  /// 页面销毁。
  disposed,
}

/// 单击/双击仲裁：onTapUp 后等 [tapWait]（默认 200ms，等双击判定），
/// 到点无人取消才执行九宫格动作。
class MangaTapArbiter {
  MangaTapArbiter({
    required this.onAction,
    this.tapWait = const Duration(milliseconds: 200),
  });

  final void Function(MangaTapAction action) onAction;
  final Duration tapWait;

  Timer? _timer;
  Offset? _downNormalized;

  /// 是否有待定单击在等待。
  bool get waiting => _timer != null;

  /// 按下：记录归一化位置；新的按下会作废上一轮待定单击。
  void onTapDown(Offset normalized) {
    _cancelTimer();
    _downNormalized = normalized;
  }

  /// 抬起：启动 200ms 等待。
  void onTapUp() {
    if (_downNormalized == null || _timer != null) return;
    _timer = Timer(tapWait, _settle);
  }

  /// 手势被识别器取消（拖动/多指/系统打断）。
  void onTapCancel() => cancel(MangaTapCancelReason.drag);

  /// 取消矩阵入口。
  void cancel(MangaTapCancelReason reason) {
    _cancelTimer();
    _downNormalized = null;
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void _settle() {
    _cancelTimer();
    final down = _downNormalized;
    _downNormalized = null;
    if (down == null) return;
    onAction(mangaTapActionFor(down));
  }

  void dispose() => cancel(MangaTapCancelReason.disposed);
}
