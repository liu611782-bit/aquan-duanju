import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/aqua_error.dart';
import '../core/download_service.dart';
import '../core/books/book_source_store.dart';
import '../core/image_cache_store.dart';
import '../core/image_key.dart';
import 'skeleton.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/sources/auto_source_manager.dart';
import '../models/models.dart';
import '../store/stores.dart';

/// 全局单例容器： stores / api 在这里下发（无第三方状态管理依赖）。

class AppScope extends InheritedNotifier<ChangeNotifier> {
  const AppScope({
    super.key,
    required super.notifier,
    required this.api,
    required this.settings,
    required this.history,
    required this.reading,
    required this.listening,
    required this.bookCache,
    required this.follows,
    required this.searches,
    required this.playSkip,
    required this.downloads,
    required this.detailSnapshots,
    required this.sources,
    required this.bookSources,
    required this.sourceHealth,
    required this.marketSites,
    required this.seeds,
    required this.discovery,
    required this.autoSource,
    required this.bookmarks,
    required this.markings,
    required this.replaceRules,
    required this.playbackHealth,
    required this.cast,
    required this.lives,
    required this.readerSettings,
    required this.speech,
    required super.child,
  });

  final AquaApi api;
  final SettingsStore settings;
  final HistoryStore history;
  final ReadingProgressStore reading;
  final ListenProgressStore listening;
  final BookChapterCache bookCache;
  final FollowStore follows;
  final SearchHistoryStore searches;
  final PlaySkipStore playSkip;
  final DownloadService downloads;

  /// 详情页快照缓存（秒开；可再生数据，不进备份）。
  final DetailSnapshotStore detailSnapshots;

  /// 第三方影视源（TVBox / CMS）：配置、健康、源市场索引站。
  final SourcesStore sources;
  final BookSourceStore bookSources;
  final SourceHealthStore sourceHealth;
  final MarketSitesStore marketSites;

  /// 源扫描种子清单（内置线路 / 聚合页 / 清单页 + 用户自定义）。
  final SeedStore seeds;

  /// 自动找源的验证记录与合并快照元信息。
  final SourceDiscoveryStore discovery;

  /// 自动找源调度器（发现 / 验证 / 同步配置 / 重建合并源）。
  final AutoSourceManager autoSource;

  /// 阅读书签。
  final BookmarkStore bookmarks;

  /// 阅读划线/批注。
  final MarkingStore markings;

  /// 正文替换规则（去广告/水印）。
  final ReplaceRuleStore replaceRules;

  /// 播放线路健康度（源|影片|集|线路）。
  final PlaybackHealthStore playbackHealth;

  /// 投屏设备记忆（最近使用 + 钉选）。
  final CastStore cast;

  /// 直播配置（TVBox lives）。
  final LivesStore lives;

  /// 小说阅读器设置（排版 / 点击区 / 动画 / 主题）。
  final ReaderSettingsStore readerSettings;

  /// 全局听书控制器：挂在根上，离开阅读页也能继续读。
  final ReaderSpeechController speech;

  static AppScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!;

  /// 不依赖通知的读取（回调里用）。
  static AppScope read(BuildContext context) {
    final widget = context
        .getElementForInheritedWidgetOfExactType<AppScope>()
        ?.widget;
    if (widget is AppScope) return widget;
    return of(context);
  }
}

/// 统一的三态内容视图：加载骨架 / 错误重试 / 内容。
class LoadView extends StatelessWidget {
  const LoadView({
    super.key,
    required this.loading,
    required this.error,
    required this.onRetry,
    required this.child,
    this.empty = false,
    this.emptyText = '这里空空如也',
    this.skeleton = SkeletonLayout.grid,
  });

  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final Widget child;
  final bool empty;
  final String emptyText;

  /// 加载态骨架形态：按页面内容结构选择（网格 / 列表 / 详情）。
  final SkeletonLayout skeleton;

  @override
  Widget build(BuildContext context) {
    if (loading) return SkeletonView(layout: skeleton);
    if (error != null) {
      return ErrorRetryView(
        error: error!,
        onRetry: onRetry,
      );
    }
    if (empty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.movie_filter_outlined,
                size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(emptyText,
                style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ],
        ),
      );
    }
    return child;
  }
}

