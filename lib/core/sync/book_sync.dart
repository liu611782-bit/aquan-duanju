/// 书库云同步：把「本地书 + 阅读进度 + 书签 + 划线」打成一个 zip 传远端，
/// 恢复时**按记录级合并**（新者胜 / id 去重），不整包覆盖。
///
/// 冲突策略（手动、可预期）：
/// - 进度：同一本书取 `updated_at` 较新的一条；
/// - 书签/划线：按 `id` 取并集（同 id 取较新 `created_at`）；
/// - 本地书文件：只补缺失的 `book_library/<id>/`，绝不覆盖已有文件。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../store/stores.dart';
import 'remote_store.dart';

export 'merge.dart';

/// 同步配置（WebDAV / S3 二选一）。
class SyncConfig {
  const SyncConfig({
    this.type = SyncBackendType.webdav,
    this.url = '',
    this.username = '',
    this.password = '',
    this.bucket = '',
    this.region = 'us-east-1',
    this.prefix = 'aquan/',
  });

  final SyncBackendType type;
  final String url;
  final String username;
  final String password;
  final String bucket;
  final String region;
  final String prefix;

  bool get isConfigured =>
      type == SyncBackendType.webdav
          ? url.trim().isNotEmpty
          : url.trim().isNotEmpty && bucket.trim().isNotEmpty;

  SyncConfig copyWith({
    SyncBackendType? type,
    String? url,
    String? username,
    String? password,
    String? bucket,
    String? region,
    String? prefix,
  }) =>
      SyncConfig(
        type: type ?? this.type,
        url: url ?? this.url,
        username: username ?? this.username,
        password: password ?? this.password,
        bucket: bucket ?? this.bucket,
        region: region ?? this.region,
        prefix: prefix ?? this.prefix,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'url': url,
        'username': username,
        'password': password,
        'bucket': bucket,
        'region': region,
        'prefix': prefix,
      };

  factory SyncConfig.fromJson(Map<String, dynamic> j) => SyncConfig(
        type: SyncBackendType.values
                .where((t) => t.name == j['type'])
                .firstOrNull ??
            SyncBackendType.webdav,
        url: j['url']?.toString() ?? '',
        username: j['username']?.toString() ?? '',
        password: j['password']?.toString() ?? '',
        bucket: j['bucket']?.toString() ?? '',
        region: j['region']?.toString() ?? 'us-east-1',
        prefix: j['prefix']?.toString() ?? 'aquan/',
      );

  RemoteStore buildStore() => switch (type) {
        SyncBackendType.webdav => WebDavStore(
            baseUrl: url,
            username: username,
            password: password,
          ),
        SyncBackendType.s3 => S3Store(
            endpoint: url,
            bucket: bucket,
            accessKey: username,
            secretKey: password,
            region: region,
            prefix: prefix,
          ),
      };
}

enum SyncBackendType {
  webdav('WebDAV'),
  s3('S3 兼容');

  const SyncBackendType(this.label);

  final String label;
}

/// 配置持久化。
class SyncConfigStore {
  SyncConfigStore({this.prefs});

  static const String prefsKey = 'sync.config.v1';

  SharedPreferences? prefs;

  Future<SyncConfig> load() async {
    final prefs = this.prefs ??= await SharedPreferences.getInstance();
    final raw = prefs.getString(prefsKey);
    if (raw == null || raw.isEmpty) return const SyncConfig();
    try {
      final json = jsonDecode(raw);
      if (json is Map<String, dynamic>) return SyncConfig.fromJson(json);
    } catch (_) {
      // 坏配置按未配置处理。
    }
    return const SyncConfig();
  }

  Future<void> save(SyncConfig config) async {
    final prefs = this.prefs ??= await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(config.toJson()));
  }
}

/// 合并结果。
class SyncMergeReport {
  const SyncMergeReport({
    this.progressUpdated = 0,
    this.bookmarksAdded = 0,
    this.markingsAdded = 0,
    this.booksAdded = 0,
    this.written = const [],
  });

  final int progressUpdated;
  final int bookmarksAdded;
  final int markingsAdded;
  final int booksAdded;

  /// 合并发生变化的本地文件名（JSON 经 Store 队列合并后内存即时生效）。
  final List<String> written;

  bool get changed => written.isNotEmpty || booksAdded > 0;

  String get summary {
    if (!changed) return '远端与本地一致，无需变更';
    final parts = <String>[
      if (progressUpdated > 0) '进度 $progressUpdated 条',
      if (bookmarksAdded > 0) '书签 +$bookmarksAdded',
      if (markingsAdded > 0) '划线 +$markingsAdded',
      if (booksAdded > 0) '本地书 +$booksAdded 本',
    ];
    // 三个 JSON 状态文件恢复后经 Store 即时生效并通知刷新，
    // 媒体文件（books/）落盘即可用——无需重启。
    return '已合并：${parts.join('，')}';
  }
}

/// 备份/恢复服务。
class BookSyncService {
  BookSyncService({
    required this.supportDir,
    required this.libraryDir,
    required this.store,
    required this.progress,
    required this.bookmarks,
    required this.markings,
  });

  /// 应用数据目录（含 `aquan_reading.json` 等）。
  final Directory supportDir;

  /// 本地书库目录（`book_library`）。
  final Directory libraryDir;

  final RemoteStore store;

