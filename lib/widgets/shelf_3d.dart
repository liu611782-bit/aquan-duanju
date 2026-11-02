/// 3D 立体书架：横滑轮播 + 透视位姿 + 惯性吸附。
///
/// - 每本书按「与视口中线的距离」倾斜/缩放/明暗（[poseFor]），中间一本正立突出；
/// - 松手吸附到最近档位（[ShelfSnapScrollPhysics]），不会停在两本之间；
/// - 封面来自网络或本地文件，取不到时退化为书脊文字（书名竖排）；
/// - 键盘 ← → 可翻书，回车打开。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/shelf/shelf_geometry.dart';

/// 书架条目（视图与业务解耦：书架页把阅读记录/本地书映射成它）。
class ShelfBook {
  const ShelfBook({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.coverUrl = '',
    this.coverFile,
    this.percent,
  });

  final String id;
  final String title;
  final String subtitle;

  /// 网络封面。
  final String coverUrl;

  /// 本地封面路径。
  final String? coverFile;

  /// 阅读进度 0..1（null = 不画进度条）。
  final double? percent;
}

/// 吸附物理：松手后落到最近的整档（带一点回弹）。
class ShelfSnapScrollPhysics extends ScrollPhysics {
  const ShelfSnapScrollPhysics({super.parent, this.itemExtent = 118});

  final double itemExtent;

  @override
  ShelfSnapScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ShelfSnapScrollPhysics(
        parent: buildParent(ancestor),
        itemExtent: itemExtent,
      );

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // 甩得快就至少前进一档（与 PageScrollPhysics 同语义），否则吸附最近档。
    final page = position.pixels / itemExtent;
    final velocityTolerance = toleranceFor(position).velocity;
    var targetPage = page;
    if (velocity < -velocityTolerance) {
      targetPage = page - 0.5;
    } else if (velocity > velocityTolerance) {
      targetPage = page + 0.5;
    }
    var target = snapTarget(targetPage * itemExtent, itemExtent);
    target = target.clamp(position.minScrollExtent, position.maxScrollExtent);

    if ((target - position.pixels).abs() < 0.5 && velocity.abs() < 1) {
      return null;
    }
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity,
      tolerance: toleranceFor(position),
    );
  }
}

/// 3D 书架视图。
class Shelf3DView extends StatefulWidget {
  const Shelf3DView({
    super.key,
    required this.books,
    required this.onOpen,
    this.metrics = const ShelfMetrics(),
    this.projection = const ShelfProjection(),
    this.onDelete,
  });

  final List<ShelfBook> books;
  final ValueChanged<ShelfBook> onOpen;
  final ValueChanged<ShelfBook>? onDelete;
  final ShelfMetrics metrics;
  final ShelfProjection projection;

  @override
  State<Shelf3DView> createState() => _Shelf3DViewState();
}

