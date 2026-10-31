import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../store/stores.dart';
import 'aqua_api.dart';

/// 一次下载解析的结果：媒体 URL 与随文件缓存的 CENC 密钥（未加密为空）。
class ResolvedMedia {
  const ResolvedMedia({
    required this.url,
    this.keyHex = '',
    this.expectedBytes = 0,
    this.quality = '',
  });

  final String url;
  final String keyHex;
  final int expectedBytes;

  /// 选中的清晰度标签，随下载记录保存。
  final String quality;
}

/// 在线解析一集：返回流 URL 与密钥。可注入替换用于测试。
typedef MediaResolver = Future<ResolvedMedia> Function(Episode episode);

/// 单集下载执行器：把 url 下载到 path，报告进度；[isCancelled] 变 true 时
/// 应尽快以异常退出（临时文件由服务清理）。可注入替换用于测试。
typedef EpisodeDownloader = Future<int> Function(
  String url,
  String path,
  void Function(int received, int total)? onProgress,
  bool Function() isCancelled,
);

/// 在线解析（默认实现）：按清晰度选流并取 CENC 密钥。
MediaResolver defaultResolver(AquaApi api, String Function() qualityOf) {
  return (ep) async {
    final pb = await api.resolvePlayback(ep.id);
    final usable = pb.playback.streams.where((s) => s.url.isNotEmpty).toList();
    if (usable.isEmpty) {
      throw StateError('没有可用播放流');
    }
    final quality = qualityOf();
    VideoStream pick;
    switch (quality) {
      case 'worst':
        pick = usable.first;
        break;
      case '':
      case 'best':
        pick = usable.last;
        break;
      default:
        pick = usable.lastWhere(
          (s) =>
              s.definition == quality ||
              s.quality == quality ||
              s.codec == quality,
          orElse: () => usable.last,
        );
    }
    return ResolvedMedia(
      url: pick.url,
      keyHex: pb.contentKey?.key ?? '',
      expectedBytes: pick.size,
      quality: pick.definition.isNotEmpty
          ? pick.definition
          : (pick.quality.isEmpty ? '默认' : pick.quality),
    );
  };
}

/// 下载目录迁移结果。
class DownloadMigrationResult {
  const DownloadMigrationResult({
    this.moved = 0,
    this.failed = 0,
    this.bytes = 0,
  });

  final int moved;
  final int failed;
  final int bytes;
}

enum DownloadState { queued, running, paused, done, failed, cancelled }

/// 完整性复核失败：实际字节数与预期不符。
///
/// 少字节（流被服务端提前掐断）保留 `.part` 续传；多字节说明前缀已脏，
/// 调用方丢弃重下。两者都**不计 completed**、不写下载记录。
class _IncompleteDownload implements Exception {
  _IncompleteDownload(this.received, this.expected);

  final int received;
  final int expected;

  @override
  String toString() => '下载不完整：$received/$expected 字节';
}

/// 一集的下载任务状态（UI 订阅服务刷新）。
class DownloadTask {
  DownloadTask(this.episode, this.seriesTitle, this.coverUrl);

  final Episode episode;
  final String seriesTitle;
  final String coverUrl;
  DownloadState state = DownloadState.queued;
  int received = 0;
  int total = 0;
  int retries = 0;
  Object? error;

  double get progress =>
      total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
}

/// 离线下载服务：顺序队列，逐集「在线解析 → 流式下载 .part → 改名 → 记录」。
///
/// 加密分集的密钥按集稳定，与文件一起记进 [DownloadStore]；离线播放时
/// 播放器对本地文件用 decryption_key 解密即可，全程不需要网络。
class DownloadService extends ChangeNotifier {
  DownloadService({
    required this.store,
    required this.baseDir,
    required this.resolver,
    EpisodeDownloader? downloader,
    this.concurrency = 1,
    this.maxRetries = 0,
    this.retryDelay = const Duration(seconds: 2),
  }) : downloader = downloader ?? defaultDownloader;

  final DownloadStore store;
  Directory baseDir;
  final MediaResolver resolver;
  final EpisodeDownloader downloader;

  /// 同时下载数（1–3）。
  int concurrency;

  /// 单集失败自动重试次数（0–3）。
  int maxRetries;

  /// 第 n 次重试前的等待 = retryDelay * n。
  final Duration retryDelay;

  final Map<String, DownloadTask> _tasks = {};
  final List<Episode> _queue = [];
  final Set<String> _cancelledSeries = {};
  final Set<String> _pausedEpisodes = {};
  bool _pumping = false;
  int _active = 0;