/// 错误态：翻译 AquaException，给「重试」。
class ErrorRetryView extends StatelessWidget {
  const ErrorRetryView({
    super.key,
    required this.error,
    required this.onRetry,
    this.onResetDevice,
  });

  final Object error;
  final VoidCallback? onRetry;

  /// 仅在设备被限/被拒时提供：一键重置匿名设备并重试。
  ///
  /// 限流类错误不该自动重试（会更快耗尽配额），但用户可以主动换一台设备。
  final VoidCallback? onResetDevice;

  @override
  Widget build(BuildContext context) {
    // 展示真实原因：吞成「出了点小问题」会让书源/网络问题无从排查。
    final raw = error.toString().replaceFirst(RegExp(r'^Exception: '), '').trim();
    final text = error is AquaException
        ? (error as AquaException).friendlyText
        : (raw.isEmpty || raw == 'Exception'
            ? '出了点小问题，请稍后再试'
            : (raw.length > 260 ? '${raw.substring(0, 260)}…' : raw));
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            children: [
              FilledButton.tonal(
                  onPressed: onRetry, child: const Text('重试')),
              if (onResetDevice != null)
                TextButton(
                  onPressed: onResetDevice,
                  child: const Text('重置设备并重试'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 骨架屏（卡片网格的加载占位）。
///
/// 保留为 [SkeletonView] 的薄封装：旧调用点（含 `SkeletonGrid(columns: 1)`）
/// 不需要改，自动获得流光效果。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.columns = 2});

  final int columns;

  @override
  Widget build(BuildContext context) =>
      SkeletonView(layout: SkeletonLayout.grid, columns: columns);
}

/// 剧集卡片：封面（竖版）+ 标题 + 副行（集数/热度/状态）。
class SeriesCard extends StatelessWidget {
  const SeriesCard({
    super.key,
    required this.item,
    required this.onTap,
    this.subtitle,
    this.badge,
  });

  final SeriesSummary item;
  final VoidCallback onTap;
  final String? subtitle;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = subtitle ??
        (item.episodeCount > 0 ? '共${item.episodeCount}集' : item.category);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: CoverImage(url: item.coverUrl),
                ),
                if (badge != null)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        badge!,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimary,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            sub,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ],
      ),
    );
  }
}

/// 封面图：三级缓存（内存 LRU → 磁盘 → 核心转码）+ 占位 + 失效兜底。
///
/// 服务端返回的封面 URL 签名固定了 .heic 模板（改扩展名即失效），而
/// Flutter 引擎不解码 HEIC，所以字节经 Go 核心 fetchImage 转成 JPEG 再
/// 解码；磁盘缓存里存的是转码后的字节，key 为原始 URL。封面 URL 有签名
/// 过期时间（x-expires），过期 403 时维持裂图占位兜底。
class CoverImage extends StatelessWidget {
  const CoverImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.onFetchError,
  });

  final String url;
  final BoxFit fit;

  /// 诊断钩子：封面加载失败时回调（调用方记录 URL 供排查）。
  final VoidCallback? onFetchError;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(Icons.movie_outlined,
            color: Theme.of(context).colorScheme.outline),
      );
    }
    final api = AppScope.read(context).api;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        // 按展示宽度降采样；约束无界时退回原尺寸（不猜一个上限）。
        final targetWidth = constraints.hasBoundedWidth &&
                constraints.maxWidth.isFinite &&
                constraints.maxWidth > 0
            ? (constraints.maxWidth * dpr).round()
            : null;
        return Image(
          image: AquaImageProvider(url, api, targetWidth: targetWidth),
          fit: fit,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) return child;
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 150),
              child: child,
            );
          },
          errorBuilder: (_, _, _) {
            onFetchError?.call();
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(Icons.broken_image_outlined,
                  color: Theme.of(context).colorScheme.outline),
            );
          },
        );
      },
    );
  }
}

/// 通过 Go 核心转码加载封面（HEIC→JPEG）的 ImageProvider。
/// key 只取 url：同一封面在多个组件里共享一份缓存与解码结果。
class AquaImageProvider extends ImageProvider<AquaImageProvider> {
  const AquaImageProvider(
    this.url,
    this.api, {
    this.targetWidth,
    this.targetHeight,
  });

  final String url;
  final AquaImageFetcher api;

  /// 解码目标尺寸（物理像素）。按展示尺寸降采样，避免 104×140 的小卡片
  /// 去解码 1000px 原图——列表里几十张封面时这是主要的内存与 CPU 开销。
  final int? targetWidth;
  final int? targetHeight;