  /// 三个阅读状态库（11-08-book-sync-race）：恢复合并改走各库写队列
  /// （`mergeRemoteJson`），不再对 JSON 文件队列外直写。
  final ReadingProgressStore progress;
  final BookmarkStore bookmarks;
  final MarkingStore markings;

  static const String progressFile = 'aquan_reading.json';
  static const String bookmarksFile = 'aquan_bookmarks.json';
  static const String markingsFile = 'aquan_markings.json';

  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// 打包并上传；返回远端路径。
  Future<String> backup() async {
    final files = <String, List<int>>{};
    for (final name in [progressFile, bookmarksFile, markingsFile]) {
      final file = File('${supportDir.path}/$name');
      if (file.existsSync()) files[name] = await file.readAsBytes();
    }
    if (libraryDir.existsSync()) {
      for (final dir in libraryDir.listSync().whereType<Directory>()) {
        final id = dir.path.replaceAll('\\', '/').split('/').last;
        final meta = File('${dir.path}/meta.json');
        if (meta.existsSync()) {
          files['books/$id/meta.json'] = await meta.readAsBytes();
        }
        for (final entity in dir.listSync()) {
          if (entity is! File) continue;
          final name = entity.path.replaceAll('\\', '/').split('/').last;
          if (!name.startsWith('book.') && name != 'cover.jpg') continue;
          files['books/$id/$name'] = await entity.readAsBytes();
        }
      }
    }
    if (files.isEmpty) {
      throw const RemoteStoreException('本地还没有可备份的数据');
    }
    final remotePath = 'backup-${_stamp()}.zip';
    await store.put(remotePath, buildBundle(files));
    return remotePath;
  }

  /// 拉最新备份并合并；返回合并报告。
  Future<SyncMergeReport> restore() async {
    final objects = await store.list('');
    final backups = objects.where((o) => o.path.toLowerCase().endsWith('.zip')).toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    if (backups.isEmpty) {
      throw const RemoteStoreException('远端没有备份文件');
    }
    final bytes = await store.get(backups.first.path);
    if (bytes == null) {
      throw RemoteStoreException('下载备份失败：${backups.first.path}');
    }
    return mergeBundle(bytes);
  }

  /// 合并一个备份包（恢复与测试共用）。
  Future<SyncMergeReport> mergeBundle(Uint8List zipBytes) async {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(zipBytes);
    } catch (e) {
      throw RemoteStoreException('备份包损坏：$e');
    }

    var progressUpdated = 0;
    var bookmarksAdded = 0;
    var markingsAdded = 0;
    var booksAdded = 0;
    var booksSkipped = 0;
    final written = <String>[];
    // 本轮新建的书目录：同一本书的多个文件只判一次「是否已存在」，否则
    // 写完 meta.json 后 book.txt 会被当成「已存在」直接跳过。
    final created = <String>{};

    int? mergedCount;

    for (final file in archive.files) {
      if (!file.isFile) continue;
      final name = file.name.replaceAll('\\', '/');
      if (name.startsWith('books/')) {
        // 只补缺失的本地书目录，绝不覆盖。
        final parts = name.split('/');
        if (parts.length < 3) continue;
        final id = parts[1];
        final target = Directory('${libraryDir.path}/$id');
        final existedBefore = target.existsSync() && !created.contains(id);
        if (existedBefore) {
          booksSkipped++;
          continue;
        }
        if (!created.contains(id)) {
          await target.create(recursive: true);
          created.add(id);
        }
        final targetFile = File('${target.path}/${parts[2]}');
        await targetFile.writeAsBytes(file.content, flush: true);
        if (parts[2] == 'meta.json') booksAdded++;
        continue;
      }
      if (name == progressFile || name == bookmarksFile || name == markingsFile) {
        final remoteText = utf8.decode(file.content, allowMalformed: true);
        // 记录级合并走 Store 写队列（11-08-book-sync-race）：以各库内存态为
        // local 基线入队合并并同步刷新内存，不再对 JSON 文件队列外直写——
        // 与常规写者（阅读进度落盘、加书签/划线）并发时不再互相覆盖丢键，
        // 合并结果即时生效。
        final changedCount = name == progressFile
            ? await progress.mergeRemoteJson(remoteText)
            : name == bookmarksFile
                ? await bookmarks.mergeRemoteJson(remoteText)
                : await markings.mergeRemoteJson(remoteText);
        if (changedCount > 0) {
          written.add(name);
          if (name == progressFile) {
            progressUpdated = changedCount;
          } else if (name == bookmarksFile) {
            bookmarksAdded = changedCount;
          } else {
            markingsAdded = changedCount;
          }
        }
        mergedCount = (mergedCount ?? 0) + changedCount;
      }
    }
    if (mergedCount == null && booksAdded == 0 && booksSkipped == 0) {
      throw const RemoteStoreException('备份包里没有可识别的数据');
    }
    return SyncMergeReport(
      progressUpdated: progressUpdated,
      bookmarksAdded: bookmarksAdded,
      markingsAdded: markingsAdded,
      booksAdded: booksAdded,
      written: written,
    );
  }
}

/// 打包（纯函数，测试可直接断言解包结果）。
Uint8List buildBundle(Map<String, List<int>> files) {
  final archive = Archive();
  for (final entry in files.entries) {
    final data = entry.value;
    archive.addFile(ArchiveFile(entry.key, data.length, data));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
