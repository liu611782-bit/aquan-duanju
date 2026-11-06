import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

/// 持久化索引里的单条记录。
///
/// 键是 `sha1(key)`（与 `<sha1>.bin` 文件名一致），值里额外携带原始 [key]：
/// sha1 不可逆，只有存下原始 key 才能在启动时零 IO 重建内存索引，真正做到
/// 「冷启动不扫盘」。`size` 用于双阈值淘汰记账，`atime` 用于 LRU，
/// `fetchedAt` 用于 TTL 判定（[ImageCacheStore] 的 put 会刷新它）。
class ImageIndexEntry {
  const ImageIndexEntry({
    required this.key,
    required this.size,
    required this.atime,
    required this.fetchedAt,
  });

  final String key;
  final int size;
  final DateTime atime;
  final DateTime fetchedAt;

  ImageIndexEntry copyWith({
    int? size,
    DateTime? atime,
    DateTime? fetchedAt,
  }) =>
      ImageIndexEntry(
        key: key,
        size: size ?? this.size,
        atime: atime ?? this.atime,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'key': key,
        'size': size,
        'atime': atime.toIso8601String(),
        'fetchedAt': fetchedAt.toIso8601String(),
      };

  /// 解析单条；缺字段 / 类型不符 / 时间非法一律返回 null（跳过该条）。
  static ImageIndexEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final size = raw['size'];
    final atime = raw['atime'];
    final fetchedAt = raw['fetchedAt'];
    if (key is! String || key.isEmpty || size is! int || size < 0) return null;
    final a = atime is String ? DateTime.tryParse(atime) : null;
    final f = fetchedAt is String ? DateTime.tryParse(fetchedAt) : null;
    if (a == null || f == null) return null;
    return ImageIndexEntry(key: key, size: size, atime: a, fetchedAt: f);
  }
}

/// 磁盘索引 `aquan_image_index.json`。
///
/// - 原子写：`.part → rename`，写失败静默（索引只是加速器，缓存数据不丢）；
/// - 缺失 / 损坏 / 版本不符：返回空索引且 [needsRescan] = true，让调用方
///   回退「只读 4 字节头 + key」扫盘重建（见 image-cache-contract.md）；
/// - TTL 默认 7 天，[isExpired] 可注入 [now] 便于测试边界。
class ImageCacheIndex {
  ImageCacheIndex({
    Map<String, ImageIndexEntry>? entries,
    this.needsRescan = false,
  }) : _entries = entries ?? <String, ImageIndexEntry>{};

  static const int version = 1;
  static const String fileName = 'aquan_image_index.json';
  static const Duration defaultTtl = Duration(days: 7);

  final Map<String, ImageIndexEntry> _entries;

  /// true = 索引不可用，调用方须回退扫盘并用 [upsert] + [save] 重建。
  bool needsRescan;

  int get length => _entries.length;
  bool get isEmpty => _entries.isEmpty;
  Iterable<ImageIndexEntry> get values => _entries.values;

  /// 与 `<sha1>.bin` 落盘文件名同源。
  static String hashOf(String key) =>
      crypto.sha1.convert(utf8.encode(key)).toString();

  /// 恰好满 [ttl] 即视为过期（`>=` 边界）。
  static bool isExpired(
    DateTime fetchedAt, {
    DateTime? now,
    Duration ttl = defaultTtl,
  }) {
    final at = now ?? DateTime.now();
    return !at.isBefore(fetchedAt.add(ttl));
  }

  /// 按 key 判过期；无记录视为已过期（需要抓取）。
  bool isStale(String key, {DateTime? now, Duration ttl = defaultTtl}) {
    final e = lookup(key);
    return e == null || isExpired(e.fetchedAt, now: now, ttl: ttl);
  }

  ImageIndexEntry? lookup(String key) => _entries[hashOf(key)];

  /// 写入 / 更新一条。未传 [fetchedAt] 时记为「刚抓取」。
  void upsert(
    String key, {
    required int size,
    DateTime? atime,
    DateTime? fetchedAt,
  }) {
    final now = DateTime.now();
    _entries[hashOf(key)] = ImageIndexEntry(
      key: key,
      size: size,
      atime: atime ?? now,
      fetchedAt: fetchedAt ?? now,
    );
  }

  /// 访问续期：只动 [ImageIndexEntry.atime]，保留 [ImageIndexEntry.fetchedAt]
  /// （TTL 以「抓取时间」为准，访问不能延长有效期）。
  void touch(String key, {DateTime? atime}) {
    final hash = hashOf(key);
    final old = _entries[hash];
    if (old == null) return;
    _entries[hash] = old.copyWith(atime: atime ?? DateTime.now());
  }

  void remove(String key) => _entries.remove(hashOf(key));

  void clear() => _entries.clear();

  /// 从仓目录加载；任何异常 / 版本不符 / 结构损坏都删掉坏索引并返回空。
  static Future<ImageCacheIndex> load(Directory dir) async {
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    try {
      if (!await file.exists()) {
        return ImageCacheIndex(needsRescan: true);
      }
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map || decoded['version'] != version) {
        return await _corrupt(file);
      }
      final rawEntries = decoded['entries'];
      if (rawEntries is! Map) return await _corrupt(file);
      final entries = <String, ImageIndexEntry>{};
      for (final item in rawEntries.entries) {
        final hash = item.key;
        if (hash is! String) continue;
        final parsed = ImageIndexEntry.fromJson(item.value);
        // 键与内容里的 key 必须匹配，防止损坏数据把错图映射到别名下。
        if (parsed != null && hashOf(parsed.key) == hash) {
          entries[hash] = parsed;
        }
      }
      return ImageCacheIndex(entries: entries);
    } catch (_) {
      return await _corrupt(file);
    }
  }

  static Future<ImageCacheIndex> _corrupt(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    return ImageCacheIndex(needsRescan: true);
  }

  /// 原子写（`.part → rename`）；先删旧文件以兼容 Windows 的 rename 语义。
  /// 失败静默：下次启动会 needsRescan 回退扫盘，缓存数据本身不丢。
  Future<void> save(Directory dir) async {
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    final part = File('${file.path}.part');
    try {
      final payload = jsonEncode(<String, Object?>{
        'version': version,
        'entries':
            _entries.map((k, v) => MapEntry<String, Object?>(k, v.toJson())),
      });
      await part.writeAsString(payload, flush: true);
      if (await file.exists()) await file.delete();
      await part.rename(file.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
    }
  }
}