  @override
  Future<AquaImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AquaImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    AquaImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(key, decode),
      scale: 1.0,
      informationCollector: () sync* {
        yield StringProperty('AquaImageProvider url', url);
      },
    );
  }

  Future<ui.Codec> _load(
      AquaImageProvider key, ImageDecoderCallback decode) async {
    final bytes = await AquaImageCache.instance.load(key.url, key.api);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(
      buffer,
      getTargetSize: (intrinsicWidth, intrinsicHeight) =>
          key._targetSize(intrinsicWidth, intrinsicHeight),
    );
  }

  /// 计算解码尺寸：只缩小、不放大，保持宽高比。
  ///
  /// 新版 Flutter 的解码回调只提供 `getTargetSize`（没有 cacheWidth/cacheHeight），
  /// 返回 `const TargetImageSize()` 表示按原尺寸解码。
  ui.TargetImageSize _targetSize(int width, int height) {
    final tw = targetWidth;
    final th = targetHeight;
    if ((tw == null && th == null) || width <= 0 || height <= 0) {
      return const ui.TargetImageSize();
    }
    var scale = 1.0;
    if (tw != null && tw > 0 && tw < width) scale = tw / width;
    if (th != null && th > 0 && th < height) {
      final s = th / height;
      if (s < scale) scale = s;
    }
    if (scale >= 1) return const ui.TargetImageSize();
    return ui.TargetImageSize(
      width: (width * scale).round().clamp(1, width),
      height: (height * scale).round().clamp(1, height),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AquaImageProvider &&
      other.url == url &&
      other.targetWidth == targetWidth &&
      other.targetHeight == targetHeight;

  @override
  int get hashCode => Object.hash(url, targetWidth, targetHeight);
}

/// 封面字节的三级缓存：内存 LRU → 磁盘（ImageCacheStore，LRU+上限）→ 核心转码。
/// 磁盘与内存里存的都是转码后可直接解码的字节；相同 URL 的并发请求合并。
class AquaImageCache {
  AquaImageCache({this.fetchOverride});

  /// 测试注入点：不给就调 [AquaApi.fetchImage]。
  final Future<AquaImage> Function(String url)? fetchOverride;

  static AquaImageCache instance = AquaImageCache();

  /// 内存层双阈值：条数 + 字节。只有条数上限时，512 条大图仍可能吃掉几百 MB。
  static const int _maxEntries = 512;
  static const int _maxBytes = 96 << 20;

  /// 并发下载上限：网格首屏会一次要十几张，全放出去会互相抢带宽，首图更慢。
  static const int _maxConcurrent = 6;

  final Map<String, Uint8List> _memory = {};
  int _memoryBytes = 0;
  final Map<String, Future<Uint8List>> _inFlight = {};

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  /// 载入图片字节。[url] 可带签名：缓存 key 会先规范化（见 `image_key.dart`），
  /// 否则签名一变就整盘 miss，每次都要重新下载 + HEIC 转码。
  Future<Uint8List> load(String url, AquaImageFetcher api) {
    final key = stableImageKey(url);
    return _inFlight.putIfAbsent(key, () => _load(key, url, api));
  }

  Future<Uint8List> _load(
      String key, String url, AquaImageFetcher api) async {
    try {
      final hit = await cached(key);
      if (hit != null) return hit;
      await _acquire();
      try {
        final image = await (fetchOverride ?? api.fetchImage)(url);
        _memoryPut(key, image.bytes);
        try {
          // 存的是转码后的字节；下次直接命中磁盘，不再进核心。
          await ImageCacheStore.instance.put(key, image.bytes);
        } catch (_) {
          // 磁盘缓存失败不影响显示（测试环境没有 path_provider）。
        }
        return image.bytes;
      } finally {
        _release();
      }
    } finally {
      _inFlight.remove(key);
    }
  }

  Future<void> _acquire() async {
    if (_active < _maxConcurrent) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future;
    _active++;
  }

  void _release() {
    if (_active > 0) _active--;
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    }
  }

  /// 只查缓存（内存 + 磁盘），不发网络。[key] 会被规范化，幂等。
  Future<Uint8List?> cached(String key) async {
    final normalized = stableImageKey(key);
    final mem = _memoryGet(normalized);
    if (mem != null) return mem;
    try {
      final bytes = await ImageCacheStore.instance.get(normalized);
      if (bytes != null) {
        _memoryPut(normalized, bytes);
        return bytes;
      }
    } catch (_) {
      // 磁盘缓存不可用时退化为纯内存缓存。
    }
    return null;
  }

  Uint8List? _memoryGet(String key) {
    final bytes = _memory.remove(key);
    if (bytes != null) _memory[key] = bytes;
    return bytes;
  }

  void _memoryPut(String key, Uint8List bytes) {
    final old = _memory.remove(key);
    if (old != null) _memoryBytes -= old.length;
    _memory[key] = bytes;
    _memoryBytes += bytes.length;
    while (_memory.length > _maxEntries ||
        (_memoryBytes > _maxBytes && _memory.length > 1)) {
      final oldest = _memory.keys.first;
      final dropped = _memory.remove(oldest);
      if (dropped != null) _memoryBytes -= dropped.length;
    }
  }
}

