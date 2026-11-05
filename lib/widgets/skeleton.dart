import 'package:flutter/material.dart';

/// 骨架屏形态。
enum SkeletonLayout {
  /// 封面网格（榜单 / 发现 / 搜索 / 分类）。
  grid,

  /// 左图右文的行列表（历史 / 配置 / 目录类）。
  list,

  /// 详情页（封面 + 标题 + 剧集格）。
  detail,
}

/// 全站统一的页面级加载占位：流光扫过的骨架屏。
///
/// 用一个 [AnimationController] 驱动整页所有灰块的相位，避免每个块各持一个
/// ticker；`TickerMode` 关闭（页面不可见）时 Ticker 自动静音，不需要手工处理。
class SkeletonView extends StatefulWidget {
  const SkeletonView({
    super.key,
    this.layout = SkeletonLayout.grid,
    this.itemCount = 12,
    this.columns,
  });

  final SkeletonLayout layout;
  final int itemCount;

  /// 仅 [SkeletonLayout.grid] 生效；不传则按宽度自适应（与 SeriesGrid 同规则）。
  final int? columns;

  @override
  State<SkeletonView> createState() => _SkeletonViewState();
}

class _SkeletonViewState extends State<SkeletonView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase;

  @override
  void initState() {
    super.initState();
    _phase = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return AnimatedBuilder(
      animation: _phase,
      builder: (context, _) {
        final shimmer = _ShimmerStyle(
          base: base,
          highlight: Color.alphaBlend(Colors.white.withValues(alpha: 0.28), base),
          phase: _phase.value,
        );
        switch (widget.layout) {
          case SkeletonLayout.grid:
            return _grid(context, shimmer);
          case SkeletonLayout.list:
            return _list(shimmer);
          case SkeletonLayout.detail:
            return _detail(shimmer);
        }
      },
    );
  }

  Widget _grid(BuildContext context, _ShimmerStyle shimmer) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = widget.columns ??
        (width >= 1100 ? 6 : width >= 800 ? 4 : width >= 560 ? 3 : 2);
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.62,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: widget.itemCount,
      itemBuilder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _SkeletonBox(shimmer: shimmer, radius: 12)),
          const SizedBox(height: 8),
          SizedBox(
            height: 12,
            child: _SkeletonBox(shimmer: shimmer, radius: 6),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 10,
            width: 60,
            child: _SkeletonBox(shimmer: shimmer, radius: 5),
          ),
        ],
      ),
    );
  }

  Widget _list(_ShimmerStyle shimmer) {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      itemCount: widget.itemCount,
      itemBuilder: (_, _) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              height: 60,
              child: _SkeletonBox(shimmer: shimmer, radius: 6),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 14,
                    child: _SkeletonBox(shimmer: shimmer, radius: 5),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 11,
                    width: 120,
                    child: _SkeletonBox(shimmer: shimmer, radius: 5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _detail(_ShimmerStyle shimmer) {
    return SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 56, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 108,
                height: 148,
                child: _SkeletonBox(shimmer: shimmer, radius: 10),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 18,
                      child: _SkeletonBox(shimmer: shimmer, radius: 6),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 12,
                      width: 160,
                      child: _SkeletonBox(shimmer: shimmer, radius: 5),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 12,
                      width: 100,
                      child: _SkeletonBox(shimmer: shimmer, radius: 5),
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      height: 34,
                      width: 132,
                      child: _SkeletonBox(shimmer: shimmer, radius: 17),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 22),
          for (var i = 0; i < 2; i++) ...[
            SizedBox(
              height: 13,
              child: _SkeletonBox(shimmer: shimmer, radius: 5),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < 10; i++)
                SizedBox(
                  width: 54,
                  height: 38,
                  child: _SkeletonBox(shimmer: shimmer, radius: 8),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一次流光计算出的三色渐变与相位（整页共享）。
class _ShimmerStyle {
  const _ShimmerStyle({
    required this.base,
    required this.highlight,
    required this.phase,
  });

  final Color base;
  final Color highlight;
  final double phase;

  /// 渐变从左侧外扫到右侧外：p=0 在 [-3,-1]，p=1 在 [1,3]。
  LinearGradient gradient() => LinearGradient(
        colors: [base, highlight, base],
        stops: const [0.35, 0.5, 0.65],
        begin: Alignment(-3.0 + 4.0 * phase, 0),
        end: Alignment(-1.0 + 4.0 * phase, 0),
      );
}

class _SkeletonBox extends StatelessWidget {
  const _SkeletonBox({required this.shimmer, this.radius = 8});

  final _ShimmerStyle shimmer;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: shimmer.gradient(),
      ),
    );
  }
}
