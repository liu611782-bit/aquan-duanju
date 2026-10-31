import 'dart:async';
import 'dart:convert';

import 'source_adapter.dart';

/// 书源验收方法论（移植 VenHM `SOURCE_ACCEPTANCE.md` 的分级 + 取样 + 归因，
/// 适配本项目源生态：TVBox/CMS/Spider/市场站）。
///
/// 与 `source_checker.dart` 的关系：checker 是**快检**（导入后识别「全站空」
/// 假成功）；本模块是**深度验收**（分级取样 + 关键字扫描 + 归因矩阵），
/// 供源质量门禁与排查使用，不自动写健康分。
///
/// 分级：
/// - L0 离线契约：适配器身份可读（id/name/caps）；
/// - L1 注册：分类接口可调（不抛错即算过，空列表记备注）；
/// - L2 元数据：首页/列表可取且非空；deep 时分类抽样；
/// - L3 全链路：搜索取样（CJK/ASCII 各一 × 2 页 + id 指纹校验）→ 关键字
///   扫描 → 详情 → 分集首/中/末探测可播地址；
/// - L4 交互：真机人工验收项，执行器跳过并标注。
///
/// 归因三分类（VenHM A/B/C）：A 站点/网络（HTTP 4xx/5xx、超时、连接）；
/// B 需上游对照（拿到响应但解析/结构异常）；C 未定（默认，凭证据升级）。

enum SourceAcceptanceLevel {
  l0Contract('L0 离线契约'),
  l1Register('L1 注册'),
  l2Metadata('L2 元数据'),
  l3Chain('L3 全链路'),
  l4Interactive('L4 交互');

  final String label;
  const SourceAcceptanceLevel(this.label);
}

enum SourceFailureCause {
  /// A 类：站点/网络明确故障。
  siteOrNetwork('站点或网络'),

  /// B 类：拿到响应但结构可疑，需与上游对照。
  needsUpstreamComparison('需上游对照'),

  /// C 类：证据不足，保持未定。
  undetermined('未定');

  final String label;
  const SourceFailureCause(this.label);
}

/// 一条验收发现（JSONL 一行一个）。
class AcceptanceFinding {
  const AcceptanceFinding({
    required this.level,
    required this.ok,
    required this.detail,
    this.cause,
  });

  final SourceAcceptanceLevel level;
  final bool ok;

  /// 观察描述；源检查只发公开请求，不得携带账号/凭据。
  final String detail;
  final SourceFailureCause? cause;

  Map<String, dynamic> toJson() => {
        'level': level.name,
        'ok': ok,
        'detail': detail,
        if (cause != null) 'cause': cause!.name,
      };

  String toJsonLine() => jsonEncode(toJson());
}

/// 取样与判定规则（纯函数，便于单测）。
abstract final class SourceAcceptanceSampling {
  /// 搜索取样关键词：CJK / ASCII 各一（VenHM L3 硬性取样）。
  static const String cjkKeyword = '魔法';
  static const String asciiKeyword = 'love';

  /// 每个关键词取样的页数。
  static const int searchPages = 2;

  /// deep 模式下抽样的分类个数。
  static const int categorySamples = 6;

  /// 关键字扫描六词（VenHM SourceSelfTest）：区分「源坏了」vs「关键词
  /// 本来就没结果」。
  static const List<String> sweepWords = [
    'a', '1', '魔法', 'ab', 'love', '海贼',
  ];

  /// 章节/分集取样：首/中/末（n<=3 全取）。
  static List<int> pickEpisodeSamples(int n) {
    if (n <= 0) return const [];
    if (n <= 3) return List<int>.generate(n, (i) => i);
    return [0, n ~/ 2, n - 1];
  }

  /// 第 2 页与第 1 页的条目 id 指纹是否不同（防「分页失效重复第一页」）。
  /// 任一页为空视为无法比对（不算重复）。
  static bool pageFingerprintDiffers(List<String> page1, List<String> page2) {
    if (page1.isEmpty || page2.isEmpty) return true;
    if (page1.length != page2.length) return true;
    for (var i = 0; i < page1.length; i++) {
      if (page1[i] != page2[i]) return true;
    }
    return false;
  }

  /// 关键字扫描：任一词有命中即「源能出结果」。
  static bool sweepHasAnyHit(Map<String, int> resultCounts) =>
      resultCounts.values.any((n) => n > 0);
}

/// 失败 → 归因分类（只看错误文本特征，不猜）。
SourceFailureCause classifySourceFailure(Object error) {
  final text = error.toString().toLowerCase();
  if (RegExp(
          r'\b4\d{2}\b|\b5\d{2}\b|timeout|timed out|connection|socket|handshake|tls|certificate|unreachable|refused|http')
      .hasMatch(text)) {
    return SourceFailureCause.siteOrNetwork;
  }
  if (text.contains('type ') ||
      text.contains('null check') ||
      text.contains('formatexception') ||
      text.contains('parse') ||
      text.contains('decode') ||
      text.contains('missing') ||
      text.contains('not a function')) {
    return SourceFailureCause.needsUpstreamComparison;
  }
  return SourceFailureCause.undetermined;
}

