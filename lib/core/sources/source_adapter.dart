/// 第三方影视源的统一抽象：CMS(苹果CMS V10) JSON/XML 源与后续 spider 源都适配成它，
/// 红果内容经 [HongguoBridgeAdapter]（见 hongguo_bridge_adapter.dart）并入同一消费口径。
///
/// 内模 [UnifiedSeries] 供详情/播放器/历史复用；红果的 [seriesId] 语义对应
/// `sourceKey + ':' + sourceItemId`（sourceKey 为空即红果，保持旧数据兼容）。
library;


/// 源类型：type=1 JSON CMS / type=0 XML CMS / type=3 爬虫源
/// （[spider] = jar/JVM 族暂不支持；[spiderJs] = .js 爬虫，QuickJS 运行时执行）。
enum SourceKind { cmsJson, cmsXml, spider, spiderJs }

/// 源配置（持久化于 aquan_sources.json 的 sources[]）。
class SourceConfig {
  SourceConfig({
    required this.id,
    required this.name,
    required List<String> apis,
    this.kind = SourceKind.cmsJson,
    this.spiderKey,
    Map<String, String>? headers,
    this.enabled = true,
    this.pinned = false,
    this.shortDrama = false,
    this.note = '',
    DateTime? addedAt,
  })  : apis = List.of(apis),
        headers = Map.of(headers ?? const {}),
        addedAt = addedAt ?? DateTime.now();

  final String id;

  /// 展示名。
  final String name;

  /// 接口基址列表：[apis[0]] 为主地址，其余为镜像（失败逐个回退）。
  final List<String> apis;

  final SourceKind kind;

  /// spider 源的 key（TVBox sites[].key，Companion RPC 路由用）。
  final String? spiderKey;

  /// 源级请求头（TVBox sites[].header 归并 Referer/UA）。
  final Map<String, String> headers;
  bool enabled;
  bool pinned;

  /// CMS 分类含「短剧/微短剧/短视频」时自动标记（MoonTVPlus duanju 语义）。
  bool shortDrama;
  String note;
  DateTime addedAt;

  String get api => apis.first;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'apis': apis,
        'kind': kind.name,
        if (spiderKey != null) 'spider_key': spiderKey,
        if (headers.isNotEmpty) 'headers': headers,
        'enabled': enabled,
        'pinned': pinned,
        'short_drama': shortDrama,
        if (note.isNotEmpty) 'note': note,
        'added_at': addedAt.toIso8601String(),
      };

  factory SourceConfig.fromJson(Map<String, dynamic> json) => SourceConfig(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        apis: [
          if (json['api'] is String && (json['api'] as String).isNotEmpty)
            json['api'] as String,
          ...?((json['apis'] as List?)?.cast<String>()),
        ],
        kind: SourceKind.values.firstWhere(
          (k) => k.name == json['kind'],
          orElse: () => SourceKind.cmsJson,
        ),
        spiderKey: json['spider_key'] as String?,
        headers: (json['headers'] as Map?)
                ?.map((k, v) => MapEntry(k.toString(), v.toString())) ??
            const <String, String>{},
        enabled: json['enabled'] as bool? ?? true,
        pinned: json['pinned'] as bool? ?? false,
        shortDrama: json['short_drama'] as bool? ?? false,
        note: json['note'] as String? ?? '',
        addedAt:
            DateTime.tryParse(json['added_at'] as String? ?? '') ??
                DateTime.now(),
      );

  /// 按 api 归一化（去尾斜杠）判断与 [other] 是否同一源。
  bool sameEndpointAs(SourceConfig other) =>
      kind == other.kind && _norm(apis) == _norm(other.apis);

  static String _norm(List<String> apis) => apis
      .map((a) => a.endsWith('/') ? a.substring(0, a.length - 1) : a)
      .join('|');
}

/// 源能力声明（UI 据此显隐入口）。
class SourceCaps {
  const SourceCaps({
    this.searchable = true,
    this.filterable = true,
    this.multiLine = true,
  });

  final bool searchable;
  final bool filterable;
  final bool multiLine;
}

/// 源内分类。
class SourceCategory {
  const SourceCategory({required this.id, required this.name});
  final String id;
  final String name;
}

