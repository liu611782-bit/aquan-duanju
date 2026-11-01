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
  Future<void> _appendToFile(ErrorLogEntry entry) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}${Platform.pathSeparator}error_log.txt');
      await file.writeAsString('${entry.toString()}\n\n',
          mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// 全部内容（复制用）。
  String get text => _entries.map((e) => e.toString()).join('\n\n');

  /// 抹掉 URL 查询串、常见凭据字段与 CENC 解密密钥，避免密钥进日志。
  static String redact(String text) => text
      .replaceAllMapped(
        RegExp(r'(https?://[^\s?#"]+)\?[^\s"]*'),
        (m) => '${m[1]}?…',
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