/// 验收执行器：阶段独立 try/catch（单阶段失败不抹掉其他阶段结果——VenHM
/// 教训），逐条产出 [AcceptanceFinding]。
class SourceAcceptanceRunner {
  const SourceAcceptanceRunner({
    this.stageTimeout = const Duration(seconds: 15),
  });

  /// 单阶段（一页搜索/一次列表/一次详情）的超时，防卡死的源拖住整个验收。
  final Duration stageTimeout;

  /// 对单个适配器跑 L0–L3（deep 加深取样），L4 只标注。
  Stream<AcceptanceFinding> run(SourceAdapter adapter,
      {bool deep = false}) async* {
    // L0 离线契约。
    final id = adapter.id.trim();
    final name = adapter.name.trim();
    yield AcceptanceFinding(
      level: SourceAcceptanceLevel.l0Contract,
      ok: id.isNotEmpty && name.isNotEmpty,
      detail:
          id.isEmpty ? '适配器 id 为空' : 'id=$id name=$name caps=${adapter.caps}',
    );

    // L1 注册：分类接口可调（空列表允许，记备注）。
    List<SourceCategory> categories = const [];
    try {
      categories = await adapter.categories().timeout(stageTimeout);
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l1Register,
        ok: true,
        detail: '分类接口可调，返回 ${categories.length} 个分类',
      );
    } catch (e) {
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l1Register,
        ok: false,
        detail: '分类接口失败：$e',
        cause: classifySourceFailure(e),
      );
    }

    // L2 元数据：首页列表非空；deep 时分类抽样。
    List<UnifiedSeries> home = const [];
    try {
      home = await _collectListPage(adapter);
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l2Metadata,
        ok: home.isNotEmpty,
        detail: home.isEmpty ? '首页列表为空' : '首页 ${home.length} 条',
        cause: home.isEmpty ? SourceFailureCause.undetermined : null,
      );
    } catch (e) {
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l2Metadata,
        ok: false,
        detail: '首页列表失败：$e',
        cause: classifySourceFailure(e),
      );
    }
    if (deep && categories.isNotEmpty) {
      var checked = 0;
      var emptyParts = 0;
      var failedParts = 0;
      for (final category in categories.take(SourceAcceptanceSampling.categorySamples)) {
        try {
          final items = await _collectListPage(adapter, category.id);
          checked++;
          if (items.isEmpty) emptyParts++;
        } catch (_) {
          failedParts++;
        }
      }
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l2Metadata,
        ok: checked > 0 && failedParts < checked,
        detail: '分类抽样：检查 $checked / 失败 $failedParts / 空 $emptyParts',
        cause: checked > 0 && failedParts >= checked
            ? SourceFailureCause.siteOrNetwork
            : null,
      );
    }

    // L3 搜索取样：两词 × 2 页 + 指纹校验。
    final firstHit = <UnifiedSeries>[];
    var searchFailures = 0;
    for (final keyword in [
      SourceAcceptanceSampling.cjkKeyword,
      SourceAcceptanceSampling.asciiKeyword,
    ]) {
      List<UnifiedSeries> page1;
      try {
        page1 = await _collectSearchPage(adapter, keyword, 1);
      } catch (e) {
        searchFailures++;
        yield AcceptanceFinding(
          level: SourceAcceptanceLevel.l3Chain,
          ok: false,
          detail: '搜索「$keyword」第1页失败：$e',
          cause: classifySourceFailure(e),
        );
        continue;
      }
      if (page1.isNotEmpty && firstHit.isEmpty) firstHit.addAll(page1);
      final page2Ok = await _collectPage2(adapter, keyword, page1);
      if (page2Ok != null) yield page2Ok;
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: page1.isNotEmpty,
        detail: '搜索「$keyword」第1页 ${page1.length} 条',
        cause: page1.isEmpty ? SourceFailureCause.undetermined : null,
      );
    }

    // L3 关键字扫描：六词各一页，区分「源坏」与「词无结果」。
    try {
      final counts = <String, int>{};
      for (final word in SourceAcceptanceSampling.sweepWords) {
        try {
          counts[word] =
              (await _collectSearchPage(adapter, word, 1)).length;
        } catch (_) {
          counts[word] = -1; // 请求失败与 0 结果分开记
        }
      }
      final failed = counts.values.where((n) => n < 0).length;
      final anyHit = SourceAcceptanceSampling.sweepHasAnyHit(
          counts.map((k, v) => MapEntry(k, v < 0 ? 0 : v)));
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        // 扫描本身可执行（不是全 ERR）即算过；「全 0=词无结果」是解读，
        // 记在 detail 里（VenHM：全 0 只说明关键词没结果，源未必坏）。
        ok: failed < SourceAcceptanceSampling.sweepWords.length,
        detail: '关键字扫描：'
            '${counts.entries.map((e) => '${e.key}=${e.value < 0 ? "ERR" : e.value}').join(' ')}'
            '${anyHit ? '；有词命中' : '；全 0=关键词无结果（源未必坏）'}',
      );
    } catch (e) {
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: false,
        detail: '关键字扫描异常：$e',
        cause: classifySourceFailure(e),
      );
    }

    // L3 详情链路：取首个搜索命中的条目 → 详情 → 分集首/中/末探测。
    if (firstHit.isEmpty) {
      if (searchFailures >= 2) {
        yield AcceptanceFinding(
          level: SourceAcceptanceLevel.l3Chain,
          ok: false,
          detail: '搜索两词均失败，详情链路跳过',
          cause: SourceFailureCause.siteOrNetwork,
        );
      }
    } else {
      yield* _runDetailChain(adapter, firstHit.first);
    }

    // L4 交互：真机人工项，执行器跳过。
    yield const AcceptanceFinding(
      level: SourceAcceptanceLevel.l4Interactive,
      ok: false,
      detail: '真机人工验收项（选集起播/续播/切线路），执行器跳过',
    );
  }

  Future<AcceptanceFinding?> _collectPage2(
      SourceAdapter adapter, String keyword, List<UnifiedSeries> page1) async {
    List<UnifiedSeries> page2;
    try {
      page2 = await _collectSearchPage(adapter, keyword, 2);
    } catch (e) {
      return AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: false,
        detail: '搜索「$keyword」第2页失败：$e',
        cause: classifySourceFailure(e),
      );
    }
    final differs = SourceAcceptanceSampling.pageFingerprintDiffers(
      page1.map((s) => s.sourceItemId).toList(),
      page2.map((s) => s.sourceItemId).toList(),
    );
    return AcceptanceFinding(
      level: SourceAcceptanceLevel.l3Chain,
      ok: differs,
      detail: differs
          ? '搜索「$keyword」第2页 ${page2.length} 条，指纹与第1页不同'
          : '搜索「$keyword」第2页与第1页 id 指纹相同（分页失效嫌疑）',
      cause: differs ? null : SourceFailureCause.needsUpstreamComparison,
    );
  }

  Stream<AcceptanceFinding> _runDetailChain(
      SourceAdapter adapter, UnifiedSeries hit) async* {
    UnifiedSeries? detail;
    try {
      detail = await adapter.detail(hit.sourceItemId).timeout(stageTimeout);
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: true,
        detail: '详情「${detail.title}」线路 ${detail.lines.length} 条',
      );
    } catch (e) {
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: false,
        detail: '详情失败（${hit.sourceItemId}）：$e',
        cause: classifySourceFailure(e),
      );
      return;
    }
    final line = detail.defaultLine;
    final episodes = line?.episodes ?? const <UnifiedEpisode>[];
    if (episodes.isEmpty) {
      yield const AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: false,
        detail: '详情无可播分集',
        cause: SourceFailureCause.needsUpstreamComparison,
      );
      return;
    }
    // 分集首/中/末结构采样：地址非空（契约里没有「探测任一分集可播」的
    // 通用接口，逐集探测不可行；网络级可播验证由下面的 probePlayable 兜底）。
    final sampled = SourceAcceptanceSampling.pickEpisodeSamples(episodes.length);
    final emptyUrls =
        sampled.where((i) => episodes[i].url.trim().isEmpty).length;
    yield AcceptanceFinding(
      level: SourceAcceptanceLevel.l3Chain,
      ok: emptyUrls == 0,
      detail: '分集采样（${line!.name}，共 ${episodes.length} 集）：'
          '首/中/末 ${sampled.length} 集地址空 $emptyUrls',
      cause: emptyUrls > 0 ? SourceFailureCause.needsUpstreamComparison : null,
    );
    // 全链路可播探测：契约方法 detail→默认线路→首集地址。
    try {
      final url = await adapter
          .probePlayable(itemId: hit.sourceItemId)
          .timeout(stageTimeout);
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: url.isNotEmpty,
        detail: url.isEmpty ? 'probePlayable 未解析出可播地址' : 'probePlayable 出地址（链路通）',
        cause: url.isEmpty ? SourceFailureCause.undetermined : null,
      );
    } catch (e) {
      yield AcceptanceFinding(
        level: SourceAcceptanceLevel.l3Chain,
        ok: false,
        detail: 'probePlayable 失败：$e',
        cause: classifySourceFailure(e),
      );
    }
  }

  Future<List<UnifiedSeries>> _collectListPage(
      SourceAdapter adapter,
      [String? categoryId]) async {
    final page = await adapter
        .list(categoryId: categoryId, page: 1)
        .timeout(stageTimeout);
    return page.items;
  }

  Future<List<UnifiedSeries>> _collectSearchPage(
      SourceAdapter adapter, String query, int page) async {
    final items = <UnifiedSeries>[];
    await for (final event
        in adapter.search(query, page: page).timeout(stageTimeout)) {
      if (event is SourceHits) items.addAll(event.items);
      if (event is SourceSearchFailed) {
        throw Exception('search failed: ${event.code.name} ${event.detail}');
      }
      if (event is SourceSearchDone) break;
    }
    return items;
  }
}