  /// 全部任务（含已完成），episodeId → task。
  Map<String, DownloadTask> get tasks => Map.unmodifiable(_tasks);

  DownloadTask? taskOf(String episodeId) => _tasks[episodeId];

  /// 某部剧的活动任务（排队/进行中）数量。
  int activeCount(String seriesId) => _tasks.values
      .where((t) =>
          t.episode.seriesId == seriesId &&
          (t.state == DownloadState.queued || t.state == DownloadState.running))
      .length;

  /// 某部剧的暂停任务数量。
  int pausedCount(String seriesId) => _tasks.values
      .where((t) =>
          t.episode.seriesId == seriesId &&
          t.state == DownloadState.paused)
      .length;

  bool get isBusy => _pumping;

  /// 是否有排队 / 进行中 / 暂停的任务（切换或迁移目录前必须为空）。
  bool get hasActiveTasks => _tasks.values.any((t) =>
      t.state == DownloadState.queued ||
      t.state == DownloadState.running ||
      t.state == DownloadState.paused);

  /// 把一部剧未缓存的集加入队列；返回本次入队的集数。
  int enqueue(Series series, List<Episode> episodes) {
    var added = 0;
    _cancelledSeries.remove(series.id);
    for (final ep in episodes) {
      if (!ep.playable) continue;
      if (store.has(ep.id)) continue;
      _pausedEpisodes.remove(ep.id);
      final existing = _tasks[ep.id];
      if (existing != null &&
          (existing.state == DownloadState.queued ||
              existing.state == DownloadState.running)) {
        continue;
      }
      if (existing != null && existing.state == DownloadState.paused) {
        existing.state = DownloadState.queued;
      } else {
        _tasks[ep.id] = DownloadTask(ep, series.title, series.coverUrl);
      }
      _queue.add(ep);
      added++;
    }
    if (added > 0) {
      notifyListeners();
      unawaited(_pump());
    }
    return added;
  }

  /// 取消一部剧：排队 / 暂停的直接标记，正在下载的由下载循环按集退出。
  void cancelSeries(String seriesId) {
    _cancelledSeries.add(seriesId);
    _queue.removeWhere((ep) => ep.seriesId == seriesId);
    for (final t in _tasks.values) {
      if (t.episode.seriesId != seriesId) continue;
      if (t.state == DownloadState.queued ||
          t.state == DownloadState.paused) {
        t.state = DownloadState.cancelled;
        unawaited(_deletePart(_episodePath(t.episode)));
      }
      _pausedEpisodes.remove(t.episode.id);
    }
    notifyListeners();
  }

  String _episodePath(Episode ep) =>
      '${baseDir.path}${Platform.pathSeparator}${ep.seriesId}'
      '${Platform.pathSeparator}第${_pad3(ep.number)}集.mp4';

