/// 归一化标题：跨源去重键的基础（归一化标题 + 年份）。
///
/// 规则：全角转半角、去空白、去常见中西文标点/分隔符；年份后缀由调用方单独携带
/// （UnifiedSeries.year），这里只统一文本形态。
String normalizeTitle(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  // 全角 ASCII 区转半角。
  final sb = StringBuffer();
  for (final ch in s.runes) {
    if (ch == 0x3000) {
      sb.write(' ');
    } else if (ch >= 0xFF01 && ch <= 0xFF5E) {
      sb.writeCharCode(ch - 0xFEE0);
    } else {
      sb.writeCharCode(ch);
    }
  }
  s = sb.toString();
  s = s.replaceAll(RegExp(r'\s+'), '');
  s = s.replaceAll(
      RegExp('[\'"\\[\\]()（）【】《》<>·•，,。.！!？?：:；;～~\\-—_+*/\\\\|&^%\$#@＝=]'),
      '');
  return s.toLowerCase();
}

/// 分集名归一化：换源后按集名定位同一集。
///
/// 规则（xiugou-tv `normalizeEpisodeName`）：全角转半角 → 去空白 → 去前缀「第」
/// → 去后缀「集/话/期/回」→ 纯数字去前导 0 → 小写。
/// 只做「唯一匹配」判定：多个分集归一到同一个名字时调用方应视为歧义并跳过。
String normalizeEpisodeName(String raw) {
  var s = normalizeTitle(raw);
  if (s.isEmpty) return s;
  s = s.replaceFirst(RegExp(r'^第'), '');
  s = s.replaceFirst(RegExp(r'(集|话|期|回)$'), '');
  if (RegExp(r'^\d+$').hasMatch(s)) {
    s = int.tryParse(s)?.toString() ?? s;
  }
  return s;
}
