import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 单条 MP4 导出任务状态。
enum Mp4TaskState { queued, running, done, failed, cancelled }

/// 播放页「下载(MP4)」触发的导出任务。
class Mp4DownloadTask {
  Mp4DownloadTask({
    required this.id,
    required this.title,
    required this.m3u8Url,
    this.headers = const {},
  });

  final String id;
  final String title;
  final String m3u8Url;
  final Map<String, String> headers;

  Mp4TaskState state = Mp4TaskState.queued;
  double progress = 0.0;
  String message = '';
  String? error;
  String? outputPath;
  DateTime? startedAt;
  DateTime? finishedAt;
  /// 是否已写入系统相册。
    /// 用户自定义导出目录（null 或空 = 默认目录）。
  String? _customOutputDir;

  /// 由设置页与启动时调用，同步用户设置到管理器。
  void configure({String? customOutputDir, bool? autoSave}) {
    if (customOutputDir != null) _customOutputDir = customOutputDir;
    if (autoSave != null) autoSaveToGallery = autoSave;
  }

/// MP4 导出下载管理器（二次开发）。
///
/// 路径约定（与官方离线缓存 [DownloadService.baseDir] 分离）：
/// - 导出文件：`getExternalStorageDirectory()/mp4_downloads/`（失败则应用 support 目录）
/// - 相册：`Gal.putVideo(..., album: '阿圈短剧')` → 系统 MediaStore
class Mp4DownloadManager extends ChangeNotifier {
  Mp4DownloadManager._();
  static final Mp4DownloadManager instance = Mp4DownloadManager._();

  final Map<String, Mp4DownloadTask> _tasks = {};
  final Map<String, Process> _procs = {};
  String? _ffmpegPath;
  Future<String>? _finding;
    /// 用户自定义导出目录（null 或空 = 默认目录）。
  String? _customOutputDir;

  /// 由设置页与启动时调用，同步用户设置到管理器。
  void configure({String? customOutputDir, bool? autoSave}) {
    if (customOutputDir != null) _customOutputDir = customOutputDir;
    if (autoSave != null) autoSaveToGallery = autoSave;
  }

  /// 导出根目录（UI 标注与写入共用）。
  /// 优先使用用户自定义目录；不可写时回退到默认目录。
  Future<Directory> outputDir() async {
    final custom = _customOutputDir;
    if (custom != null && custom.isNotEmpty) {
      try {
        final d = Directory(custom);
        if (!await d.exists()) await d.create(recursive: true);
        final probe = File(p.join(d.path,
            '.aquan-write-test-${DateTime.now().microsecondsSinceEpoch}'));
        await probe.writeAsString('ok', flush: true);
        await probe.delete();
        return d;
      } catch (_) {
        debugPrint('自定义导出目录不可写，回退默认目录: $custom');
      }
    }
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory(p.join(ext.path, 'mp4_downloads'));
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    } catch (_) {}
    final support = await getApplicationSupportDirectory();
    final d = Directory(p.join(support.path, 'mp4_downloads'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 立刻进入 running 并开始，提升按钮点击反馈。
  Future<void> start({
    required String id,
    required String title,
    required String m3u8Url,
    Map<String, String> headers = const {},
  }) async {
    final existing = _tasks[id];
    if (existing != null &&
        (existing.state == Mp4TaskState.running ||
            existing.state == Mp4TaskState.queued)) {
      return;
    }

    final task = Mp4DownloadTask(
      id: id,
      title: title,
      m3u8Url: m3u8Url,
      headers: headers,
    );
    task.state = Mp4TaskState.running;
    task.message = '正在准备...';
    task.startedAt = DateTime.now();
    _tasks[id] = task;
    notifyListeners();

    try {
      await _assertNotEncrypted(m3u8Url, headers);

      final ffmpeg = await _ensureFfmpeg();
      task.message = '正在下载中 0s';
      notifyListeners();

      final dir = await outputDir();
      lastOutputDirPath = dir.path;
      final outName = '${_safeName(title)}-$id.mp4';
      final outPath = p.join(dir.path, outName);
      task.outputPath = outPath;
      final outFile = File(outPath);
      if (await outFile.exists()) await outFile.delete();

      final args = <String>[
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-progress', 'pipe:1',
        if (headers.isNotEmpty) ...[
          '-headers',
          '${headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n')}\r\n',
        ],
        '-i', m3u8Url,
        '-c', 'copy',
        '-bsf:a', 'aac_adtstoasc',
        '-movflags', '+faststart',
        outPath,
      ];

      final proc = await Process.start(ffmpeg, args);
      _procs[id] = proc;

      proc.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        if (line.startsWith('out_time_ms=')) {
          final ms = int.tryParse(line.substring('out_time_ms='.length)) ?? 0;
          final sec = (ms / 1000000).round();
          task.message = '正在下载中 ${sec}s';
          task.progress = (sec / 600).clamp(0.0, 0.99);
          notifyListeners();
        } else if (line.startsWith('progress=') && line.contains('end')) {
          task.progress = 1.0;
          notifyListeners();
        }
      });

      final errBuf = StringBuffer();
      proc.stderr.transform(utf8.decoder).listen(errBuf.write);

      final code = await proc.exitCode;
      _procs.remove(id);

