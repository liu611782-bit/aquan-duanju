import 'dart:io';

import 'reader_theme.dart';

/// 页眉页脚渲染所需的上下文。
class ReaderTipContext {
  const ReaderTipContext({
    this.bookName = '',
    this.chapterTitle = '',
    this.chapterIndex = 0,
    this.chapterSize = 0,
    this.pageIndex = 0,
    this.pageSize = 0,
    this.wholePageIndex = 0,
    this.wholePageSize = 0,
    this.progress = 0,
    this.now,
    this.batteryPercent,
  });

  final String bookName;
  final String chapterTitle;
  final int chapterIndex;
  final int chapterSize;

  /// 章内页码，从 0 开始。
  final int pageIndex;
  final int pageSize;

  /// 全书页码。
  final int wholePageIndex;
  final int wholePageSize;

  /// 全书进度 0..1。
  final double progress;

  final DateTime? now;
  final int? batteryPercent;

  DateTime get timestamp => now ?? DateTime.now();

  ReaderTipContext copyWith({
    String? bookName,
    String? chapterTitle,
    int? chapterIndex,
    int? chapterSize,
    int? pageIndex,
    int? pageSize,
    int? wholePageIndex,
    int? wholePageSize,
    double? progress,
    DateTime? now,
    int? batteryPercent,
  }) =>
      ReaderTipContext(
        bookName: bookName ?? this.bookName,
        chapterTitle: chapterTitle ?? this.chapterTitle,
        chapterIndex: chapterIndex ?? this.chapterIndex,
        chapterSize: chapterSize ?? this.chapterSize,
        pageIndex: pageIndex ?? this.pageIndex,
        pageSize: pageSize ?? this.pageSize,
        wholePageIndex: wholePageIndex ?? this.wholePageIndex,
        wholePageSize: wholePageSize ?? this.wholePageSize,
        progress: progress ?? this.progress,
        now: now ?? this.now,
        batteryPercent: batteryPercent ?? this.batteryPercent,
      );
}

/// 页眉/页脚的三个位置取值。
class ReaderTipLayout {
  const ReaderTipLayout({
    this.left = '',
    this.middle = '',
    this.right = '',
  });

  final String left;
  final String middle;
  final String right;

  bool get isEmpty => left.isEmpty && middle.isEmpty && right.isEmpty;
}

/// 当前时间 `HH:mm`。
String formatTipTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

/// 渲染单个页眉/页脚取值。缺数据时退化成占位符，不抛异常。
String renderTip(
  ReaderTipValue value,
  ReaderTipContext ctx, {
  String custom = '',
}) {
  switch (value) {
    case ReaderTipValue.none:
      return '';
    case ReaderTipValue.time:
      return formatTipTime(ctx.timestamp);
    case ReaderTipValue.battery:
      return ctx.batteryPercent == null ? '—' : '${ctx.batteryPercent}%';
    case ReaderTipValue.chapterTitle:
      return ctx.chapterTitle;
    case ReaderTipValue.pageIndex:
      return ctx.pageSize <= 0 ? '' : '${ctx.pageIndex + 1}/${ctx.pageSize}';
    case ReaderTipValue.totalProgress:
      return '${(ctx.progress * 100).clamp(0, 100).toStringAsFixed(1)}%';
    case ReaderTipValue.pageAndTotal:
      if (ctx.pageSize <= 0) return '';
      return '${ctx.pageIndex + 1}/${ctx.pageSize}  '
          '${(ctx.progress * 100).clamp(0, 100).toStringAsFixed(1)}%';
    case ReaderTipValue.bookPage:
      if (ctx.wholePageSize <= 0) return '';
      return '${ctx.wholePageIndex + 1}/${ctx.wholePageSize}';
    case ReaderTipValue.custom:
      return renderTipTemplate(custom, ctx);
  }
}

/// 自定义模板：替换 `{BookName}` 一类变量。
///
/// 匹配大小写与下划线不敏感（`{bookname}`/`{book_name}` 都命中）：
/// 用户照着别处手抄模板时最容易写出发音相同但拼写不同的变体，
/// 严格按原文匹配会让整条模板「一堆变量原文」直接糊在页脚上。
/// 仍然不认识的变量原样保留，便于排错。
String renderTipTemplate(String template, ReaderTipContext ctx) {
  if (template.isEmpty) return '';
  final remaining =
      ctx.pageSize <= 0 ? 0 : (ctx.pageSize - ctx.pageIndex - 1).clamp(0, 1 << 30);
  final values = <String, String>{
    'BookName': ctx.bookName,
    'ChapterTitle': ctx.chapterTitle,
    'ChapterIndex': (ctx.chapterIndex + 1).toString(),
    'ChapterSize': '${ctx.chapterSize}',
    'Time': formatTipTime(ctx.timestamp),
    'BatteryPercent': ctx.batteryPercent?.toString() ?? '—',
    'PageIndex': '${ctx.pageIndex + 1}',
    'PageSize': '${ctx.pageSize}',
    'PageRemaining': '$remaining',
    'ReadProgress': (ctx.progress * 100).clamp(0, 100).toStringAsFixed(1),
    'FullPageIndex': '${ctx.wholePageIndex + 1}',
    'FullPageSize': '${ctx.wholePageSize}',
  };
  String normalize(String key) => key.replaceAll('_', '').toLowerCase();
  final byNormalized = <String, String>{
    for (final e in values.entries) normalize(e.key): e.value,
  };
  return template.replaceAllMapped(
    RegExp(r'\{([A-Za-z_][A-Za-z0-9_]*)\}'),
    (m) => byNormalized[normalize(m.group(1)!)] ?? m.group(0)!,
  );
}

/// 组装一行的三个位置。
ReaderTipLayout buildTipLayout({
  required ReaderTipValue left,
  required ReaderTipValue middle,
  required ReaderTipValue right,
  required ReaderTipContext ctx,
  String customLeft = '',
  String customMiddle = '',
  String customRight = '',
}) =>
    ReaderTipLayout(
      left: renderTip(left, ctx, custom: customLeft).trim(),
      middle: renderTip(middle, ctx, custom: customMiddle).trim(),
      right: renderTip(right, ctx, custom: customRight).trim(),
    );

/// 电量百分比读取。
///
/// 不引入 `battery_plus`（会带来额外的平台配置），直接读 Linux/Android 的
/// sysfs 节点；Windows/macOS 返回 null，页眉显示 `—`。结果缓存 60 秒。
class BatteryLevelReader {
  BatteryLevelReader._();

  static const List<String> _paths = <String>[
    '/sys/class/power_supply/battery/capacity',
    '/sys/class/power_supply/BAT0/capacity',
    '/sys/class/power_supply/BAT1/capacity',
  ];

  static int? _cached;
  static DateTime? _cachedAt;

  static int? read() {
    final now = DateTime.now();
    final cachedAt = _cachedAt;
    if (cachedAt != null && now.difference(cachedAt).inSeconds < 60) {
      return _cached;
    }
    _cachedAt = now;
    _cached = null;
    if (Platform.isWindows || Platform.isMacOS) return null;
    for (final path in _paths) {
      try {
        final file = File(path);
        if (!file.existsSync()) continue;
        final value = int.tryParse(file.readAsStringSync().trim());
        if (value != null && value >= 0 && value <= 100) {
          _cached = value;
          return value;
        }
      } catch (_) {
        // 没权限或节点不存在：继续试下一个。
      }
    }
    return null;
  }
}
