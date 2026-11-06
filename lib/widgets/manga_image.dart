import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../core/aqua_api.dart';
import '../core/image_cache_store.dart';
import '../core/image_key.dart';
import 'common.dart';
import 'loading.dart';

/// 漫画的一页：字节由 core 下载并按整话密钥解密，这里负责缓存与展示。
class MangaPageImage extends StatelessWidget {
  const MangaPageImage({
    super.key,
    required this.url,
    this.keyHex = '',
    this.aspectRatio = 1000 / 1500,
  });

  final String url;
  final String keyHex;
  final double aspectRatio;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return _placeholder(context, Icons.image_not_supported_outlined);
    return AspectRatio(
      aspectRatio: aspectRatio,
      child: Image(
        image: MangaPageProvider(
          url,
          keyHex,
          AppScope.read(context).api,
        ),
        fit: BoxFit.contain,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSync) {
          if (wasSync) return child;
          // 加载中给可见占位：黑底阅读器里透明占位=整页黑，用户会以为死了。
          if (frame == null) {
            return Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              alignment: Alignment.center,
              child: const AppLoading.inline(),
            );
          }
          return AnimatedOpacity(
            opacity: 1,
            duration: const Duration(milliseconds: 160),
            child: child,
          );
        },
        errorBuilder: (_, _, _) =>
            _placeholder(context, Icons.broken_image_outlined),
      ),
    );
  }

  Widget _placeholder(BuildContext context, IconData icon) => AspectRatio(
        aspectRatio: aspectRatio,
        child: Container(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          child: Icon(icon, color: Theme.of(context).colorScheme.outline),
        ),
      );
}

/// 漫画页的 ImageProvider：同一 (url, key) 共享一次下载与解密。
class MangaPageProvider extends ImageProvider<MangaPageProvider> {
  const MangaPageProvider(this.url, this.key, this.api);

  final String url;
  final String key;
  final MangaPageFetcher api;

  @override
  Future<MangaPageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<MangaPageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    MangaPageProvider key,
    ImageDecoderCallback decode,
  ) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1.0,
        informationCollector: () sync* {
          yield StringProperty('MangaPageProvider url', url);
        },
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await MangaPageCache.instance.load(url, key, api);
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is MangaPageProvider &&
      stableImageKey(other.url) == stableImageKey(url) &&
      other.key == key;

  @override
  int get hashCode => Object.hash(stableImageKey(url), key);
}

/// 漫画页字节缓存：内存 LRU → 磁盘（flutter_cache_manager）→ core 解密。
class MangaPageCache {
  MangaPageCache({this.maxEntries = 48});

  final int maxEntries;

  static MangaPageCache instance = MangaPageCache();

  final Map<String, Uint8List> _memory = {};
  final Map<String, Future<Uint8List>> _inFlight = {};

  /// 缓存的磁盘/内存 key。URL 先规范化：漫画图同样走带签名的 CDN 直链，
  /// 签名变化不该导致整页重下重解密。
  static String _cacheKey(String url, String key) =>
      'manga:$key:${stableImageKey(url)}';

  Future<Uint8List> load(String url, String key, MangaPageFetcher api) {
    final cacheKey = _cacheKey(url, key);
    return _inFlight.putIfAbsent(cacheKey, () => _load(cacheKey, url, key, api));
  }

  Future<Uint8List> _load(
      String cacheKey, String url, String key, MangaPageFetcher api) async {
    try {
      final mem = _memory.remove(cacheKey);
      if (mem != null) {
        _memory[cacheKey] = mem;
        return mem;
      }
      try {
        final disk = await ImageCacheStore.instance.get(cacheKey);
        if (disk != null) {
          _put(cacheKey, disk);
          return disk;
        }
      } catch (_) {
        // 磁盘不可用时退化为纯内存。
      }
      final image = await api.fetchMangaPage(url, key);
      _put(cacheKey, image.bytes);
      try {
        await ImageCacheStore.instance.put(cacheKey, image.bytes);
      } catch (_) {}
      return image.bytes;
    } finally {
      _inFlight.remove(cacheKey);
    }
  }

  void _put(String key, Uint8List bytes) {
    _memory.remove(key);
    _memory[key] = bytes;
    while (_memory.length > maxEntries) {
      _memory.remove(_memory.keys.first);
    }
  }
}
