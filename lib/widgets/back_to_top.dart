import 'dart:async';

import 'package:flutter/material.dart';

/// 回到顶部按钮的显示阈值（dp）。
///
/// 约两屏多一点：太早出现会挡住内容，太晚又起不到作用。
const double kBackToTopOffset = 600;

/// 回到顶部：滚动超过 [threshold] 后出现，点击平滑回到顶部。
///
/// 直接放进 `Scaffold.floatingActionButton`（或已有 FAB 的 Column 里）即可。
/// 不可见时返回零尺寸，不会在右下角留下可点击的空位。
class BackToTopFab extends StatefulWidget {
  const BackToTopFab({
    super.key,
    required this.controller,
    this.threshold = kBackToTopOffset,
    this.tooltip = '回到顶部',
  });

  /// 页面主滚动容器的控制器。页面必须自己持有它（不能是临时创建的）。
  final ScrollController controller;

  final double threshold;
  final String tooltip;

  @override
  State<BackToTopFab> createState() => _BackToTopFabState();
}

class _BackToTopFabState extends State<BackToTopFab> {
  bool _scrolled = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant BackToTopFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_sync);
      widget.controller.addListener(_sync);
      _sync();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    if (!mounted) return;
    final scrolled = widget.controller.hasClients &&
        widget.controller.offset > widget.threshold;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
  }

  void _goTop() {
    if (!widget.controller.hasClients) return;
    unawaited(widget.controller.animateTo(
      0,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
    ));
  }

  @override
  Widget build(BuildContext context) {
    // 再判一次：滚动容器在加载态会被替换掉，此时 controller 已 detach，
    // 状态可能仍是「可见」，直接按当前实际情况决定。
    final visible = _scrolled &&
        widget.controller.hasClients &&
        widget.controller.offset > widget.threshold;
    if (!visible) return const SizedBox.shrink();
    return FloatingActionButton.small(
      tooltip: widget.tooltip,
      onPressed: _goTop,
      child: const Icon(Icons.vertical_align_top),
    );
  }
}
