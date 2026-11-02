import 'dart:convert';

/// 书源方言（可插拔多格式引擎的第一层：按格式分派到对应 provider/runtime）。
///
/// 新增方言只需：枚举加值 + 写一个 `BookSourceProvider` 并注册，分派代码不动。
enum BookSourceFormat {
  /// legado（阅读3.0）规则源，走 `BookSourceRuntime`。
  legado,

  /// so-novel 规则源（`rawRuleJson` 承载原样 JSON），走 `SoNovelRuntime`。
  soNovel,

  /// 内置站点 provider（轻小说文库 Wenku8），公开页只读。
  wenku8,

  /// 本地导入书（虚拟源，`bookUrl = localbook:<id>`）。
  local;

  /// 持久化字符串 → 枚举；未知值回落 [legado]（历史数据兼容）。
  static BookSourceFormat parse(Object? name) {
    for (final v in values) {
      if (v.name == name) return v;
    }
    return legado;
  }
}

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
    this.jsLib = '',
    this.format = BookSourceFormat.legado,
    this.rawRuleJson = '',
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

  /// 共享 JS 库（legado `jsLib`）：大量真实源的函数定义在此；js 求值前注入全局。
  /// 仅支持文本形态；`{name:url}` 远程形态诚实拒绝（供应链风险，见 spec）。
  final String jsLib;

  /// 方言：legado 走 `BookSourceRuntime`；soNovel 走 `SoNovelRuntime`（用 [rawRuleJson]）。
  final BookSourceFormat format;

  /// so-novel 等方言的原样源 JSON（format != legado 时非空，供专用运行时解析）。
  final String rawRuleJson;

  /// 规则里出现 `js:` / `<js>` / `@js:` / 内嵌 `{{...js}}` → 本引擎不支持。
  bool get requiresJs {
    // 只有 legado 方言用本工程的 js 规则语法；其它方言各自处理（so-novel 自带 @js:、
    // wenku8 内置解析、local 无规则），不得把关卡套到它们头上。
    if (format != BookSourceFormat.legado) return false;
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

  /// 换启用态重建（市场导入：可用即启用、失败源导入但停用）。
  BookSource copyWithEnabled(bool enabled) => BookSource(
        url: url,
        name: name,
        group: group,
        enabled: enabled,
        searchUrl: searchUrl,
        ruleSearch: ruleSearch,
        ruleBookInfo: ruleBookInfo,
        ruleToc: ruleToc,
        ruleContent: ruleContent,
        jsLib: jsLib,
        format: format,
        rawRuleJson: rawRuleJson,
      );

  factory BookSource.fromJson(Map<String, dynamic> json) {
    // so-novel 方言指纹：无 bookSourceUrl，但有 url + search/toc/chapter 之一。
    if (!json.containsKey('bookSourceUrl') &&
        json.containsKey('url') &&
        (json.containsKey('search') ||
            json.containsKey('toc') ||
            json.containsKey('chapter'))) {
      return BookSource(
        url: json['url']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        enabled: json['disabled'] != true,
        format: BookSourceFormat.soNovel,
        rawRuleJson: jsonEncode(json),
      );
    }
    Map<String, dynamic> group(Object? raw) =>
        raw is Map<String, dynamic> ? raw : const {};
    return BookSource(
      url: json['bookSourceUrl']?.toString() ?? '',
      name: json['bookSourceName']?.toString() ?? '',
      group: json['bookSourceGroup']?.toString() ?? '',
      enabled: json['enabled'] is bool ? json['enabled'] as bool : true,
      searchUrl: json['searchUrl']?.toString() ?? '',
      format: BookSourceFormat.parse(json['aquanFormat']),
      ruleSearch: BookRuleGroup.fromJson(group(json['ruleSearch'])),
      ruleBookInfo: BookRuleGroup.fromJson(group(json['ruleBookInfo'])),
      ruleToc: BookTocRule.fromJson(group(json['ruleToc'])),
      ruleContent: BookContentRule.fromJson(group(json['ruleContent'])),
      jsLib: json['jsLib']?.toString() ?? '',
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
      // so-novel 单对象（无 bookSourceUrl，有 url + search/toc/chapter 指纹）。
      if (!raw.containsKey('bookSourceUrl') &&
          raw.containsKey('url') &&
          (raw.containsKey('search') ||
              raw.containsKey('toc') ||
              raw.containsKey('chapter'))) {
        return [BookSource.fromJson(raw)];
      }
      // 或 {"bookSources": [...]} 包装。
      final wrapped = raw['bookSources'];
      if (wrapped is List) return listFromJson(wrapped);
    }
    return const [];
  }

  Map<String, dynamic> toJson() {
    if (format == BookSourceFormat.soNovel) {
      // 原样回写 so-novel Rule（含 search/toc/chapter 指纹，fromJson 会重新识别）；
      // 启用态落回 so-novel 自带的 `disabled` 字段做往返（否则停用状态重启即丢）。
      Map<String, dynamic> out;
      try {
        final decoded = jsonDecode(rawRuleJson);
        out = decoded is Map<String, dynamic>
            ? decoded
            : <String, dynamic>{'url': url, 'name': name};
      } catch (_) {
        out = <String, dynamic>{'url': url, 'name': name};
      }
      out['disabled'] = !enabled;
      return out;
    }
    return {
        'bookSourceUrl': url,
        'bookSourceName': name,
        'bookSourceGroup': group,
        'enabled': enabled,
        'searchUrl': searchUrl,
        'ruleSearch': ruleSearch.toJson(),
        'ruleBookInfo': ruleBookInfo.toJson(),
        'ruleToc': ruleToc.toJson(),
        'ruleContent': ruleContent.toJson(),
        if (jsLib.isNotEmpty) 'jsLib': jsLib,
        // 方言往返：legado 键名与其它方言不相交，靠显式字段保真（本地/内置源必需）。
        if (format != BookSourceFormat.legado) 'aquanFormat': format.name,
      };
  }
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

/// 详情聚合返回（**所有方言统一的数据面**）。
///
/// 由各 provider 的 `detail` 产出，上层（详情页/阅读器）只认这个类型。
class BookDetailData {
  const BookDetailData({
    this.name = '',
    this.author = '',
    this.intro = '',
    this.coverUrl = '',
    this.chapters = const [],
  });

  final String name;
  final String author;
  final String intro;
  final String coverUrl;
  final List<BookTocItem> chapters;
}
