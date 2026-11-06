import 'package:flutter/widgets.dart';

/// 让方向键优先移动焦点，而不是被所在的列表当成滚动吃掉。
///
/// Flutter 的 `Scrollable` 默认把方向键映射成 `ScrollIntent`。电视上遥控器只有
/// 方向键，如果滚动先赢，焦点会永远停在第一屏、按右键只是把列表滚一下。
/// 这里把 `ScrollIntent` 截断：焦点移动交给默认的 `DirectionalFocusIntent`，
/// 列表靠焦点进入不可见区域时的 `ensureVisible` 自动跟随。
///
/// 只在电视形态启用；手机/桌面原样返回，不产生影响。
class TvFocusScope extends StatelessWidget {
  const TvFocusScope({super.key, required this.enabled, required this.child});

  final bool enabled;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return Actions(
      actions: <Type, Action<Intent>>{
        ScrollIntent: CallbackAction<ScrollIntent>(onInvoke: (_) => null),
      },
      child: child,
    );
  }
}
