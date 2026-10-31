/// legado（阅读3.0）书源模型——本项目支持的字段子集。
///
/// 只取「搜书 → 详情 → 目录 → 正文」链路必需的字段；`js:` 一类脚本规则
/// 明确不支持，靠 [requiresJs] 识别后在导入校验时诚实拒绝。
class BookSource {
  const BookSource({
    this.url = '',
    this.name = '',
    this.group = '',
    this.enabled = true,
    this.searchUrl = '',
    this.ruleSearch = const BookRuleGroup.empty(),
    this.ruleBookInfo = const BookRuleGroup.empty(),
    this.ruleToc = const BookTocRule.empty(),
    this.ruleContent = const BookContentRule.empty(),
  });

  /// 书源自身地址（legado `bookSourceUrl`，作唯一键）。
  final String url;
  final String name;
  final String group;
  final bool enabled;

  /// 搜索地址：`url` 或 `url,{ "method":"POST", "body":"..." }`。
  final String searchUrl;
  final BookRuleGroup ruleSearch;
  final BookRuleGroup ruleBookInfo;
  final BookTocRule ruleToc;
  final BookContentRule ruleContent;

  /// 规则里出现 `js:` / `<js>` / `@js:` / 内嵌 `{{...js}}` → 本引擎不支持。
  bool get requiresJs {
    final all = [
      searchUrl,
      ...ruleSearch.values,
      ...ruleBookInfo.values,
      ...ruleToc.values,
      ...ruleContent.values,
    ];
    for (final rule in all) {
      if (_jsPattern.hasMatch(rule)) return true;
    }
    return false;
  }

  static final RegExp _jsPattern =
      RegExp(r'js:|<js>|@js:', caseSensitive: false);

  String get id => url;

  factory BookSource.fromJson(Map<String, dynamic> json) {
    Map<String, dynamic> group(Object? raw) =>
        raw is Map<String, dynamic> ? raw : const {};
    return BookSource(
      url: json['bookSourceUrl']?.toString() ?? '',
      name: json['bookSourceName']?.toString() ?? '',
      group: json['bookSourceGroup']?.toString() ?? '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      searchUrl: json['searchUrl']?.toString() ?? '',
      ruleSearch: BookRuleGroup.fromJson(group(json['ruleSearch'])),
      ruleBookInfo: BookRuleGroup.fromJson(group(json['ruleBookInfo'])),
      ruleToc: BookTocRule.fromJson(group(json['ruleToc'])),
      ruleContent: BookContentRule.fromJson(group(json['ruleContent'])),
    );
  }

  /// 一个文件可能给单个书源对象，也可能给数组/带 `bookSourceUrl` 键的包装。
  static List<BookSource> listFromJson(Object? raw) {
    if (raw is List) {
      return [
        for (final item in raw)
          if (item is Map<String, dynamic>) BookSource.fromJson(item),
      ];
    }
    if (raw is Map<String, dynamic>) {
      // legado 分享格式偶见 {"bookSourceUrl": ...} 顶层单对象。
      if (raw.containsKey('bookSourceUrl')) return [BookSource.fromJson(raw)];
      // 或 {"bookSources": [...]} 包装。
      final wrapped = raw['bookSources'];
      if (wrapped is List) return listFromJson(wrapped);
    }
    return const [];
  }

  Map<String, dynamic> toJson() => {
        'bookSourceUrl': url,
        'bookSourceName': name,
        'bookSourceGroup': group,
        'enabled': enabled,
        'searchUrl': searchUrl,
        'ruleSearch': ruleSearch.toJson(),
        'ruleBookInfo': ruleBookInfo.toJson(),
        'ruleToc': ruleToc.toJson(),
        'ruleContent': ruleContent.toJson(),
      };
}

/// 搜索/详情共用的字段规则组（字段名 → 规则字符串）。
class BookRuleGroup {
  const BookRuleGroup({
    this.bookList = '',
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.bookUrl = '',
    this.kind = '',
    this.lastChapter = '',
    this.tocUrl = '',
  });

  final String bookList;
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String bookUrl;
  final String kind;
  final String lastChapter;

  /// 详情规则组的目录页地址（空 = 与详情同页）。
  final String tocUrl;

