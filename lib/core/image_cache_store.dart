import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path_provider/path_provider.dart';

/// 统一图片字节缓存仓：封面 / 漫画页等**可再生**图片字节的磁盘层。
///
/// 设计参照 VenHM `CacheStore`（记账 + LRU + 上限 + 原子写 + 损坏重建）与本项目
/// `BookChapterCache`（双阈值、新者优先、至少保留一条）：
/// - 文件自描述：`<sha1(key)>.bin` = `keyLen(u32 LE) + key(utf8) + bytes`——
///   索引丢失时扫目录重建（能读就能回），不需要单独的索引文件；
/// - 写入原子：`.part → rename`，崩溃不留半截条目；
/// - 双阈值：条数 ≤ [limit]、字节 ≤ [maxBytes]；访问即续期，淘汰最旧；
/// - 只管图片字节，**不碰**下载 / 历史 / 正文缓存（清理由设置页显式触发）。
///
/// 内存记账在首次访问时通过扫描目录建立；之后 put/get 维护条数与字节估算。
class ImageCacheStore {
  ImageCacheStore({
    Future<Directory> Function()? directory,
    int? limit,
    int? maxBytes,
  })  : _directory = directory ?? _defaultDirectory,
        limit = limit ?? defaultLimit,
        maxBytes = maxBytes ?? defaultMaxBytes;

  static const int defaultLimit = 2000;
  static const int defaultMaxBytes = 512 << 20; // 512MB

  static final ImageCacheStore instance = ImageCacheStore();

  final Future<Directory> Function() _directory;

  /// 条数上限；淘汰时新者优先保留，至少保留一条。
  int limit;

  /// 字节上限（记账按「key 头 + 内容」的实际落盘大小计）。
  int maxBytes;

  final Map<String, _ImageCacheEntry> _entries = {};
  Future<void> _putQueue = Future<void>.value();
  bool _loaded = false;

