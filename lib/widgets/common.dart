import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/aqua_error.dart';
import '../core/download_service.dart';
import '../core/books/book_source_store.dart';
import '../core/image_cache_store.dart';
import '../core/reader/reader_speech_controller.dart';
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
  });

  final bool loading;
  final Object? error;
  final VoidCallback? onRetry;
  final Widget child;
  final bool empty;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (loading) return const SkeletonGrid();
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
  const ErrorRetryView({super.key, required this.error, required this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final text = error is AquaException
        ? (error as AquaException).friendlyText
        : '出了点小问题，请稍后再试';
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined,
              size: 56, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(text, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: 16),
          FilledButton.tonal(
              onPressed: onRetry, child: const Text('重试')),
        ],
      ),
    );
  }
}

/// 骨架屏（双列卡片网格的加载占位）。
class SkeletonGrid extends StatelessWidget {
  const SkeletonGrid({super.key, this.columns = 2});

  final int columns;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 0.62,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
      ),
      itemCount: 12,
      itemBuilder: (_, _) => Container(
        decoration: BoxDecoration(
          color: base.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }
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
    return Image(
      image: AquaImageProvider(url, AppScope.read(context).api),
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
  }
}

/// 通过 Go 核心转码加载封面（HEIC→JPEG）的 ImageProvider。
/// key 只取 url：同一封面在多个组件里共享一份缓存与解码结果。
class AquaImageProvider extends ImageProvider<AquaImageProvider> {
  const AquaImageProvider(this.url, this.api);

  final String url;
  final AquaImageFetcher api;

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
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is AquaImageProvider && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

/// 封面字节的三级缓存：内存 LRU → 磁盘（ImageCacheStore，LRU+上限）→ 核心转码。
/// 磁盘与内存里存的都是转码后可直接解码的字节；相同 URL 的并发请求合并。
class AquaImageCache {
  AquaImageCache({this.fetchOverride});

  /// 测试注入点：不给就调 [AquaApi.fetchImage]。
  final Future<AquaImage> Function(String url)? fetchOverride;

  static AquaImageCache instance = AquaImageCache();

  static const _maxEntries = 256;

  final Map<String, Uint8List> _memory = {};
  final Map<String, Future<Uint8List>> _inFlight = {};

  Future<Uint8List> load(String url, AquaImageFetcher api) {
    return _inFlight.putIfAbsent(url, () => _load(url, api));
  }

  Future<Uint8List> _load(String url, AquaImageFetcher api) async {
    try {
      final hit = await cached(url);
      if (hit != null) return hit;
      final image = await (fetchOverride ?? api.fetchImage)(url);
      _memoryPut(url, image.bytes);
      try {
        // 存的是转码后的字节；下次直接命中磁盘，不再进核心。
        await ImageCacheStore.instance.put(url, image.bytes);
      } catch (_) {
        // 磁盘缓存失败不影响显示（测试环境没有 path_provider）。
      }
      return image.bytes;
    } finally {
      _inFlight.remove(url);
    }
  }

  /// 只查缓存（内存 + 磁盘），不发网络。
  Future<Uint8List?> cached(String url) async {
    final mem = _memoryGet(url);
    if (mem != null) return mem;
    try {
      final bytes = await ImageCacheStore.instance.get(url);
      if (bytes != null) {
        _memoryPut(url, bytes);
        return bytes;
      }
    } catch (_) {
      // 磁盘缓存不可用时退化为纯内存缓存。
    }
    return null;
  }

  Uint8List? _memoryGet(String url) {
    final bytes = _memory.remove(url);
    if (bytes != null) _memory[url] = bytes;
    return bytes;
  }

  void _memoryPut(String url, Uint8List bytes) {
    _memory.remove(url);
    _memory[url] = bytes;
    while (_memory.length > _maxEntries) {
      _memory.remove(_memory.keys.first);
    }
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
  });

  final List<SeriesSummary> items;
  final void Function(SeriesSummary item) onTap;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final Widget? header;
  final int? columns;

  /// 每张卡片左上角的角标（如榜单名次）；不给则与原来一致，不显示角标。
  final String? Function(SeriesSummary item)? badgeOf;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final cols = columns ??
        (width >= 1100 ? 6 : width >= 800 ? 4 : width >= 560 ? 3 : 2);
    final childCount = items.length + (hasMore ? cols : 0) + (header != null ? 1 : 0);
    return GridView.builder(
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