      if (code == 0 && await outFile.exists() && await outFile.length() > 0) {
        task.state = Mp4TaskState.done;
        task.progress = 1.0;
        task.message = '下载完成';
        task.finishedAt = DateTime.now();
        if (autoSaveToGallery) {
          try {
            await Gal.putVideo(outPath, album: '阿圈短剧');
            task.savedToGallery = true;
            task.message = '下载完成 · 已存相册';
          } catch (e) {
            task.message = '下载完成 · 存相册失败: $e';
          }
        }
      } else {
        final detail = errBuf.toString().trim();
        task.state = Mp4TaskState.failed;
        task.error = detail.isNotEmpty ? detail : 'ffmpeg 退出码 $code';
        task.message = '失败: ${task.error}';
      }
    } catch (e, st) {
      debugPrint('Mp4DownloadManager.start: $e\n$st');
      task.state = Mp4TaskState.failed;
      task.error = e.toString().replaceFirst('Exception: ', '');
      task.message = '失败: ${task.error}';
    } finally {
      notifyListeners();
    }
  }

  Future<void> cancel(String id) async {
    _procs.remove(id)?.kill(ProcessSignal.sigterm);
    final t = _tasks[id];
    if (t != null && t.state == Mp4TaskState.running) {
      t.state = Mp4TaskState.cancelled;
      t.message = '已取消';
      notifyListeners();
    }
  }

  void remove(String id) {
    _tasks.remove(id);
    notifyListeners();
  }

  /// 手动保存到系统相册（列表页按钮）。
  Future<void> saveToGallery(String id) async {
    final t = _tasks[id];
    final path = t?.outputPath;
    if (t == null || path == null) {
      throw Exception('文件不存在');
    }
    await Gal.putVideo(path, album: '阿圈短剧');
    t.savedToGallery = true;
    t.message = '下载完成 · 已存相册';
    notifyListeners();
  }

  Future<void> scanExisting() async {
    try {
      final dir = await outputDir();
      lastOutputDirPath = dir.path;
      await for (final ent in dir.list()) {
        if (ent is! File || !ent.path.toLowerCase().endsWith('.mp4')) continue;
        final name = p.basenameWithoutExtension(ent.path);
        final id = name.contains('-') ? name.split('-').last : name;
        if (_tasks.containsKey(id)) continue;
        final t = Mp4DownloadTask(id: id, title: name, m3u8Url: '');
        t.state = Mp4TaskState.done;
        t.progress = 1.0;
        t.message = '下载完成';
        t.outputPath = ent.path;
        t.finishedAt = (await ent.stat()).modified;
        _tasks[id] = t;
      }
      notifyListeners();
    } catch (e) {
      debugPrint('scanExisting: $e');
    }
  }

  /// 导出根目录（UI 标注与写入共用）。
  Future<Directory> outputDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory(p.join(ext.path, 'mp4_downloads'));
        if (!await d.exists()) await d.create(recursive: true);
        return d;
      }
    } catch (_) {}
    final support = await getApplicationSupportDirectory();
    final d = Directory(p.join(support.path, 'mp4_downloads'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> _assertNotEncrypted(
      String url, Map<String, String> headers) async {
    final resp = await http.get(Uri.parse(url), headers: headers).timeout(
          const Duration(seconds: 15),
        );
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('无法读取播放列表（HTTP ${resp.statusCode}）');
    }
    if (resp.body.contains('EXT-X-KEY')) {
      throw Exception('该视频受版权保护无法下载');
    }
  }

  Future<String> _ensureFfmpeg() {
    if (_ffmpegPath != null) return Future.value(_ffmpegPath!);
    return _finding ??= _findBuiltinFfmpeg().then((path) {
      _ffmpegPath = path;
      _finding = null;
      return path;}).catchError((Object e) {
      _finding = null;
      throw e;
    });
  }

  Future<String> _findBuiltinFfmpeg() async {
    final env = Platform.environment['AQUAN_FFMPEG'];
    if (env != null && await _isUsable(env)) return env;

    final mapsDir = await _nativeLibDirFromMaps();
    if (mapsDir != null) {
      for (final name in ['libffmpeg.so', 'ffmpeg']) {
        final candidate = p.join(mapsDir, name);
        if (await _isUsable(candidate)) return candidate;
      }
      final src = File(p.join(mapsDir, 'libffmpeg.so'));
      if (await src.exists()) {
        final support = await getApplicationSupportDirectory();
        final dst = File(p.join(support.path, 'ffmpeg'));
        try {
          if (await dst.exists()) await dst.delete();
          await src.copy(dst.path);
          await Process.run('chmod', ['755', dst.path]);
          if (await _isUsable(dst.path)) return dst.path;
        } catch (e) {
          debugPrint('copy libffmpeg.so failed: $e');
        }
      }
    }

    try {
      final support = await getApplicationSupportDirectory();
      final cached = p.join(support.path, 'ffmpeg');
      if (await _isUsable(cached)) return cached;
    } catch (_) {}

    throw Exception('未找到内置 ffmpeg 二进制,无法下载');
  }

  Future<String?> _nativeLibDirFromMaps() async {
    try {
      final maps = await File('/proc/self/maps').readAsString();
      for (final line in maps.split('\n')) {
        if (!line.contains('libaquan_core.so') &&
            !line.contains('libffmpeg.so')) {
          continue;
        }
        final fields = line.split(RegExp(r'\s+'));
        if (fields.length < 6) continue;
        final mapped = fields.sublist(5).join(' ');
        if (!mapped.startsWith('/')) continue;
        final dir = p.dirname(mapped);
        if (dir.isNotEmpty && dir != '.') return dir;
      }
    } catch (e) {
      debugPrint('read maps failed: $e');
    }
    return null;
  }

  Future<bool> _isUsable(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return false;
      final st = await f.stat();
      return st.type == FileSystemEntityType.file && st.size > 1024;
    } catch (_) {
      return false;
    }
  }

  String _safeName(String name) {
    var s = name
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (s.length > 80) s = s.substring(0, 80);
    return s.isEmpty ? 'export' : s;
  }
}
