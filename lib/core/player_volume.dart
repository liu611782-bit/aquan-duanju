import 'package:flutter/material.dart';

/// 桌面端底栏显示音量滑块的窗口宽度下限（dp）。
///
/// 底栏固定子项约 528dp，音量控件再加 148dp；窗口再窄就会把最右侧的全屏按钮
/// 挤出屏幕，所以低于该宽度直接隐藏音量控件。
const double kVolumeBarMinWidth = 720;

/// 音量 → 喇叭图标：0 静音、低于一半用「小喇叭」、其余用「大喇叭」。
IconData volumeIconFor(double volume) {
  if (volume <= 0) return Icons.volume_off_rounded;
  if (volume < 50) return Icons.volume_down_rounded;
  return Icons.volume_up_rounded;
}

/// 是否显示底栏音量控件：只在桌面端、且窗口足够宽时显示。
bool showVolumeBar({required bool desktop, required double width}) =>
    desktop && width >= kVolumeBarMinWidth;
