import 'package:flutter/material.dart';

/// 电视上「焦点可见」的点击容器。
///
/// 电视没有悬停与触摸反馈，必须靠焦点态告诉用户当前选中的是哪一项：聚焦时放大
/// 1.06 + 主色描边 + 阴影。非电视形态只包一层 `InkWell`，不产生额外动画开销。
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.onTap,
    required this.child,
    this.enabled = true,
    this.scale = 1.06,
    this.radius = 12,
  });

  final VoidCallback onTap;
  final Widget child;

  /// 电视形态传 true；其余形态传 false，退化为普通可点击区域。
  final bool enabled;
  final double scale;
  final double radius;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final ink = InkWell(
      onTap: widget.onTap,
      canRequestFocus: widget.enabled,
      borderRadius: BorderRadius.circular(widget.radius),
      onFocusChange: (focused) {
        if (!widget.enabled || focused == _focused) return;
        setState(() => _focused = focused);
      },
      child: widget.child,
    );
    if (!widget.enabled) return ink;

    final scheme = Theme.of(context).colorScheme;
    return AnimatedScale(
      scale: _focused ? widget.scale : 1,
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(widget.radius),
          border: Border.all(
            color: _focused ? scheme.primary : Colors.transparent,
            width: 2,
          ),
          boxShadow: _focused
              ? [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.35),
                    blurRadius: 16,
                  ),
                ]
              : const [],
        ),
        child: ink,
      ),
    );
  }
}
