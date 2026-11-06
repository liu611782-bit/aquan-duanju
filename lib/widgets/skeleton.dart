import 'package:flutter/material.dart';

import 'loading.dart';

/// 骨架屏形态。
///
/// 仅为兼容既有调用点保留：页面级加载已统一成转圈（见 [AppLoading]），
/// 选中哪个布局不再影响渲染。
enum SkeletonLayout {
  /// 封面网格（榜单 / 发现 / 搜索 / 分类）。
  grid,

  /// 左图右文的行列表（历史 / 配置 / 目录类）。
  list,

  /// 详情页（封面 + 标题 + 剧集格）。
  detail,
}

/// 页面级加载占位。
///
/// 历史上是流光骨架屏，现在全站统一为居中转圈。类名与三个参数保留，
/// 让既有调用点无需改动；新代码请直接用 [AppLoading]。
class SkeletonView extends StatelessWidget {
  const SkeletonView({
    super.key,
    this.layout = SkeletonLayout.grid,
    this.itemCount = 12,
    this.columns,
  });

  /// 仅为兼容旧调用点保留，不再影响渲染。
  final SkeletonLayout layout;

  /// 仅为兼容旧调用点保留，不再影响渲染。
  final int itemCount;

  /// 仅为兼容旧调用点保留，不再影响渲染。
  final int? columns;

  @override
  Widget build(BuildContext context) => const Center(child: AppLoading());
}