/// 分页结果。
class SourcePage<T> {
  const SourcePage({
    required this.items,
    required this.page,
    this.hasMore = false,
  });
  final List<T> items;
  final int page;
  final bool hasMore;
}

/// 一条线路：CMS `vod_play_url` 以 `$$$` 分线路。
class PlayLine {
  const PlayLine({required this.name, required this.episodes});
  final String name;
  final List<UnifiedEpisode> episodes;

  Map<String, dynamic> toJson() => {
        'name': name,
        'episodes': [for (final e in episodes) e.toJson()],
      };

  static PlayLine? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    final episodes = raw['episodes'];
    if (name is! String) return null;
    if (episodes is! List) return null;
    final parsed = <UnifiedEpisode>[];
    for (final e in episodes) {
      final ep = UnifiedEpisode.tryFromJson(e);
      if (ep != null) parsed.add(ep);
    }
    return PlayLine(name: name, episodes: parsed);
  }
}

/// 一集可播地址。
class UnifiedEpisode {
  const UnifiedEpisode({
    required this.title,
    required this.url,
    required this.index,
  });
  final String title;
  final String url;
  final int index;

  Map<String, dynamic> toJson() => {'title': title, 'url': url, 'index': index};

  static UnifiedEpisode? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final url = raw['url'];
    if (title is! String || url is! String) return null;
    return UnifiedEpisode(
      title: title,
      url: url,
      index: (raw['index'] as num?)?.toInt() ?? 0,
    );
  }
}

/// 统一内模：红果与第三方源都适配成它，供详情/播放器/历史复用。
class UnifiedSeries {
  const UnifiedSeries({
    required this.sourceKey,
    required this.sourceItemId,
    required this.title,
    required this.normalizedTitle,
    this.year = '',
    this.coverUrl = '',
    this.remarks = '',
    this.description = '',
    this.lines = const [],
    this.headers = const {},
  });

  /// '' = 红果；否则为 [SourceConfig.id] 或 'bili'。
  final String sourceKey;

  /// 源内 id（CMS vod_id）。
  final String sourceItemId;
  final String title;
  final String normalizedTitle;
  final String year;
  final String coverUrl;
  final String remarks;
  final String description;
  final List<PlayLine> lines;
  final Map<String, String> headers;

  /// 历史/追剧的续播 key：红果保持裸 seriesId 兼容旧数据。
  String get historyKey =>
      sourceKey.isEmpty ? sourceItemId : '$sourceKey:$sourceItemId';

  /// 默认播放线路：集数最多；并列时先出现者优先（适配器已按 m3u8>mp4 排过）。
  PlayLine? get defaultLine {
    PlayLine? best;
    for (final line in lines) {
      if (best == null || line.episodes.length > best.episodes.length) {
        best = line;
      }
    }
    return best;
  }

  Map<String, dynamic> toJson() => {
        'source_key': sourceKey,
        'source_item_id': sourceItemId,
        'title': title,
        'normalized_title': normalizedTitle,
        'year': year,
        'cover_url': coverUrl,
        'remarks': remarks,
        'description': description,
        'lines': [for (final l in lines) l.toJson()],
        'headers': headers,
      };

  /// 详情快照容错解析：关键字段（title/sourceItemId）缺失返回 null，
  /// 其余字段缺失按空值（参照 PlaySkipEntry.tryFromJson 风格）。
  static UnifiedSeries? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final title = raw['title'];
    final itemId = raw['source_item_id'];
    if (title is! String || itemId is! String) return null;
    final linesRaw = raw['lines'];
    final lines = <PlayLine>[];
    if (linesRaw is List) {
      for (final l in linesRaw) {
        final line = PlayLine.tryFromJson(l);
        if (line != null) lines.add(line);
      }
    }
    final headersRaw = raw['headers'];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      headersRaw.forEach((k, v) {
        if (k is String && v is String) headers[k] = v;
      });
    }
    return UnifiedSeries(
      sourceKey: raw['source_key'] is String ? raw['source_key'] as String : '',
      sourceItemId: itemId,
      title: title,
      normalizedTitle:
          raw['normalized_title'] is String ? raw['normalized_title'] as String : title,
      year: raw['year'] is String ? raw['year'] as String : '',
      coverUrl: raw['cover_url'] is String ? raw['cover_url'] as String : '',
      remarks: raw['remarks'] is String ? raw['remarks'] as String : '',
      description:
          raw['description'] is String ? raw['description'] as String : '',
      lines: lines,
      headers: headers,
    );
  }
}