/// 封面预取：列表首屏的封面在滚动到之前先拉一次。
///
/// 只预热前 [limit] 张，且走 [AquaImageCache] 的并发闸门；失败静默（真正可见
/// 时 CoverImage 会再请求一次）。预取命中时 `load` 直接返回内存/磁盘字节，
/// 不再占用下载名额。
class CoverPrefetch extends StatefulWidget {
  const CoverPrefetch({
    super.key,
    required this.urls,
    required this.child,
    this.limit = 12,
  });

  final List<String> urls;
  final Widget child;
  final int limit;

  @override
  State<CoverPrefetch> createState() => _CoverPrefetchState();
}

class _CoverPrefetchState extends State<CoverPrefetch> {
  String _warmed = '';

  @override
  Widget build(BuildContext context) {
    final urls = widget.urls
        .take(widget.limit)
        .where((u) => u.isNotEmpty)
        .toList(growable: false);
    final signature = urls.join('|');
    if (signature != _warmed) {
      _warmed = signature;
      if (urls.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _warm(urls));
      }
    }
    return widget.child;
  }

  void _warm(List<String> urls) {
    if (!mounted) return;
    final api = AppScope.read(context).api;
    for (final url in urls) {
      unawaited(
        AquaImageCache.instance.load(url, api).then(
              (_) {},
              onError: (Object _) {},
            ),
      );
    }
  }
}

/// 网格列数：与 [SeriesGrid]、[SliverSeriesGrid] 共用同一套断点。
int seriesGridColumns(BuildContext context, int? columns) {
  if (columns != null) return columns;
  final width = MediaQuery.sizeOf(context).width;
  return width >= 1100 ? 6 : width >= 800 ? 4 : width >= 560 ? 3 : 2;
}

/// 剧集网格的 sliver 版本：与 [SeriesGrid] 共用列数规则与卡片，但把网格拼进
/// 外层 [CustomScrollView]，让页面只有一个滚动视口。
///
/// 为什么需要它：用 `SliverFillRemaining(hasScrollBody: true)` 包 `SeriesGrid`
/// 会得到**第二个独立滚动源**——滚动网格时外层 scroll offset 不变，任何依赖
/// 外层 offset 的效果（如发现页历史条自动收起/回顶展开）都会失效。
class SliverSeriesGrid extends StatelessWidget {
  const SliverSeriesGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.hasMore = false,
    this.onLoadMore,
    this.columns,
    this.badgeOf,
    this.padding = const EdgeInsets.fromLTRB(12, 8, 12, 24),
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final int? columns;
  final String? Function(SeriesSummary item)? badgeOf;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final cols = seriesGridColumns(context, columns);
    final childCount = items.length + (hasMore ? cols : 0);
    return SliverPadding(
      padding: padding,
      sliver: SliverGrid(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: cols,
          childAspectRatio: 0.62,
          mainAxisSpacing: 14,
          crossAxisSpacing: 12,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            if (index >= items.length) {
              // 触底加载更多：与原 GridView 版本一致，构建到最后一项时触发。
              if (hasMore && onLoadMore != null) {
                WidgetsBinding.instance
                    .addPostFrameCallback((_) => onLoadMore!());
              }
              return const Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              );
            }
            final item = items[index];
            return SeriesCard(
              item: item,
              onTap: () => onTap(item),
              badge: badgeOf?.call(item),
            );
          },
          childCount: childCount,
        ),
      ),
    );
  }
}