  static Future<Directory> _defaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory(
        '${support.path}${Platform.pathSeparator}image_cache');
  }

  Directory? _resolved;

  Future<Directory> _resolve() async {
    final cached = _resolved;
    if (cached != null) return cached;
    final dir = await _directory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _resolved = dir;
    return dir;
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await _resolve();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.bin')) continue;
        final entry = await _parseFile(entity);
        if (entry != null) {
          _entries[entry.key] = entry;
        } else {
          // 损坏残文件当场清走（损坏重建：能读的回仓，读不了的不留垃圾）。
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 目录不可读：退化为空仓（put 仍会尝试建立）。
      _entries.clear();
    }
    _prune();
  }

  /// 解析自描述文件；损坏（头非法 / 不可读）返回 null。
  Future<_ImageCacheEntry?> _parseFile(File file) async {
    try {
      final bytes = await file.readAsBytes();
      if (bytes.length < 4) return null;
      final view = ByteData.sublistView(bytes);
      final keyLen = view.getUint32(0, Endian.little);
      if (keyLen == 0 || keyLen > 4096 || 4 + keyLen > bytes.length) return null;
      final key = utf8.decode(bytes.sublist(4, 4 + keyLen), allowMalformed: true);
      final stat = await file.stat();
      return _ImageCacheEntry(
        key: key,
        file: file,
        bytes: bytes.length,
        lastAccess: stat.modified,
      );
    } catch (_) {
      return null;
    }
  }

  static String _fileName(String key) =>
      crypto.sha1.convert(utf8.encode(key)).toString();

  /// 取缓存字节（命中即续期）。损坏文件当场删除并视为未命中。
  Future<Uint8List?> get(String key) async {
    await _ensureLoaded();
    final entry = _entries.remove(key);
    if (entry == null) return null;
    try {
      final bytes = await entry.file.readAsBytes();
      final view = ByteData.sublistView(bytes);
      final keyLen = view.getUint32(0, Endian.little);
      if (4 + keyLen > bytes.length) throw const FormatException('bad header');
      final payload = Uint8List.sublistView(bytes, 4 + keyLen);
      // LRU 续期（内存序 + 文件 mtime）。
      _entries[key] = entry..touch();
      return Uint8List.fromList(payload);
    } catch (_) {
      _entries.remove(key);
      try {
        await entry.file.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 写缓存：`.part → rename` 原子落盘 + 记账 + 阈值淘汰。
  /// 写失败静默（缓存失败不影响显示，与既有三级缓存同语义）。
  Future<void> put(String key, List<int> bytes) async {
    final task = _putQueue.then((_) => _doPut(key, bytes));
    _putQueue = task.catchError((Object _) {});
    await task;
  }

  Future<void> _doPut(String key, List<int> bytes) async {
    await _ensureLoaded();
    try {
      final dir = await _resolve();
      final name = _fileName(key);
      final keyBytes = utf8.encode(key);
      final header = BytesBuilder()
        ..add(<int>[
          keyBytes.length & 0xff,
          (keyBytes.length >> 8) & 0xff,
          (keyBytes.length >> 16) & 0xff,
          (keyBytes.length >> 24) & 0xff,
        ])
        ..add(keyBytes);
      final part = File('${dir.path}${Platform.pathSeparator}$name.part');
      await part.writeAsBytes(
        [...header.takeBytes(), ...bytes],
        flush: true,
      );
      final target = File('${dir.path}${Platform.pathSeparator}$name.bin');
      if (await target.exists()) {
        // 同 key 重写：先摘旧记账再落盘。
        _entries.remove(key);
      }
      await part.rename(target.path);
      final stat = await target.stat();
      _entries[key] = _ImageCacheEntry(
        key: key,
        file: target,
        bytes: stat.size,
        lastAccess: DateTime.now(),
      );
      _prune();
    } catch (_) {
      // 磁盘不可用：退化为无磁盘层（调用方内存层仍在）。
    }
  }

  Future<void> remove(String key) async {
    await _ensureLoaded();
    final entry = _entries.remove(key);
    if (entry == null) return;
    try {
      await entry.file.delete();
    } catch (_) {}
  }

  /// 清空全仓（设置页显式触发）；不碰仓外任何文件。
  Future<void> clear() async {
    await _ensureLoaded();
    for (final entry in _entries.values) {
      try {
        await entry.file.delete();
      } catch (_) {}
    }
    _entries.clear();
  }

  /// 当前条数（首次访问前触发一次目录扫描）。
  Future<int> entryCount() async {
    await _ensureLoaded();
    return _entries.length;
  }

  /// 当前总字节（记账口径 = 实际落盘大小）。
  Future<int> totalBytes() async {
    await _ensureLoaded();
    var sum = 0;
    for (final entry in _entries.values) {
      sum += entry.bytes;
    }
    return sum;
  }

  /// 双阈值淘汰：新者优先保留，填到条数/字节上限为止；至少保留一条。
  void _prune() {
    if (_entries.length <= limit && _total() <= maxBytes) return;
    final ordered = _entries.values.toList()
      ..sort((a, b) => b.lastAccess.compareTo(a.lastAccess));
    final keep = <String>{};
    var bytes = 0;
    for (final entry in ordered) {
      if (keep.length >= limit) break;
      if (bytes + entry.bytes > maxBytes && keep.isNotEmpty) break;
      bytes += entry.bytes;
      keep.add(entry.key);
    }
    final dropped =
        _entries.values.where((e) => !keep.contains(e.key)).toList();
    _entries.removeWhere((k, _) => !keep.contains(k));
    for (final entry in dropped) {
      // 删除失败不回滚记账（下次 ensureLoaded 扫描会对齐）。
      unawaited(entry.file.delete().then((_) {}, onError: (Object _) {}));
    }
  }

  int _total() {
    var sum = 0;
    for (final entry in _entries.values) {
      sum += entry.bytes;
    }
    return sum;
  }
}

class _ImageCacheEntry {
  _ImageCacheEntry({
    required this.key,
    required this.file,
    required this.bytes,
    required this.lastAccess,
  });

  final String key;
  final File file;

  /// 实际落盘大小（含 key 头）。
  final int bytes;
  DateTime lastAccess;

  void touch() => lastAccess = DateTime.now();
}
