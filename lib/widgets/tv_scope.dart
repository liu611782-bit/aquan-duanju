import 'package:flutter/widgets.dart';

import '../core/tv/tv_mode.dart';

/// 全局运行形态：启动时解析一次，运行中不变。
///
/// 页面用 `TvScope.isTvOf(context)` 判断是否走电视交互；没有该 Scope 时按手机处理，
/// 所以单测与组件预览不需要额外包裹。
class TvScope extends InheritedWidget {
  const TvScope({super.key, required this.formFactor, required super.child});

  final AppFormFactor formFactor;

  bool get isTv => formFactor == AppFormFactor.tv;

  static AppFormFactor formFactorOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvScope>()?.formFactor ??
      AppFormFactor.phone;

  static bool isTvOf(BuildContext context) =>
      formFactorOf(context) == AppFormFactor.tv;

  @override
  bool updateShouldNotify(TvScope oldWidget) =>
      oldWidget.formFactor != formFactor;
}
