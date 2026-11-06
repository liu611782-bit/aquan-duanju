import 'package:flutter/material.dart';

/// 全站统一的加载转圈。
///
/// 只有两种规格，调用方**不能**再传任意尺寸/线宽——这是「所有加载中动画都统一」
/// 的硬约束：
/// - 默认构造：页面级，直径 32、线宽 3；
/// - [AppLoading.inline]：行内级（列表触底、按钮内、卡片角标），直径 20、线宽 2。
///
/// 组件本身不居中，页面级请自行包一层 [Center]；颜色默认取主题主色，
/// 深色视频上下文传 `Colors.white`。
class AppLoading extends StatelessWidget {
  /// 页面级加载转圈（32 / 3）。
  const AppLoading({super.key, this.color})
      : size = 32,
        strokeWidth = 3;

  /// 行内加载转圈（20 / 2）。
  const AppLoading.inline({super.key, this.color})
      : size = 20,
        strokeWidth = 2;

  final double size;
  final double strokeWidth;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        strokeWidth: strokeWidth,
        color: color ?? Theme.of(context).colorScheme.primary,
      ),
    );
  }
}
