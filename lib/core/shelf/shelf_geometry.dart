/// 3D 书架投影常量与位姿公式（**纯 Dart**，只依赖 `dart:math`，可单测）。
///
/// 思路沿用「立体书架」的透视投影：书脊朝向观察者、书壳向右后方递进，
/// 滑动时按书与视口中线的距离做角度/纵向位移（波浪位姿），产生立体纵深。
library;

import 'dart:math' as math;

/// 单本书的投影尺寸。
class ShelfMetrics {
  const ShelfMetrics({
    this.coverWidth = 108,
    this.coverHeight = 154,
    this.spineWidth = 12,
    this.pitch = 118,
    this.gap = 10,
  });

  /// 封面宽。
  final double coverWidth;

  /// 封面高。
  final double coverHeight;

  /// 书脊宽（封面左侧的厚度条）。
  final double spineWidth;

  /// 相邻书的中线间距（吸附步长）。
  final double pitch;

  /// 书与书之间的空隙。
  final double gap;

  double get itemExtent => coverWidth + spineWidth + gap;
}

/// 透视投影常量（数值越小透视越强）。
class ShelfProjection {
  const ShelfProjection({
    this.perspective = 0.0016,
    this.maxTilt = 0.42,
    this.maxLift = 14,
    this.depthX = 0.66,
    this.depthY = -0.30,
  });

  /// `Matrix4` 透视项。
  final double perspective;

  /// 距中心最远时的 Y 轴旋转（弧度）。
  final double maxTilt;

  /// 距中心最远时的纵向抬升（像素，负值向下）。
  final double maxLift;

  /// 纵深方向在 X 轴的投影比例（书壳向右后方退）。
  final double depthX;

  /// 纵深方向在 Y 轴的投影比例（后退同时略微上抬）。
  final double depthY;
}

/// 一本书的位姿。
class ShelfPose {
  const ShelfPose({
    required this.tiltY,
    required this.lift,
    required this.scale,
    required this.opacity,
    required this.z,
  });

  /// 绕 Y 轴旋转（弧度，正值向右转）。
  final double tiltY;

  /// 纵向位移（像素）。
  final double lift;

  /// 缩放（近大远小）。
  final double scale;

  final double opacity;

  /// 纵深（0=正中，1=最外侧），供绘制阴影/亮度用。
  final double z;

  static const ShelfPose identity =
      ShelfPose(tiltY: 0, lift: 0, scale: 1, opacity: 1, z: 0);
}

/// 按「书中线与视口中线的距离」算位姿。
///
/// [offset] 是书中线相对视口中线的像素距离，[halfViewport] 是半个视口宽。
/// 归一化后 `t ∈ [-1, 1]`：中间书正立放大，两侧书向外倾斜、下沉、缩小、变暗。
ShelfPose poseFor({
  required double offset,
  required double halfViewport,
  ShelfProjection projection = const ShelfProjection(),
}) {
  if (halfViewport <= 0) return ShelfPose.identity;
  final t = (offset / halfViewport).clamp(-1.0, 1.0);
  final magnitude = t.abs();
  return ShelfPose(
    tiltY: -t * projection.maxTilt,
    lift: magnitude * projection.maxLift,
    scale: 1.0 - magnitude * 0.16,
    opacity: 1.0 - magnitude * 0.42,
    z: magnitude,
  );
}

/// 吸附目标：离 [offset] 最近的档位（以 [pitch] 为步长）。
double snapTarget(double offset, double pitch) {
  if (pitch <= 0) return offset;
  return (offset / pitch).roundToDouble() * pitch;
}

/// 波浪位姿：整排书的纵向起伏（相邻书反相，读起来像一本本立着）。
double waveLift(int index, {double amplitude = 2.4, double period = 3}) {
  if (period <= 0) return 0;
  return math.sin(index / period * math.pi) * amplitude;
}

/// 书脊高度：越靠两侧越矮（与封面高一致，留出书脊弧度）。
double spineHeight(double coverHeight, double z) =>
    coverHeight * (1 - z * 0.06);
