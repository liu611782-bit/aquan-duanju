/// 季序号的展示口径。
///
/// 上游 `season_index` 在部分合集里缺失或为 0（见 `Season.index` 注释「从 1 开始」，
/// 但 SDK 不做归一化），而详情页此前直接打印 `'${s.index}. ${s.title}'`，于是出现
/// 「0. 万妖图录传」。这里统一三级兜底，保证任何入口都不会显示 0。
library;

/// 中文数字 → 整数（只覆盖季号常见范围 1–99）。
int? _chineseNumber(String raw) {
  const digits = {
    '零': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  if (raw.isEmpty) return null;
  // 纯阿拉伯数字（调用方已用正则限定，这里兜底直接解析）。
  final direct = int.tryParse(raw);
  if (direct != null) return direct;

  // 「十」「十一」「二十」「二十三」。
  if (!raw.contains('十')) {
    var value = 0;
    for (final ch in raw.split('')) {
      final d = digits[ch];
      if (d == null) return null;
      value = value * 10 + d;
    }
    return value == 0 ? null : value;
  }
  final parts = raw.split('十');
  if (parts.length > 2) return null;
  final head = parts[0].isEmpty ? 1 : (digits[parts[0]] ?? 0);
  if (head <= 0) return null;
  final tail = parts[1].isEmpty ? 0 : (digits[parts[1]] ?? -1);
  if (tail < 0) return null;
  return head * 10 + tail;
}

/// 从标题里解析季号：`第2季` / `第二部` / `（第三季）` / `(第 4 季)`。
///
/// 返回 null 表示标题里没有季记号。
int? seasonNumberFromTitle(String title) {
  if (title.isEmpty) return null;
  final match = RegExp(
    r'第\s*([0-9]{1,3}|[零一二两三四五六七八九十]{1,3})\s*[季部]',
  ).firstMatch(title);
  if (match == null) return null;
  final value = _chineseNumber(match.group(1) ?? '');
  if (value == null || value <= 0) return null;
  return value;
}

/// 三级兜底：`index > 0` → 标题解析 → 列表位置 + 1。
///
/// [position] 为该季在合集列表中的下标（0 基）。返回值恒 ≥ 1。
int seasonOrdinal({
  required int index,
  required String title,
  required int position,
}) {
  if (index > 0) return index;
  final parsed = seasonNumberFromTitle(title);
  if (parsed != null) return parsed;
  return position < 0 ? 1 : position + 1;
}

/// 列表项标题：「3. 万妖图录传第三季」。
///
/// 标题原文保留（上游可能已经带「第三季」），只有序号做兜底——与既有
/// 「1. 万妖图录传第一季」的呈现一致。
String seasonTitleLabel({
  required int index,
  required String title,
  required int position,
}) {
  final ordinal =
      seasonOrdinal(index: index, title: title, position: position);
  return title.isEmpty ? '$ordinal.' : '$ordinal. $title';
}
