/// RSS 订阅源与文章模型（legado `rssSource` 子集）。
library;

/// 订阅源。
class RssSource {
  const RssSource({
    required this.url,
    required this.name,
    this.group = '',
    this.enabled = true,
    this.header = '',
    this.ruleArticles = '',
    this.ruleTitle = '',
    this.ruleLink = '',
    this.ruleContent = '',
  });

  factory RssSource.fromJson(Map<String, dynamic> json) => RssSource(
        url: (json['sourceUrl'] ?? json['url'] ?? '').toString(),
        name: (json['sourceName'] ?? json['name'] ?? '').toString(),
        group: (json['sourceGroup'] ?? json['group'] ?? '').toString(),
        enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
        header: (json['header'] ?? '').toString(),
        ruleArticles: (json['ruleArticles'] ?? '').toString(),
        ruleTitle: (json['ruleTitle'] ?? '').toString(),
        ruleLink: (json['ruleLink'] ?? '').toString(),
        ruleContent: (json['ruleContent'] ?? '').toString(),
      );

  final String url;
  final String name;
  final String group;
  final bool enabled;

  /// 附加请求头（JSON 字符串；解析失败则忽略）。
  final String header;

  /// 网页规则订阅源（legado `ruleArticles` 等）：非空则按 CSS/JSON 规则抓列表，
  /// 而不是按 RSS/Atom 解析。喵公子 `DY.json` 这类源就是这种形态。
  final String ruleArticles;
  final String ruleTitle;
  final String ruleLink;
  final String ruleContent;

  bool get isRuleBased => ruleArticles.trim().isNotEmpty;

  Map<String, dynamic> toJson() => {
        'sourceUrl': url,
        'sourceName': name,
        'sourceGroup': group,
        'enabled': enabled,
        if (header.isNotEmpty) 'header': header,
        if (ruleArticles.isNotEmpty) 'ruleArticles': ruleArticles,
        if (ruleTitle.isNotEmpty) 'ruleTitle': ruleTitle,
        if (ruleLink.isNotEmpty) 'ruleLink': ruleLink,
        if (ruleContent.isNotEmpty) 'ruleContent': ruleContent,
      };

  RssSource copyWith({bool? enabled, String? name}) => RssSource(
        url: url,
        name: name ?? this.name,
        group: group,
        enabled: enabled ?? this.enabled,
        header: header,
        ruleArticles: ruleArticles,
        ruleTitle: ruleTitle,
        ruleLink: ruleLink,
        ruleContent: ruleContent,
      );
}

/// 一篇文章。
class RssArticle {
  const RssArticle({
    required this.title,
    required this.link,
    this.published = '',
    this.summary = '',
    this.content = '',
  });

  final String title;
  final String link;
  final String published;

  /// 摘要（列表用，纯文本）。
  final String summary;

  /// 正文（HTML 或纯文本，阅读页再切段）。
  final String content;

  String get id => link.isEmpty ? title : link;
}
