/// so-novel 书源模型（`Rule.java` 的 Dart 镜像，见 research §1）。
///
/// 真实书源文件是 **JSON 数组**（一个文件多源），严格 JSON（`rule-template.json5`
/// 带注释但不被加载）→ 直接 `jsonDecode` 后 [SoRule.fromJson]。字段照 so-novel
/// `model/Rule.java` 逐条对齐；未知字段（如 `search.intro`）忽略。
library;

class SoRule {
  const SoRule({
    required this.url,
    this.name = '',
    this.comment = '',
    this.language = '',
    this.needProxy = false,
    this.disabled = false,
    this.search,
    this.book = const SoBook(),
    this.toc = const SoToc(),
    this.chapter = const SoChapter(),
    this.crawl,
  });

  factory SoRule.fromJson(Map<String, dynamic> j) => SoRule(
        url: _s(j['url']),
        name: _s(j['name']),
        comment: _s(j['comment']),
        language: _s(j['language']),
        needProxy: j['needProxy'] == true,
        disabled: j['disabled'] == true,
        search: j['search'] is Map<String, dynamic>
            ? SoSearch.fromJson(j['search'] as Map<String, dynamic>)
            : null,
        book: SoBook.fromJson(_m(j['book'])),
        toc: SoToc.fromJson(_m(j['toc'])),
        chapter: SoChapter.fromJson(_m(j['chapter'])),
        crawl: j['crawl'] is Map<String, dynamic>
            ? SoCrawl.fromJson(j['crawl'] as Map<String, dynamic>)
            : null,
      );

  final String url;
  final String name;
  final String comment;
  final String language;
  final bool needProxy;
  final bool disabled;
  final SoSearch? search;
  final SoBook book;
  final SoToc toc;
  final SoChapter chapter;
  final SoCrawl? crawl;
}

class SoSearch {
  const SoSearch({
    this.disabled = false,
    this.baseUri = '',
    this.timeout,
    this.url = '',
    this.method = 'get',
    this.data = '',
    this.cookies = '',
    this.result = '',
    this.bookName = '',
    this.author = '',
    this.category = '',
    this.latestChapter = '',
    this.lastUpdateTime = '',
    this.status = '',
    this.wordCount = '',
    this.nextPage = '',
  });

  factory SoSearch.fromJson(Map<String, dynamic> j) => SoSearch(
        disabled: j['disabled'] == true,
        baseUri: _s(j['baseUri']),
        timeout: _i(j['timeout']),
        url: _s(j['url']),
        method: _s(j['method']).isEmpty ? 'get' : _s(j['method']),
        data: _s(j['data']),
        cookies: _s(j['cookies']),
        result: _s(j['result']),
        bookName: _s(j['bookName']),
        author: _s(j['author']),
        category: _s(j['category']),
        latestChapter: _s(j['latestChapter']),
        lastUpdateTime: _s(j['lastUpdateTime']),
        status: _s(j['status']),
        wordCount: _s(j['wordCount']),
        nextPage: _s(j['nextPage']),
      );

  final bool disabled;
  final String baseUri;
  final int? timeout;
  final String url;
  final String method;
  final String data;
  final String cookies;
  final String result;
  final String bookName;
  final String author;
  final String category;
  final String latestChapter;
  final String lastUpdateTime;
  final String status;
  final String wordCount;
  final String nextPage;
}

class SoBook {
  const SoBook({
    this.baseUri = '',
    this.timeout,
    this.url = '',
    this.bookName = '',
    this.author = '',
    this.intro = '',
    this.category = '',
    this.coverUrl = '',
    this.latestChapter = '',
    this.latestChapterUrl = '',
    this.lastUpdateTime = '',
    this.status = '',
  });

  factory SoBook.fromJson(Map<String, dynamic> j) => SoBook(
        baseUri: _s(j['baseUri']),
        timeout: _i(j['timeout']),
        url: _s(j['url']),
        bookName: _s(j['bookName']),
        author: _s(j['author']),
        intro: _s(j['intro']),
        category: _s(j['category']),
        coverUrl: _s(j['coverUrl']),
        latestChapter: _s(j['latestChapter']),
        latestChapterUrl: _s(j['latestChapterUrl']),
        lastUpdateTime: _s(j['lastUpdateTime']),
        status: _s(j['status']),
      );

  final String baseUri;
  final int? timeout;
  final String url;
  final String bookName;
  final String author;
  final String intro;
  final String category;
  final String coverUrl;
  final String latestChapter;
  final String latestChapterUrl;
  final String lastUpdateTime;
  final String status;
}

class SoToc {
  const SoToc({
    this.baseUri = '',
    this.timeout,
    this.url = '',
    this.list = '',
    this.item = '',
    this.isDesc = false,
    this.nextPage = '',
  });

  factory SoToc.fromJson(Map<String, dynamic> j) => SoToc(
        baseUri: _s(j['baseUri']),
        timeout: _i(j['timeout']),
        url: _s(j['url']),
        list: _s(j['list']),
        item: _s(j['item']),
        isDesc: j['isDesc'] == true,
        nextPage: _s(j['nextPage']),
      );

  final String baseUri;
  final int? timeout;
  final String url;
  final String list;
  final String item;
  final bool isDesc;
  final String nextPage;
}

class SoChapter {
  const SoChapter({
    this.baseUri = '',
    this.timeout,
    this.title = '',
    this.content = '',
    this.paragraphTagClosed = false,
    this.paragraphTag = '',
    this.filterTxt = '',
    this.filterTag = '',
    this.nextPage = '',
    this.nextPageInJs = '',
    this.nextChapterLink = '',
  });

  factory SoChapter.fromJson(Map<String, dynamic> j) => SoChapter(
        baseUri: _s(j['baseUri']),
        timeout: _i(j['timeout']),
        title: _s(j['title']),
        content: _s(j['content']),
        paragraphTagClosed: j['paragraphTagClosed'] == true,
        paragraphTag: _s(j['paragraphTag']),
        filterTxt: _s(j['filterTxt']),
        filterTag: _s(j['filterTag']),
        nextPage: _s(j['nextPage']),
        nextPageInJs: _s(j['nextPageInJs']),
        nextChapterLink: _s(j['nextChapterLink']),
      );

  final String baseUri;
  final int? timeout;
  final String title;
  final String content;
  final bool paragraphTagClosed;
  final String paragraphTag;
  final String filterTxt;
  final String filterTag;
  final String nextPage;
  final String nextPageInJs;
  final String nextChapterLink;
}

class SoCrawl {
  const SoCrawl({
    this.concurrency,
    this.minInterval,
    this.maxInterval,
    this.maxAttempts,
    this.retryMinInterval,
    this.retryMaxInterval,
  });

  factory SoCrawl.fromJson(Map<String, dynamic> j) => SoCrawl(
        concurrency: _i(j['concurrency']),
        minInterval: _i(j['minInterval']),
        maxInterval: _i(j['maxInterval']),
        maxAttempts: _i(j['maxAttempts']),
        retryMinInterval: _i(j['retryMinInterval']),
        retryMaxInterval: _i(j['retryMaxInterval']),
      );

  final int? concurrency;
  final int? minInterval;
  final int? maxInterval;
  final int? maxAttempts;
  final int? retryMinInterval;
  final int? retryMaxInterval;
}

String _s(Object? v) => v?.toString() ?? '';
int? _i(Object? v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}');
Map<String, dynamic> _m(Object? v) =>
    v is Map<String, dynamic> ? v : const <String, dynamic>{};