class _Shelf3DViewState extends State<Shelf3DView> {
  final _controller = ScrollController();
  int _focused = 0;
  double _offset = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    final next = _controller.hasClients ? _controller.offset : 0.0;
    if ((next - _offset).abs() < 0.01) return;
    setState(() {
      _offset = next;
      _focused = (next / widget.metrics.pitch).round().clamp(
            0,
            math.max(0, widget.books.length - 1),
          );
    });
  }

  void _focus(int index) {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    final target = (index * widget.metrics.pitch)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
    _controller.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight) {
      _focus((_focused + 1).clamp(0, widget.books.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _focus((_focused - 1).clamp(0, widget.books.length - 1));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_focused >= 0 && _focused < widget.books.length) {
        widget.onOpen(widget.books[_focused]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.books.isEmpty) return const SizedBox.shrink();
    final metrics = widget.metrics;
    return Focus(
      onKeyEvent: _onKey,
      child: LayoutBuilder(builder: (context, constraints) {
        final viewport = constraints.maxWidth;
        final half = viewport / 2;
        // 左右留白：第一本/最后一本也能滚到正中。
        final pad = math.max(24.0, half - metrics.itemExtent / 2);
        return ListView.builder(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          physics: ShelfSnapScrollPhysics(itemExtent: metrics.pitch),
          padding: EdgeInsets.symmetric(horizontal: pad, vertical: 18),
          itemCount: widget.books.length,
          itemBuilder: (context, index) {
            final book = widget.books[index];
            final center =
                pad + index * metrics.pitch - _offset + metrics.itemExtent / 2;
            final pose = poseFor(
              offset: center - half,
              halfViewport: half,
              projection: widget.projection,
            );
            return _BookVolume(
              book: book,
              pose: pose,
              metrics: metrics,
              projection: widget.projection,
              index: index,
              focused: index == _focused,
              onTap: () => widget.onOpen(book),
              onDelete: widget.onDelete == null
                  ? null
                  : () => widget.onDelete!(book),
            );
          },
        );
      }),
    );
  }
}

class _BookVolume extends StatefulWidget {
  const _BookVolume({
    required this.book,
    required this.pose,
    required this.metrics,
    required this.projection,
    required this.index,
    required this.focused,
    required this.onTap,
    this.onDelete,
  });

  final ShelfBook book;
  final ShelfPose pose;
  final ShelfMetrics metrics;
  final ShelfProjection projection;
  final int index;
  final bool focused;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  State<_BookVolume> createState() => _BookVolumeState();
}

class _BookVolumeState extends State<_BookVolume> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m = widget.metrics;
    final pose = widget.pose;
    final lift = pose.lift + waveLift(widget.index);
    final width = m.coverWidth + m.spineWidth;

    final matrix = Matrix4.identity()
      ..setEntry(3, 2, widget.projection.perspective)
      ..rotateY(pose.tiltY);

    final cover = _buildCover(theme);

    return Padding(
      padding: EdgeInsets.only(right: m.gap),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          onLongPress: widget.onDelete,
          child: Transform(
            alignment: Alignment.center,
            transform: matrix,
            child: Opacity(
              opacity: lerpDouble(pose.opacity, 1.0, _hover ? 0.6 : 0)!,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                transform: Matrix4.translationValues(
                  0,
                  -lift - (_hover || widget.focused ? 8 : 0),
                  0,
                ),
                child: SizedBox(
                  width: width,
                  height: m.coverHeight + 22,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 地面阴影
                      Positioned(
                        left: m.spineWidth,
                        right: 2,
                        bottom: 0,
                        child: Container(
                          height: 12,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black
                                    .withValues(alpha: 0.28 - pose.z * 0.12),
                                blurRadius: 10 + pose.z * 6,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                        ),
                      ),
                      // 书脊
                      Positioned(
                        left: 0,
                        top: 4,
                        bottom: 14,
                        child: Container(
                          width: m.spineWidth,
                          decoration: BoxDecoration(
                            borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(3)),
                            gradient: LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                theme.colorScheme.primary
                                    .withValues(alpha: 0.85),
                                theme.colorScheme.primary
                                    .withValues(alpha: 0.55),
                              ],
                            ),
                          ),
                        ),
                      ),
                      // 封面
                      Positioned(
                        left: m.spineWidth - 1,
                        top: 4,
                        bottom: 14,
                        right: 0,
                        child: ClipRRect(
                          borderRadius: const BorderRadius.horizontal(
                            right: Radius.circular(4),
                            left: Radius.circular(2),
                          ),
                          child: cover,
                        ),
                      ),
                      // 进度
                      if (widget.book.percent != null)
                        Positioned(
                          left: m.spineWidth,
                          right: 0,
                          bottom: 6,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: widget.book.percent,
                                minHeight: 3,
                              ),
                            ),
                          ),
                        ),
                      // 悬停删除
                      if (_hover && widget.onDelete != null)
                        Positioned(
                          right: -6,
                          top: -6,
                          child: Tooltip(
                            message: '移出书架',
                            child: InkWell(
                              onTap: widget.onDelete,
                              customBorder: const CircleBorder(),
                              child: CircleAvatar(
                                radius: 11,
                                backgroundColor:
                                    theme.colorScheme.surfaceContainerHighest,
                                child: Icon(Icons.close,
                                    size: 13,
                                    color: theme.colorScheme.onSurfaceVariant),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCover(ThemeData theme) {
    final book = widget.book;
    if (book.coverFile != null && book.coverFile!.isNotEmpty) {
      return Image.file(
        File(book.coverFile!),
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(theme),
      );
    }
    if (book.coverUrl.isNotEmpty) {
      return Image.network(
        book.coverUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(theme),
      );
    }
    return _placeholder(theme);
  }

  Widget _placeholder(ThemeData theme) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.colorScheme.surfaceContainerHighest,
            theme.colorScheme.surfaceContainerHigh,
          ],
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Align(
        alignment: Alignment.topCenter,
        child: Text(
          widget.book.title,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelSmall?.copyWith(height: 1.25),
        ),
      ),
    );
  }

}