/// 双列剧集瀑布网格（自带滚动控制器与加载更多回调）。
class SeriesGrid extends StatelessWidget {
  const SeriesGrid({
    super.key,
    required this.items,
    required this.onTap,
    this.hasMore = false,
    this.onLoadMore,
    this.header,
    this.columns,
    this.badgeOf,
    this.controller,
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final Widget? header;
  final int? columns;

  /// 外部滚动控制器（页面要放「回到顶部」时必须传）；不给则由 GridView 自建。
  final ScrollController? controller;

  /// 每张卡片左上角的角标（如榜单名次）；不给则与原来一致，不显示角标。
  final String? Function(SeriesSummary item)? badgeOf;

  @override
  Widget build(BuildContext context) {
    final cols = seriesGridColumns(context, columns);
    final childCount = items.length + (hasMore ? cols : 0) + (header != null ? 1 : 0);
    return CoverPrefetch(
      urls: [for (final item in items) item.coverUrl],
      child: GridView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: cols,
        childAspectRatio: 0.62,
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
      ),
      itemCount: childCount,
      itemBuilder: (context, index) {
        if (header != null && index == 0) return header!;
        final i = index - (header != null ? 1 : 0);
        if (i >= items.length) {
          // 触底加载更多。
          if (hasMore && onLoadMore != null) {
            WidgetsBinding.instance.addPostFrameCallback((_) => onLoadMore!());
          }
          return const Center(
              child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        }
        final item = items[i];
        return SeriesCard(
          item: item,
          onTap: () => onTap(item),
          badge: badgeOf?.call(item),
        );
      },
      ),
    );
  }
}

/// 把热度/播放数格式化成「4102万热度」。
String formatCount(int n) {
  if (n >= 100000000) {
    final v = n / 100000000;
    return '${_trim(v)}亿';
  }
  if (n >= 10000) {
    final v = n / 10000;
    return '${_trim(v)}万';
  }
  return '$n';
}

String _trim(double v) {
  if (v >= 100) return v.toStringAsFixed(0);
  if (v >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);
}

/// 数字转中文序数（1→第1集，直接用数字即可）。
String episodeLabel(int n) => '第$n集';

/// 随机工具：洗牌（对 RangeError 免疫）。
void shuffleList<T>(List<T> list, {math.Random? rng}) => list.shuffle(rng);

/// 桌面端横向条：常显滚动条 + 鼠标按住拖动 + 垂直滚轮转横向滚动。
///
/// 旧实现用 `PrimaryScrollController` 注入 controller，但横向 `ListView` 在桌面
/// 平台不会继承它（`ScrollView` 只对纵向 / iOS-macOS 继承），于是
/// `controller.hasClients` 恒为 false：滚轮空转、也没有滚动条，表现为「不能左右
/// 移动」。这里改为组件自持 controller 并显式传给内部 `ListView`。
///
/// 手势约定（xiugou-tv `HorizontalScrollArea` 同款）：只把 `dy` 映射到横向，
/// `dx` 留给 Scrollable，避免双倍滚动；鼠标补进 dragDevices，桌面才能按住拖。
class HorizontalScrollStrip extends StatefulWidget {
  const HorizontalScrollStrip({
    super.key,
    required this.children,
    this.height = 52,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
  });

  /// 横向排列的条目（chip 等）。条目自带右侧间距。
  final List<Widget> children;
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  State<HorizontalScrollStrip> createState() => _HorizontalScrollStripState();
}

class _HorizontalScrollStripState extends State<HorizontalScrollStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final delta = event.scrollDelta.dy;
    if (delta == 0 || !_controller.hasClients) return;
    final target = (_controller.offset + delta)
        .clamp(0.0, _controller.position.maxScrollExtent);
    if (target != _controller.offset) _controller.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          // 桌面鼠标默认不在 dragDevices 里，补上才能按住左右拖。
          dragDevices: const {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
            PointerDeviceKind.invertedStylus,
          },
        ),
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            thickness: 3,
            radius: const Radius.circular(2),
            scrollbarOrientation: ScrollbarOrientation.bottom,
            child: ListView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              padding: widget.padding,
              children: widget.children,
            ),
          ),
        ),
      ),
    );
  }
}
