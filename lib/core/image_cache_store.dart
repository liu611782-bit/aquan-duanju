import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'image_cache_index.dart';

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
/// 内存记账优先从 `aquan_image_index.json` 恢复（冷启动零扫盘）；索引缺失 /
/// 损坏 / 版本不符才回退「只读 4 字节头 + key」扫盘，并立即重建索引。
/// 索引只记 `size/atime/fetchedAt`，落盘字节格式与淘汰规则完全不变。
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

  /// 持久化索引（冷启动免扫盘）。null = 尚未加载 / 目录不可用。
  ImageCacheIndex? _index;
  Timer? _indexSaveTimer;
  Future<void> _indexSaveQueue = Future<void>.value();

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
      final index = await ImageCacheIndex.load(dir);
      _index = index;
      if (!index.needsRescan) {
        // 索引有效：直接恢复内存记账，不列目录、不逐文件 stat。
        for (final e in index.values) {
          final file = File(
              '${dir.path}${Platform.pathSeparator}${_fileName(e.key)}.bin');
          _entries[e.key] = _ImageCacheEntry(
            key: e.key,
            file: file,
            bytes: e.size,
            lastAccess: e.atime,
            fetchedAt: e.fetchedAt,
          );
        }
      } else {
        // 索引缺失/损坏/版本不符：回退既有「只读 4 字节头 + key」扫盘。
        await _rescan(dir);
        for (final entry in _entries.values) {
          index.upsert(
            entry.key,
            size: entry.bytes,
            atime: entry.lastAccess,
            // 旧文件里没有 fetchedAt，用文件 mtime 作近似（重启后 TTL 仍有效）。
            fetchedAt: entry.fetchedAt ?? entry.lastAccess,
          );
        }
        _scheduleIndexSave();
      }
    } catch (_) {
      // 目录不可读：退化为空仓（put 仍会尝试建立）。
      _entries.clear();
    }
    _prune();
  }

  /// 回退扫盘：**只读** 4 字节长度 + key，绝不 `readAsBytes()` 整文件。
  Future<void> _rescan(Directory dir) async {
    try {
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
  }

  /// 解析自描述文件；损坏（头非法 / 不可读）返回 null。
  ///
  /// **只读头部**（4 字节长度 + key），不要 `readAsBytes()` 读整个文件：
  /// 首次访问要扫描整个缓存目录，几千个文件全量读入会让首图卡住好几秒。
  Future<_ImageCacheEntry?> _parseFile(File file) async {
    RandomAccessFile? raf;
    try {
      raf = await file.open();
      final head = await raf.read(4);
      if (head.length < 4) return null;
      final keyLen =
          ByteData.sublistView(Uint8List.fromList(head)).getUint32(0, Endian.little);
      if (keyLen == 0 || keyLen > 4096) return null;
      final keyBytes = await raf.read(keyLen);
      if (keyBytes.length < keyLen) return null;
      final key = utf8.decode(keyBytes, allowMalformed: true);
      final stat = await file.stat();
      return _ImageCacheEntry(
        key: key,
        file: file,
        bytes: stat.size,
        lastAccess: stat.modified,
        fetchedAt: stat.modified,
      );
    } catch (_) {
      return null;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 与索引键同源，保证 `<sha1(key)>.bin` 和索引记录一一对应。
  static String _fileName(String key) => ImageCacheIndex.hashOf(key);

  /// 取缓存字节（命中即续期）。损坏文件当场删除并视为未命中。
  ///
  /// 过期项**仍然立即返回旧字节**（TTL 只驱动后台刷新，不阻塞出图）；
  /// 是否需要刷新由调用方通过 [isExpired] 判断。
  Future<Uint8List?> get(String key) async {
    await _ensureLoaded();
    final entry = _entries.remove(key);
    if (entry == null) return null;
    try {
      final bytes = await entry.file.readAsBytes();
      final view = ByteData.sublistView(bytes);
      final keyLen = view.getUint32(0, Endian.little);
      if (4 + keyLen > bytes.length) throw const FormatException('bad header');
      // 直接返回视图，省掉一次整图拷贝（解码器只读，不需要可变副本）。
      final payload = Uint8List.sublistView(bytes, 4 + keyLen);
      // LRU 续期（内存序 + 文件 mtime）。
      _entries[key] = entry..touch();
      // 访问只更新索引里的 atime；TTL 以 fetchedAt 为准，访问不延长有效期。
      // 落盘合并到下一次结构性写入，避免每次 get 都重写整个索引。
      _index?.touch(key, atime: entry.lastAccess);
      return payload;
    } catch (_) {
      _entries.remove(key);
      _index?.remove(key);
      _scheduleIndexSave();
      try {
        await entry.file.delete();
      } catch (_) {}
      return null;
    }
  }

  /// 该 key 是否已过期（供调用方决定是否后台刷新）。
  ///
  /// 无索引 / 无记录（例如老版本写的字节、纯内存缓存）一律返回 false：
  /// 没有 fetchedAt 就不擅自发起刷新，避免首屏重复下载。
  Future<bool> isExpired(String key) async {
    try {
      await _ensureLoaded();
      return _index?.isStale(key) ?? false;
    } catch (_) {
      return false;
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
      final now = DateTime.now();
      _entries[key] = _ImageCacheEntry(
        key: key,
        file: target,
        bytes: stat.size,
        lastAccess: now,
        fetchedAt: now,
      );
      // put 既写内容也刷新 fetchedAt（TTL 从最新一次抓取起算）。
      _index?.upsert(key, size: stat.size, atime: now, fetchedAt: now);
      _scheduleIndexSave();
      _prune();
    } catch (_) {
      // 磁盘不可用：退化为无磁盘层（调用方内存层仍在）。
    }
  }

  Future<void> remove(String key) async {
    await _ensureLoaded();
    final entry = _entries.remove(key);
    if (entry == null) return;
    _index?.remove(key);
    try {
      await entry.file.delete();
    } catch (_) {}
    // 结构性变更：调用返回时索引已同步落盘。
    await flushIndex();
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
    _index?.clear();
    await flushIndex();
  }

  /// 当前条数（首次访问前触发一次索引加载 / 回退扫盘）。
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
      // 淘汰同步维护索引，避免下次启动又从索引里「复活」已删条目。
      _index?.remove(entry.key);
      // 删除失败不回滚记账（下次 ensureLoaded 扫描会对齐）。
      unawaited(entry.file.delete().then((_) {}, onError: (Object _) {}));
    }
    if (dropped.isNotEmpty) _scheduleIndexSave();
  }

  int _total() {
    var sum = 0;
    for (final entry in _entries.values) {
      sum += entry.bytes;
    }
    return sum;
  }

  /// 合并 250ms 内的多次索引变更，只做一次原子写；不阻塞 put / get 返回。
  void _scheduleIndexSave() {
    _indexSaveTimer?.cancel();
    _indexSaveTimer = Timer(const Duration(milliseconds: 250), () {
      _indexSaveTimer = null;
      unawaited(_flushIndex());
    });
  }

  Future<void> _flushIndex() {
    final dir = _resolved;
    final index = _index;
    if (dir == null || index == null) return Future<void>.value();
    // 串行化，且执行时才读 index 的当前快照 → 自然合并排队期间的变更。
    _indexSaveQueue = _indexSaveQueue
        .then<void>((_) => index.save(dir))
        .catchError((Object _) {});
    return _indexSaveQueue;
  }

  /// 等待索引落盘完成（测试 / 退出前显式同步用）。
  Future<void> flushIndex() async {
    _indexSaveTimer?.cancel();
    _indexSaveTimer = null;
    await _flushIndex();
  }
}

class _ImageCacheEntry {
  _ImageCacheEntry({
    required this.key,
    required this.file,
    required this.bytes,
    required this.lastAccess,
    this.fetchedAt,
  });

  final String key;
  final File file;

  /// 实际落盘大小（含 key 头）。
  final int bytes;
  DateTime lastAccess;

  /// 最近一次抓取时间（索引重建时用文件 mtime 近似）。
  DateTime? fetchedAt;

  void touch() => lastAccess = DateTime.now();
}
