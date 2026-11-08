/// 联想条目的提交词。
///
/// SDK 对联想行（`query_result_v2`）的 keyword 处理有缺口：内容 ID 形态的
/// keyword（纯数字，≤40 位即保留，如 19 位 seriesId）会被原样带出——把 ID
/// 当搜索词提交，服务端检索不到任何剧（用户实测：点联想搜不到、手输全名
/// 可以；搜索历史里残留的数字条目即污染证据）。纯数字串不是人类会输入的
/// 搜索词，一律回落显示文本 [Suggestion.text]（服务端给的联想词，永远安全）。
library;

import '../../models/models.dart';

/// 联想条目实际应提交的搜索词。
String suggestSubmitText(Suggestion s) {
  final k = s.keyword.trim();
  if (k.isEmpty) return s.text;
  final digitsOnly = k.runes.every((r) => r >= 0x30 && r <= 0x39);
  return digitsOnly ? s.text : k;
}