/// 搜索事件的统一口径：适配器把「任一页完成」即发事件，编排器先到先显示。
sealed class SourceSearchEvent {
  const SourceSearchEvent();
}

/// 一批命中（流式增量）。
class SourceHits extends SourceSearchEvent {
  const SourceHits({required this.items, required this.page, this.hasMore = false});
  final List<UnifiedSeries> items;
  final int page;
  final bool hasMore;
}

/// 该源搜索失败（计入健康，UI 显角标）。
class SourceSearchFailed extends SourceSearchEvent {
  const SourceSearchFailed(this.code, this.detail);
  final SourceExceptionCode code;
  final String detail;
}

/// 该源搜索结束（分页耗尽或取消）。
class SourceSearchDone extends SourceSearchEvent {
  const SourceSearchDone();
}

/// 源适配器契约。
abstract class SourceAdapter {
  String get id;
  String get name;
  SourceCaps get caps;

  /// 分类（cmsJson：ac=list，无 class 时回退扫 videolist 回收）。
  Future<List<SourceCategory>> categories();

  /// 分类浏览或首页列表（categoryId 为空即首页/最近更新）。
  Future<SourcePage<UnifiedSeries>> list({String? categoryId, required int page});

  /// 流式搜索：每页完成即发事件。
  Stream<SourceSearchEvent> search(String query, {int page = 1});

  /// 详情（含全部线路与分集）。
  Future<UnifiedSeries> detail(String sourceItemId);

  /// 探测一次可播地址（自检用）：返回首个可播 URL 或空串。
  Future<String> probePlayable({String? itemId});
}

/// 源层错误码 → 用户文案矩阵（错误处理契约：UI 只认 code，不显示 detail）。
enum SourceExceptionCode {
  decodeFailed('配置格式无法识别（已尝试明文/Base64/AES 解密）'),
  importUnsupported('该条目是爬虫源（jar/js），暂不支持导入'),
  importSsrf('已拒绝：源地址不允许指向本机'),
  marketFetchFailed('索引站无法访问，请检查网络或稍后再试'),
  marketJsRendered('该页面由脚本渲染，暂无法自动解析，请手动复制接口地址导入'),
  probeTimeout('检测超时'),
  probeFailed('检测失败'),
  endpointUnresolved('源接口无响应，已标记失败'),
  parseFailed('解析线路全部失败，已回退原始地址'),
  searchTimeout('搜索超时'),
  searchInvalid('源返回结构异常'),
  playFailed('播放失败，可尝试换线路或换源'),
  network('网络异常，请检查网络后重试');

  const SourceExceptionCode(this.friendlyText);
  final String friendlyText;
}

/// 源层异常：detail 仅进 ErrorLog，UI 只用 [code.friendlyText]。
class SourceException implements Exception {
  SourceException(this.code, [this.detail = '']);
  final SourceExceptionCode code;
  final String detail;

  String get friendlyText => code.friendlyText;

  @override
  String toString() => 'SourceException(${code.name}, $detail)';
}

/// 导入/扫描产出的候选源（尚未入库；入库时转 [SourceConfig]）。
class SourceCandidate {
  const SourceCandidate({
    required this.name,
    required this.api,
    this.kind = SourceKind.cmsJson,
    this.spiderKey,
    this.headers = const {},
    this.ext = '',
    this.note = '',
    this.unsupportedReason = '',
  });

  final String name;
  final String api;
  final SourceKind kind;
  final String? spiderKey;
  final Map<String, String> headers;

  /// TVBox sites[].ext（字符串或已 jsonEncode 的对象）。
  final String ext;

  /// 来源备注（哪个索引站/导入方式）。
  final String note;

  /// 非空 = 该条目不可用（spider 源待引擎 / .py 不支持等），入库时跳过并展示原因。
  final String unsupportedReason;

  bool get usable => unsupportedReason.isEmpty && api.isNotEmpty;
}

/// 一次导入/扫描的逐条报告。
class ImportReport {
  final List<SourceCandidate> added = [];
  final List<SourceCandidate> skipped = [];
  final List<String> failed = [];

