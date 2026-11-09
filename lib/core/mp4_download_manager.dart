import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// MP4 导出下载任务状态
enum Mp4DownloadState {
  queued,
  running,
  done,
  failed,
  cancelled,
}

class Mp4DownloadTask {
  Mp4DownloadTask({
    required this.id,
    required this.title,
    required this.m3u8Url,
    this.headers = const {},
    this.coverUrl,
  });

  final String id;
  final String title;
  final String m3u8Url;
  final Map<String, String> headers;
  final String? coverUrl;

  Mp4DownloadState state = Mp4DownloadState.queued;
  double progress = 0.0; // 0.0 \~ 1.0
  String? message; // 实时提示，例如「正在下载中 45%」
  String? error;
  String? outputPath;
  DateTime? startedAt;
  DateTime? finishedAt;
}

/// 更稳健的内置 ffmpeg 定位 + MP4 导出下载管理器
class Mp4DownloadManager extends ChangeNotifier {
  Mp4DownloadManager();

  final Map<String, Mp4DownloadTask> _tasks = {};
  final Map<String, Process> _processes = {};
  bool _finding = false;
  String? _cachedFfmpegPath;

  Map<String, Mp4DownloadTask> get tasks => Map.unmodifiable(_tasks);

  Mp4DownloadTask? taskOf(String id) => _tasks[id];

  /// 立即开始下载（点击后马上进入 running，提升按钮灵敏度感知）
  Future<void> startDownload({
    required String id,
    required String title,
    required String m3u8Url,
    Map<String, String> headers = const {},
    String? coverUrl,
  }) async {
    // 防止重复点击
    final existing = _tasks[id];
    if (existing != null &&
        (existing.state == Mp4DownloadState.running ||
            existing.state == Mp4DownloadState.queued)) {
      return;
    }

    final task = Mp4DownloadTask(
      id: id,
      title: title,
      m3u8Url: m3u8Url,
      headers: headers,
      coverUrl: coverUrl,
    );
    task.state = Mp4DownloadState.running;
    task.message = '正在准备...';
    task.startedAt = DateTime.now();
    _tasks[id] = task;
    notifyListeners(); // 立刻刷新 UI，按钮立刻变灰/转圈

    try {
      final ffmpeg = await _ensureFfmpeg();
      task.message = '正在下载中 0%';
      notifyListeners();

      final dir = await _outputDir();
      final safeName = _safeFileName(title);
      final outPath = p.join(dir.path, '$safeName-$id.mp4');
      task.outputPath = outPath;

      // 清理旧文件
      final outFile = File(outPath);
      if (await outFile.exists()) await outFile.delete();

      final args = <String>[
        '-y',
        '-hide_banner',
        '-loglevel', 'error',
        '-progress', 'pipe:1',
        // 可选：headers（防盗链）
        if (headers.isNotEmpty) ...[
          '-headers',
          headers.entries.map((e) => '${e.key}: ${e.value}').join('\r\n') + '\r\n',
        ],
        '-i', m3u8Url,
        '-c', 'copy',
        '-bsf:a', 'aac_adtstoasc',
        '-movflags', '+faststart',
        outPath,
      ];

      final process = await Process.start(
        ffmpeg,
        args,
        mode: ProcessStartMode.normal,
      );
      _processes[id] = process;

      // 实时解析进度
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          // out_time_ms=123456789
          if (line.startsWith('out_time_ms=')) {
            final ms = int.tryParse(line.substring(12)) ?? 0;
            // 没有总时长时用时间粗略显示，或保持“正在下载中”
            // 这里简单用秒数提示，真实项目可结合 m3u8 总时长算百分比
            final sec = (ms / 1000000).round();
            task.message = '正在下载中 ${sec}s';
            // 若已知总时长可算百分比：
            // task.progress = (ms / totalUs).clamp(0.0, 1.0);
            notifyListeners();
          } else if (line.startsWith('progress=')) {
            // continue / end
            if (line.contains('end')) {
              task.progress = 1.0;
              notifyListeners();
            }
          }
        },
        onError: (_) {},
      );