  /// 暂停单集：排队中的立即暂停；下载中的在下一个数据块退出，
  /// 已写入的 `.part` 保留，继续时用 Range 续传。
  bool pauseEpisode(String episodeId) {
    final task = _tasks[episodeId];
    if (task == null) return false;
    if (task.state == DownloadState.queued) {
      _queue.removeWhere((ep) => ep.id == episodeId);
      _pausedEpisodes.add(episodeId);
      task.state = DownloadState.paused;
      notifyListeners();
      return true;
    }
    if (task.state == DownloadState.running) {
      _pausedEpisodes.add(episodeId);
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 继续单集：重新入队，`.part` 存在时由下载器从断点续传。
  Future<void> resumeEpisode(String episodeId) async {
    final task = _tasks[episodeId];
    if (task == null || task.state != DownloadState.paused) return;
    _pausedEpisodes.remove(episodeId);
    task.state = DownloadState.queued;
    if (!_queue.any((ep) => ep.id == episodeId)) {
      _queue.add(task.episode);
    }
    notifyListeners();
    unawaited(_pump());
  }

  /// 暂停一部剧的全部排队 / 下载中任务。
  int pauseSeries(String seriesId) {
    var paused = 0;
    for (final task in _tasks.values.toList()) {
      if (task.episode.seriesId != seriesId) continue;
      if (pauseEpisode(task.episode.id)) paused++;
    }
    return paused;
  }

  /// 继续一部剧的全部暂停任务。
  Future<void> resumeSeries(String seriesId) async {
    final ids = <String>[
      for (final task in _tasks.values)
        if (task.episode.seriesId == seriesId &&
            task.state == DownloadState.paused)
          task.episode.id,
    ];
    for (final id in ids) {
      _pausedEpisodes.remove(id);
      final task = _tasks[id];
      if (task == null) continue;
      task.state = DownloadState.queued;
      if (!_queue.any((ep) => ep.id == id)) _queue.add(task.episode);
    }
    if (ids.isNotEmpty) {
      notifyListeners();
      unawaited(_pump());
    }
  }

  /// 重试一部剧全部失败任务；返回重新入队的集数。
  int retryFailed(String seriesId) {
    var count = 0;
    for (final task in _tasks.values.toList()) {
      if (task.episode.seriesId != seriesId ||
          task.state != DownloadState.failed) {
        continue;
      }
      task.state = DownloadState.queued;
      task.error = null;
      task.retries = 0;
      if (!_queue.any((ep) => ep.id == task.episode.id)) {
        _queue.add(task.episode);
      }
      count++;
    }
    if (count > 0) {
      notifyListeners();
      unawaited(_pump());
    }
    return count;
  }

  /// 删除一部剧的缓存文件与记录；返回释放的字节数。
  Future<int> deleteSeries(String seriesId) async {
    cancelSeries(seriesId);
    final eps = store.episodesOf(seriesId);
    var freed = 0;
    for (final e in eps) {
      try {
        final f = File(e.filePath);
        if (await f.exists()) {
          freed += await f.length();
          await f.delete();
        }
      } catch (_) {}
    }
    final dir = Directory('${baseDir.path}${Platform.pathSeparator}$seriesId');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
    await store.removeSeries(seriesId);
    return freed;
  }

  /// 删除单集缓存：文件 + 记录；返回释放的字节数。
  Future<int> deleteEpisode(String episodeId) async {
    final task = _tasks[episodeId];
    if (task != null) {
      _pausedEpisodes.remove(episodeId);
      _queue.removeWhere((ep) => ep.id == episodeId);
      task.state = DownloadState.cancelled;
      await _deletePart(_episodePath(task.episode));
    }
    final e = store.entryOf(episodeId);
    if (e == null) return 0;
    var freed = 0;
    try {
      final f = File(e.filePath);
      if (await f.exists()) {
        freed = await f.length();
        await f.delete();
      }
    } catch (_) {}
    await store.removeEpisode(episodeId);
    return freed;
  }

  /// 播放源：已缓存返回本地记录；未缓存返回 null（调用方在线解析）。
  DownloadEntry? localEntryOf(String episodeId) => store.entryOf(episodeId);

  /// 目录可写探测（创建目录 + 写删探针文件）。
  static Future<bool> ensureWritable(Directory dir) async {
    try {
      await dir.create(recursive: true);
      final probe = File(
          '${dir.path}${Platform.pathSeparator}.aquan-write-test-$pid-${DateTime.now().microsecondsSinceEpoch}');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 仅切换下载位置：旧缓存保留在原路径（记录里是绝对路径，仍可播放）。
  Future<void> setBaseDir(Directory dir) async {
    if (hasActiveTasks) throw StateError('有下载任务正在进行，请完成后再切换目录');
    if (_conflictsWithBase(dir)) {
      throw StateError('不能选择当前下载目录本身、子目录或上级目录');
    }
    await dir.create(recursive: true);
    baseDir = dir;
  }

  bool _conflictsWithBase(Directory dir) {
    final a = dir.absolute.path.toLowerCase();
    final b = baseDir.absolute.path.toLowerCase();
    final sep = Platform.pathSeparator;
    return a == b || a.startsWith('$b$sep') || b.startsWith('$a$sep');
  }

  /// 迁移已有缓存到新目录：逐集复制 + 大小校验 + 删除源文件 + 更新记录。
  /// 单集失败不中断，失败的保留原位置。
  Future<DownloadMigrationResult> migrateDownloadsTo(Directory target) async {
    if (hasActiveTasks) {
      throw StateError('有下载任务正在进行，请完成后再迁移目录');
    }
    if (_conflictsWithBase(target)) {
      throw StateError('不能选择当前下载目录本身、子目录或上级目录');
    }
    await target.create(recursive: true);
    final oldBase = baseDir;
    var moved = 0;
    var failed = 0;
    var bytes = 0;
    for (final series in store.seriesList) {
      for (final entry in series.episodes) {
        final source = File(entry.filePath);
        if (!await source.exists()) continue;
        final name = source.uri.pathSegments.last;
        final targetDir = Directory(
            '${target.path}${Platform.pathSeparator}${entry.seriesId}');
        final targetFile = File(
            '${targetDir.path}${Platform.pathSeparator}$name');
        try {
          await targetDir.create(recursive: true);
          final sourceBytes = await source.length();
          await source.copy(targetFile.path);
          final targetBytes = await targetFile.length();
          if (sourceBytes != targetBytes) {
            try {
              await targetFile.delete();
            } catch (_) {}
            throw StateError('大小校验失败');
          }
          await source.delete();
          await store.updateFilePath(entry.episodeId, targetFile.path);
          moved++;
          bytes += targetBytes;
        } catch (_) {
          failed++;
        }
      }
    }
    baseDir = target;
    await _removeEmptySeriesDirs(oldBase);
    return DownloadMigrationResult(moved: moved, failed: failed, bytes: bytes);
  }

  Future<void> _removeEmptySeriesDirs(Directory dir) async {
    try {
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! Directory) continue;
        try {
          if (await entity.list().isEmpty) await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_queue.isNotEmpty || _active > 0) {
        while (_active < concurrency && _queue.isNotEmpty) {
          final ep = _queue.removeAt(0);
          if (_cancelledSeries.contains(ep.seriesId)) {
            final task = _tasks[ep.id];
            if (task != null) task.state = DownloadState.cancelled;
            notifyListeners();
            continue;
          }
          _active++;
          unawaited(_runTask(ep).whenComplete(() {
            _active--;
            notifyListeners();
          }));
        }
        if (_active == 0 && _queue.isEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      _pumping = false;
      notifyListeners();
      // 暂停后立即继续 / 排队期间追加任务：保证队列不会停在原地。
      if (_queue.isNotEmpty) unawaited(_pump());
    }
  }

  Future<void> _runTask(Episode ep) async {
    final task = _tasks[ep.id];
    if (task == null) return;
    if (_cancelledSeries.contains(ep.seriesId)) {
      task.state = DownloadState.cancelled;
      notifyListeners();
      return;
    }
    task.state = DownloadState.running;
    notifyListeners();
    final dir =
        Directory('${baseDir.path}${Platform.pathSeparator}${ep.seriesId}');
    final path =
        '${dir.path}${Platform.pathSeparator}第${_pad3(ep.number)}集.mp4';
    try {
      final resolved = await resolver(ep);
      await dir.create(recursive: true);
      task.total = resolved.expectedBytes > 0 ? resolved.expectedBytes : 0;
      final size = await downloader(
        resolved.url,
        '$path.part',
        (received, total) {
          task.received = received;
          task.total = total;
          notifyListeners();
        },
        () =>
            _cancelledSeries.contains(ep.seriesId) ||
            _pausedEpisodes.contains(ep.id),
      );
      if (_cancelledSeries.contains(ep.seriesId)) {
        task.state = DownloadState.cancelled;
        await _deletePart(path);
      } else if (task.state == DownloadState.cancelled) {
        // ensureCurrent 守卫：单集删除已把任务标记取消（不进 _cancelledSeries），
        // 不得落盘或写下载记录，否则留下指向已删文件的孤儿记录。
        await _deletePart(path);
      } else {
        // 完整性复核：预期大小已知且不符 → 不改名不记录。
        final expected = resolved.expectedBytes;
        if (expected > 0 && size < expected) {
          throw _IncompleteDownload(size, expected);
        }
        if (expected > 0 && size > expected) {
          await _deletePart(path);
          throw _IncompleteDownload(size, expected);
        }
        // 下载已完整结束：即使暂停标记恰好在此刻到达也直接落盘。
        _pausedEpisodes.remove(ep.id);
        await File('$path.part').rename(path);
        await store.record(DownloadEntry(
          seriesId: ep.seriesId,
          seriesTitle: task.seriesTitle,
          coverUrl: task.coverUrl,
          episodeId: ep.id,
          number: ep.number,
          title: ep.title,
          filePath: path,
          sizeBytes: size,
          keyHex: resolved.keyHex,
          quality: resolved.quality,
          downloadedAt: DateTime.now(),
        ));
        task.state = DownloadState.done;
        task.received = task.total = size;
        task.retries = 0;
      }
    } catch (e) {
      final cancelled = _cancelledSeries.contains(ep.seriesId);
      final paused = _pausedEpisodes.contains(ep.id);
      if (cancelled) {
        task.state = DownloadState.cancelled;
        task.error = e;
        await _deletePart(path);
      } else if (paused || task.state == DownloadState.paused) {
        task.state = DownloadState.paused;
      } else if (task.state == DownloadState.queued) {
        // 用户已点继续：保留 .part，由调度器重新拉起续传。
      } else if (task.state == DownloadState.cancelled) {
        await _deletePart(path);
      } else if (e is _IncompleteDownload) {
        // 少字节：保留 .part 续传重试（多字节已在落地前删除 .part）。
        task.error = e;
        if (task.retries < maxRetries) {
          task.retries++;
          task.state = DownloadState.queued;
          notifyListeners();
          await Future<void>.delayed(retryDelay * task.retries);
          if (_cancelledSeries.contains(ep.seriesId)) {
            task.state = DownloadState.cancelled;
            await _deletePart(path);
          } else if (_pausedEpisodes.contains(ep.id)) {
            task.state = DownloadState.paused;
          } else {
            _queue.add(ep);
          }
        } else {
          // 重试预算耗尽：标记失败但保留 .part，用户「重试失败」时续传。
          task.state = DownloadState.failed;
        }
      } else {
        await _deletePart(path);
        if (task.retries < maxRetries) {
          task.retries++;
          task.state = DownloadState.queued;
          task.error = e;
          notifyListeners();
          await Future<void>.delayed(retryDelay * task.retries);
          if (_cancelledSeries.contains(ep.seriesId)) {
            task.state = DownloadState.cancelled;
            await _deletePart(path);
          } else if (_pausedEpisodes.contains(ep.id)) {
            task.state = DownloadState.paused;
          } else {
            _queue.add(ep);
          }
        } else {
          task.state = DownloadState.failed;
          task.error = e;
        }
      }
    }
    notifyListeners();
  }

  Future<void> _deletePart(String path) async {
    try {
      final part = File('$path.part');
      if (await part.exists()) await part.delete();
    } catch (_) {}
  }
}

/// 默认下载执行器：流式写 `.part`，支持暂停/继续的 Range 断点续传，
/// 以及可选的全局限速（[maxBytesPerSecond]，0 = 不限速）。
Future<int> defaultDownloader(
  String url,
  String path,
  void Function(int received, int total)? onProgress,
  bool Function() isCancelled, {
  int maxBytesPerSecond = 0,
}) async {
  final client = http.Client();
  final part = File(path);
  try {
    var start = await part.exists() ? await part.length() : 0;
    http.StreamedResponse response;
    while (true) {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'aquan-duanju';
      if (start > 0) request.headers['Range'] = 'bytes=$start-';
      response = await client.send(request);
      if (start > 0 && response.statusCode == 416) {
        // .part 比服务端文件还大（源换了 / 文件变小）：丢弃重下。
        try {
          await part.delete();
        } catch (_) {}
        start = 0;
        continue;
      }
      if (start > 0 && response.statusCode == 206) {
        // 续传对齐校验：Content-Range 起点必须等于续传起点，否则源文件
        // 已变（换源/热更新），续传会拼出损坏文件 → 丢弃 .part 重下。
        // 无可解析 Content-Range 的 206 按现状容错（无法校验则信任）。
        String? contentRange;
        response.headers.forEach((k, v) {
          if (k.toLowerCase() == 'content-range') contentRange = v;
        });
        final m =
            RegExp(r'bytes\s+(\d+)').firstMatch(contentRange ?? '');
        final rangeStart = m == null ? null : int.tryParse(m.group(1)!);
        if (rangeStart != null && rangeStart != start) {
          try {
            await part.delete();
          } catch (_) {}
          start = 0;
          continue;
        }
      }
      break;
    }
    if (response.statusCode != 200 && response.statusCode != 206) {
      throw HttpException('下载失败：HTTP ${response.statusCode}');
    }
    // 服务端忽略了 Range：从头写入。
    if (start > 0 && response.statusCode == 200) start = 0;
    final remaining = response.contentLength ?? 0;
    final total = remaining + (response.statusCode == 206 ? start : 0);
    final sink = part.openWrite(
      mode: start > 0 ? FileMode.append : FileMode.write,
    );
    var received = start;
    final stopwatch = Stopwatch()..start();
    try {
      await for (final chunk in response.stream) {
        if (isCancelled()) {
          throw StateError('cancelled');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
        if (maxBytesPerSecond > 0) {
          // 简单令牌桶：按已用时允许的字节数阻塞，保留 1 秒初始突发。
          final payload = received - start;
          final allowed = maxBytesPerSecond *
                  stopwatch.elapsedMilliseconds /
                  1000 +
              maxBytesPerSecond;
          if (payload > allowed) {
            final waitMs =
                ((payload - allowed) * 1000 / maxBytesPerSecond).ceil();
            await Future<void>.delayed(
                Duration(milliseconds: waitMs.clamp(10, 1000)));
          }
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return received;
  } finally {
    client.close();
  }
}

String _pad3(int n) => n.toString().padLeft(3, '0');