  const BookRuleGroup.empty() : this();

  factory BookRuleGroup.fromJson(Map<String, dynamic> json) => BookRuleGroup(
        bookList: json['bookList']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        author: json['author']?.toString() ?? '',
        coverUrl: json['coverUrl']?.toString() ?? '',
        intro: json['intro']?.toString() ?? '',
        bookUrl: json['bookUrl']?.toString() ?? '',
        kind: json['kind']?.toString() ?? '',
        lastChapter: json['lastChapter']?.toString() ?? '',
        tocUrl: json['tocUrl']?.toString() ?? '',
      );

  List<String> get values => [
        bookList,
        name,
        author,
        coverUrl,
        intro,
        bookUrl,
        kind,
        lastChapter,
        tocUrl,
      ];

  Map<String, dynamic> toJson() => {
        'bookList': bookList,
        'name': name,
        'author': author,
        'coverUrl': coverUrl,
        'intro': intro,
        'bookUrl': bookUrl,
        'kind': kind,
        'lastChapter': lastChapter,
        'tocUrl': tocUrl,
      };
}

/// 目录规则组。
class BookTocRule {
  const BookTocRule({
    this.chapterList = '',
    this.chapterName = '',
    this.chapterUrl = '',
    this.isVolume = '',
    this.updateTime = '',
  });

  final String chapterList;
  final String chapterName;
  final String chapterUrl;
  final String isVolume;
  final String updateTime;

  const BookTocRule.empty() : this();

  factory BookTocRule.fromJson(Map<String, dynamic> json) => BookTocRule(
        chapterList: json['chapterList']?.toString() ?? '',
        chapterName: json['chapterName']?.toString() ?? '',
        chapterUrl: json['chapterUrl']?.toString() ?? '',
        isVolume: json['isVolume']?.toString() ?? '',
        updateTime: json['updateTime']?.toString() ?? '',
      );

  List<String> get values =>
      [chapterList, chapterName, chapterUrl, isVolume, updateTime];

  Map<String, dynamic> toJson() => {
        'chapterList': chapterList,
        'chapterName': chapterName,
        'chapterUrl': chapterUrl,
        'isVolume': isVolume,
        'updateTime': updateTime,
      };
}

/// 正文规则组。
class BookContentRule {
  const BookContentRule({this.content = '', this.nextContentUrl = ''});

  final String content;

  /// 下一页正文地址（长章节分页）；空 = 单页正文。
  final String nextContentUrl;

  const BookContentRule.empty() : this();

  factory BookContentRule.fromJson(Map<String, dynamic> json) =>
      BookContentRule(
        content: json['content']?.toString() ?? '',
        nextContentUrl: json['nextContentUrl']?.toString() ?? '',
      );

  List<String> get values => [content, nextContentUrl];

  Map<String, dynamic> toJson() => {
        'content': content,
        'nextContentUrl': nextContentUrl,
      };
}

/// 校验/搜索共用的书条目。
class BookHit {
  const BookHit({
    this.bookUrl = '',
    this.name = '',
    this.author = '',
    this.coverUrl = '',
    this.intro = '',
    this.kind = '',
    this.lastChapter = '',
  });

  final String bookUrl;
  final String name;
  final String author;
  final String coverUrl;
  final String intro;
  final String kind;
  final String lastChapter;

  bool get isMeaningful => name.trim().isNotEmpty && bookUrl.trim().isNotEmpty;
}

/// 一章目录项。
class BookTocItem {
  const BookTocItem({this.title = '', this.url = '', this.isVolume = false});

  final String title;
  final String url;
  final bool isVolume;
}

/// 校验结果：停在哪一级、为什么。
class BookSourceCheck {
  const BookSourceCheck({
    required this.source,
    required this.ok,
    this.stage = BookCheckStage.none,
    this.reason = '',
    this.sampleHit,
    this.sampleChapterCount = 0,
    this.sampleContentLength = 0,
  });

  final BookSource source;
  final bool ok;
  final BookCheckStage stage;
  final String reason;
  final BookHit? sampleHit;
  final int sampleChapterCount;
  final int sampleContentLength;
}

enum BookCheckStage { none, search, bookInfo, content }
