/// 播放器全屏切换的纯状态机：只描述「进入 / 退出」的**有序步骤**，
/// 窗口调用由播放器页执行（本文件不 import 任何窗口插件，可单测）。
///
/// 背景（用户实测「全屏 ESC 退出后标题栏消失，再点全屏按钮又有」）：自建
/// 全屏 = 隐标题栏 + 铺满显示器 + setFullScreen(true) 三件事，退出必须按序
/// 还原。历史 bug 是 Esc 快捷键路径直接调 `setFullScreen(false)`，跳过了
/// 标题栏恢复——窗口退出原生全屏但标题栏仍是 hidden。修复约定：**所有**
/// 进入/退出路径（按钮、F 键、Esc、退出页面）都执行这里给出的步骤序列，
/// 不允许任何路径绕过。
library;

/// 一步窗口操作；播放器页把它映射到 window_manager 调用。
enum FullscreenStep {
  /// 进入前记录当前窗口 bounds（退出时还原）。
  saveBounds,

  /// 解除最小尺寸限制（铺满显示器的 setBounds 不被 minSize 顶住）。
  clearMinimumSize,

  /// 隐藏标题栏（进入全屏的视觉前提）。
  hideTitleBar,

  /// 窗口铺满显示器工作区。window_manager 0.5.2 的 Windows setFullScreen
  /// 只剥 THICKFRAME/MAXIMIZEBOX 且盖不住任务栏，所以要先铺满再开原生标记。
  coverDisplay,

  /// 原生全屏标记打开。
  nativeFullscreenOn,

  /// 原生全屏标记关闭（必须在恢复标题栏**之前**：先退原生全屏再还原边框）。
  nativeFullscreenOff,

  /// 恢复标题栏。全屏退出的关键步——任何退出路径都不可跳过。
  showTitleBar,

  /// 恢复最小尺寸。
  restoreMinimumSize,

  /// 还原进入前的 bounds；进入时没记录成功就不执行（不瞎还原）。
  restoreBounds,
}

/// 进入全屏的有序步骤。
const List<FullscreenStep> kFullscreenEnterSteps = [
  FullscreenStep.saveBounds,
  FullscreenStep.clearMinimumSize,
  FullscreenStep.hideTitleBar,
  FullscreenStep.coverDisplay,
  FullscreenStep.nativeFullscreenOn,
];

/// 退出全屏的有序步骤。
///
/// [restorableBounds] 为 false（进入时 bounds 没记录上）时不含
/// [FullscreenStep.restoreBounds]。单测锁定两条不变式：
/// 1. `nativeFullscreenOff` 在 `showTitleBar` 之前（先退全屏再还原标题栏）；
/// 2. 任何退出序列都包含 `showTitleBar`（标题栏必须恢复——原 bug 的回归锁）。
List<FullscreenStep> fullscreenExitSteps({required bool restorableBounds}) => [
      FullscreenStep.nativeFullscreenOff,
      FullscreenStep.showTitleBar,
      FullscreenStep.restoreMinimumSize,
      if (restorableBounds) FullscreenStep.restoreBounds,
    ];
