/// 音轨/字幕选择按剧记忆（Pathfin ContinuousTrackSelection 口径）。
///
/// 序号口径 = 轨道面板展示序：media_kit 的轨道列表过滤掉 `auto`/`no` 后的
/// 下标（与 [showPlayerTracksSheet] 渲染顺序一致）。
///
/// 匹配策略（参考实现的教训，两道防线）：
/// 1. **稳定身份键优先**——轨道编号跨集不稳定（不同 mux 的轨序会漂移），
///    可携带的是「语言 + 标题」的归一化描述；键必须**唯一命中**候选列表
///    才应用（Pathfin `singleOrNull`：命中多条宁可保持默认，不错配语言）。
/// 2. **序号兜底**——键缺失（无名轨）或唯一键失配时，序号在界内仍可套用
///    （同剧各集轨道结构通常一致）。
abstract final class TrackPreference {
  /// 字幕偏好特殊值：用户明确关闭字幕（换集保持关闭，不被默认字幕顶掉）。
  static const int subtitleOff = -1;

  /// 序号是否可直接套用（列表存在且在界内）。
  static bool applicable(int? index, int trackCount) {
    if (index == null) return false;
    if (index == subtitleOff) return true; // 关闭字幕不依赖轨道列表
    return index >= 0 && index < trackCount;
  }

  /// 轨道的稳定身份键：language + title 归一化（小写、空白压扁）。
  /// 两者皆空 → null（无名轨没有可携带身份，只能靠序号兜底）。
  static String? stableTrackKey({String? language, String? title}) {
    final lang = _norm(language);
    final label = _norm(title);
    if (lang == null && label == null) return null;
    return [lang, label].whereType<String>().join('|');
  }

  static String? _norm(String? raw) {
    final v = raw?.trim().toLowerCase();
    if (v == null || v.isEmpty) return null;
    return v.replaceAll(RegExp(r'\s+'), ' ');
  }

  /// 唯一匹配才返回下标：键命中 0 条或 ≥2 条 → null（保持默认）。
  static int? uniqueMatchIndex(
      String key, List<String?> candidateKeys) {
    final hits = <int>[
      for (var i = 0; i < candidateKeys.length; i++)
        if (candidateKeys[i] != null && candidateKeys[i] == key) i,
    ];
    return hits.length == 1 ? hits.single : null;
  }
}