  /// TVBox lives 直播配置（写入 LivesStore，不与点播源混存）。
  final List<LiveConfig> lives = [];

  void add(SourceCandidate c) => added.add(c);
  void skip(SourceCandidate c) => skipped.add(c);
  void fail(String reason) => failed.add(reason);
  void addLives(List<LiveConfig> configs) => lives.addAll(configs);

  bool get isEmpty => added.isEmpty && skipped.isEmpty && failed.isEmpty;
  bool get hasProblems => skipped.isNotEmpty || failed.isNotEmpty;
}

/// 取消令牌：源市场扫描 / 聚合搜索共用。
class CancelToken {
  bool _cancelled = false;
  final _completers = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final fn in List.of(_completers)) {
      fn();
    }
  }

  /// 注册取消回调（如关闭 http.Client）；令牌已取消时立即执行。
  void whenCancelled(void Function() fn) {
    if (_cancelled) {
      fn();
    } else {
      _completers.add(fn);
    }
  }
}

/// 源市场的索引站条目：存的是「接口清单页」地址，不是内容源；
/// 内容源永远由扫描/导入产生。
class MarketSite {
  MarketSite({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.builtin = false,
  });

  factory MarketSite.fromJson(Map<String, dynamic> json) => MarketSite(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        builtin: json['builtin'] as bool? ?? false,
      );

  final String id;
  final String name;
  final String url;
  bool enabled;
  final bool builtin;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'builtin': builtin,
      };
}

/// 预置索引站（用户可禁用/删除，可自行添加；App 不内置任何内容源地址）。
final List<MarketSite> builtinMarketSites = [
  MarketSite(
      id: 'm_zoo', name: 'Zoo 接口站', url: 'https://zoo.ink/tvbox.html', builtin: true),
  MarketSite(
      id: 'm_zhuiju', name: '追剧接口表', url: 'https://b.zhuiju.me/p/3', builtin: true),
  MarketSite(
      id: 'm_yue12', name: '十二月接口站', url: 'https://0.12yue.de5.net/', builtin: true),
  MarketSite(
      id: 'm_jsnzkpg',
      name: 'Jsnzkpg 加密仓',
      url:
          'https://gh-proxy.org/https://raw.githubusercontent.com/Jsnzkpg/Jsnzkpg/Jsnzkpg/Jsnzkpg',
      builtin: true),
];

/// 一个直播配置（TVBox lives 顶层条目）：保存的是频道清单 URL，
/// 频道列表在进入直播页时再拉取解析（lib/core/live/live_parser.dart）。
class LiveConfig {
  LiveConfig({
    required this.name,
    required this.url,
    this.note = '',
    this.epg = '',
  });

  final String name;
  final String url;

  /// 镜像/备注（TVBox lives url 可 `;` 分隔多镜像）。
  final String note;

  /// EPG 节目单地址（XMLTV/xml.gz，可空）。
  final String epg;
}

/// 提取 TVBox 顶层 `lives`（多形态：字符串 / {name,url} / url 数组 / `;` 多镜像）。
List<LiveConfig> extractLives(Map cfg, {String? sourceUrl}) {
  final lives = cfg['lives'];
  if (lives is! List) return const [];
  final out = <LiveConfig>[];
  for (final item in lives) {
    if (item is String && item.startsWith('http')) {
      out.add(LiveConfig(name: '直播源', url: item));
      continue;
    }
    if (item is! Map) continue;
    // 内嵌频道（无 url 有 group 列表）：暂不支持。
    if (item['url'] == null && item['urls'] == null) continue;
    final name = (item['name'] ?? item['group'] ?? '直播源').toString();
    final raw = item['url'] ?? item['urls'];
    final urls = <String>[];
    if (raw is String) {
      urls.addAll(raw
          .split(';')
          .map((u) => u.trim())
          .where((u) => u.startsWith('http')));
    } else if (raw is List) {
      urls.addAll(
          raw.map((u) => u.toString()).where((u) => u.startsWith('http')));
    }
    if (urls.isEmpty) continue;
    out.add(LiveConfig(
      name: name,
      url: urls.first,
      note: urls.length > 1 ? '镜像 ${urls.length - 1} 个' : '',
      epg: (item['epg'] ?? '').toString(),
    ));
  }
  return out;
}
