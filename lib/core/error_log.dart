import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 应用内错误日志（关于页「错误日志」可查看 / 复制 / 清空）。
///
/// 口径：内存保留本次打开期间的最近 [maxEntries] 条（超出丢最旧的），
/// **同时逐条追加落盘** `error_log.txt`（应用支持目录）——用户反馈时
/// 可直接发文件。记录内容在入库前做脱敏，避免 token / decryption_key /
/// URL 查询串被写出去。
class ErrorLogEntry {
  const ErrorLogEntry({
    required this.time,
    required this.source,
    required this.message,
    this.stack,
  });

  final DateTime time;
  final String source;
  final String message;
  final String? stack;

  String get timeText {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }

  @override
  String toString() {
    final head = '[$timeText] $source · $message';
    final body = stack;
    if (body == null || body.isEmpty) return head;
    return '$head\n${body.split('\n').map((l) => '    $l').join('\n')}';
  }
}

class ErrorLog extends ChangeNotifier {
  ErrorLog({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final List<ErrorLogEntry> _entries = [];

  static const int maxEntries = 200;
  static const int maxStackLines = 30;

  /// 全局实例（应用生命周期内一份）。
  static final ErrorLog instance = ErrorLog();

  List<ErrorLogEntry> get entries => List.unmodifiable(_entries);
  bool get isEmpty => _entries.isEmpty;
  int get length => _entries.length;

  void record(String source, Object error, [StackTrace? stack]) {
    String? stackText;
    if (stack != null) {
      final lines = '$stack'
          .trimRight()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      stackText = [
        ...lines.take(maxStackLines).map((l) => l.trimRight()),
        if (lines.length > maxStackLines)
          '…（其余 ${lines.length - maxStackLines} 行已省略）',
      ].join('\n');
    }
    _entries.add(
      ErrorLogEntry(
        time: _now(),
        source: source,
        message: redact('$error').trim(),
        stack: stackText,
      ),
    );
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    unawaited(_appendToFile(_entries.last));
    notifyListeners();
  }

  /// 逐条追加落盘（fire-and-forget，失败静默——日志不能拖垮业务）。
  ///
  /// 主写「应用支持目录」；便携 Release（非 debug 且 exe 同级目录可写）再在
  /// exe 同级写一份，方便测试直接从安装目录找到 `error_log.txt`。
  Future<void> _appendToFile(ErrorLogEntry entry) async {
    final line = '${entry.toString()}\n\n';
    try {
      await (await _appSupportFile())
          .writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {}
    if (kDebugMode) return;
    try {
      final portable = _portableFile();
      await portable?.writeAsString(line, mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  Future<File> _appSupportFile() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}error_log.txt');
  }

  /// exe 同级目录里的 `error_log.txt`（便携包用）；拿不到目录返回 null。
  File? _portableFile() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent;
      return File('${exeDir.path}${Platform.pathSeparator}error_log.txt');
    } catch (_) {
      return null;
    }
  }

  /// 供 UI 展示/定位：应用支持目录里 `error_log.txt` 的绝对路径。
  /// 解析不了（如无 path_provider 的测试环境）返回空串，UI 据此隐藏定位入口。
  Future<String> resolveLogFilePath() async {
    try {
      return (await _appSupportFile()).path;
    } catch (_) {
      return '';
    }
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 全部内容（复制用）。
  String get text => _entries.map((e) => e.toString()).join('\n\n');

  /// 抹掉 URL 查询串的值但保留参数名、常见凭据字段与 CENC 解密密钥。
  ///
  /// 旧实现把整个 query 抹成 `?…`，播放失败时完全看不出地址是否带鉴权、
  /// 是否走 HLS 参数；保留键名既能定位又不泄露 token。
  static String redact(String text) => text
      .replaceAllMapped(
        RegExp(r'(https?://[^\s?#"]+)\?([^\s"]*)'),
        (m) {
          final keys = m[2]!
              .split('&')
              .map((kv) => kv.split('=').first)
              .where((k) => k.isNotEmpty)
              .take(8)
              .join(',');
          return keys.isEmpty ? '${m[1]}?' : '${m[1]}?[$keys]';
        },
      )
      .replaceAllMapped(
        // Authorization: Bearer xxx —— 认证方案后面的值一起抹掉
        RegExp(
          r'((?:token|authorization|cookie|password|passwd|secret)\s*[=:]\s*)(?:(?:bearer|basic)\s+)?[^\s,;&]+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}…',
      )
      .replaceAllMapped(
        RegExp(r'(decryption_key\s*[=:]\s*)[0-9a-fA-F]{16,}'),
        (m) => '${m[1]}…',
      );
}