      final stderrBuf = StringBuffer();
      process.stderr.transform(utf8.decoder).listen((s) {
        stderrBuf.write(s);
      });

      final code = await process.exitCode;
      _processes.remove(id);

      if (code == 0 && await outFile.exists() && await outFile.length() > 0) {
        task.state = Mp4DownloadState.done;
        task.progress = 1.0;
        task.message = '下载完成';
        task.finishedAt = DateTime.now();
      } else {
        task.state = Mp4DownloadState.failed;
        task.error = stderrBuf.toString().trim().isNotEmpty
            ? stderrBuf.toString().trim()
            : 'ffmpeg 退出码 $code';
        task.message = '失败: ${task.error}';
      }
    } catch (e, st) {
      debugPrint('MP4 download error: $e\n$st');
      task.state = Mp4DownloadState.failed;
      task.error = e.toString();
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

  /// 扫描输出目录，把已有 mp4 填回列表（列表页冷启动用）。
  Future<void> scanExisting() async {
    try {
      final dir = await _outputDir();
      await for (final ent in dir.list()) {
        if (ent is! File || !ent.path.toLowerCase().endsWith('.mp4')) continue;
        final name = p.basenameWithoutExtension(ent.path);
        final id = name.contains('-') ? name.split('-').last : name;
        if (_tasks.containsKey(id)) continue;
        final t = Mp4DownloadTask(
          id: id,
          title: name,
          m3u8Url: '',
        );
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

  // ---------------------------------------------------------------------------
  // 版权检查
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // ffmpeg 定位（修复「未找到内置 ffmpeg 二进制」）
  // ---------------------------------------------------------------------------

  Future<String> _ensureFfmpeg() {
    if (_ffmpegPath != null) return Future.value(_ffmpegPath!);
    return _finding ??= _findBuiltinFfmpeg().then((path) {
      _ffmpegPath = path;
      _finding = null;
      return path;
    }).catchError((Object e) {
      _finding = null;
      throw e;
    });
  }

  Future<String> _findBuiltinFfmpeg() async {
    // 1. 环境变量（调试用）
    final env = Platform.environment['AQUAN_FFMPEG'];
    if (env != null && await _isUsable(env)) return env;

    // 2. /proc/self/maps → nativeLibraryDir（对齐 castrelay.go，并增强匹配）
    final mapsDir = await _nativeLibDirFromMaps();
    if (mapsDir != null) {
      for (final name in ['libffmpeg.so', 'ffmpeg']) {
        final candidate = p.join(mapsDir, name);
        if (await _isUsable(candidate)) return candidate;
      }

      // 3. 复制到应用支持目录再 chmod（部分机型 nativeLibraryDir 不可直接 exec）
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
          debugPrint('copy libffmpeg.so → filesDir failed: $e');
        }
      }
    }

    // 4. 已缓存的 filesDir 副本
    try {
      final support = await getApplicationSupportDirectory();
      final cached = p.join(support.path, 'ffmpeg');
      if (await _isUsable(cached)) return cached;
    } catch (_) {}

    throw Exception('未找到内置 ffmpeg 二进制,无法下载');
  }

  /// 对齐官方 parseNativeLibDir，同时匹配 libaquan_core.so / libffmpeg.so。
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
        // 路径可能含空格：第 6 列及之后重新拼接
        final mapped = fields.sublist(5).join(' ');
        if (!mapped.startsWith('/')) continue;
        final dir = p.dirname(mapped);
        if (dir.isNotEmpty && dir != '.') return dir;
      }
    } catch (e) {
      debugPrint('read /proc/self/maps failed: $e');
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

  Future<Directory> _outputDir() async {
    // 与修改报告一致：getExternalStorageDirectory()/mp4_downloads/
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        final d = Directory(p.join(ext.path, 'mp4_downloads'));
        if ((!await d.exists()) await d.create(recursive: true);
        return d;
      }
    } catch (_) {}
    final support = await getApplicationSupportDirectory();
    final d = Directory(p.join(support.path, 'mp4_downloads'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
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
