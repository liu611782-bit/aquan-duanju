import 'dart:convert';

import 'book_source_model.dart';

/// so-novel 方言内置种子：本任务两个 MVP 源，**逐字**摘自
/// so-novel v1.12.0 `bundle/rules/main.json`（本地参考仓库）。
///
/// 香书小说 = 纯 CSS/POST 形状；书海阁 = cookie + `:nth-of-type` + `~` 兄弟 +
/// 正文分页 `nextPage`。以原始 JSON 文本内嵌再 `jsonDecode`——正则转义与源仓库
/// 逐字一致，不经 Dart 字符串二次转义（research R9 教训）。
///
/// 站点可连性不归代码管（源健康度≠bug，见 book-source-rule-contract）；
/// 种子只是给用户一键可测的入口，失效可删。
const String _seedJson = r'''
[
  {
    "url": "http://www.ibiqugu.net/",
    "name": "香书小说",
    "comment": "",
    "search": {
      "url": "http://www.ibiqugu.net/modules/article/waps.php",
      "method": "post",
      "data": "{searchkey: %s}",
      "result": "#checkform > table > tbody > tr",
      "bookName": "td.even > a",
      "author": "td:nth-of-type(3)",
      "latestChapter": "td.odd > a",
      "lastUpdateTime": "td:nth-of-type(4)"
    },
    "book": {
      "latestChapter": "#info > p:nth-child(5) > a",
      "latestChapterUrl": "#info > p:nth-child(5) > a@href",
      "lastUpdateTime": "#info > p:nth-child(4)"
    },
    "toc": {
      "item": "#list > dl > dd > a"
    },
    "chapter": {
      "title": ".bookname > h1",
      "content": "#content",
      "paragraphTagClosed": false,
      "paragraphTag": "<br>+",
      "filterTxt": "一秒记住【文学巴士&nbsp;】，精彩无弹窗免费阅读！|(www.xbiquge.la 新笔趣阁)，高速全文字在线阅读！|天才一秒记住本站地址：.+。手机版阅读网址：m.|手机用户请浏览阅读，更优质的阅读体验。|天才壹秒記住.+，為您提供精彩小說閱讀。|\\(本章完\\)",
      "filterTag": "div, p, script"
    }
  },
  {
    "url": "https://www.shuhaige.net/",
    "name": "书海阁小说网",
    "comment": "部分书源正文段落顺序错乱的书在这里可能正常，搜索爬取过快会丢包(Unexpected end of file from server)",
    "search": {
      "url": "https://www.shuhaige.net/search.html",
      "method": "post",
      "data": "{searchkey: %s, searchtype: all}",
      "cookies": "waf_sc=''; HMACCOUNT=''",
      "result": "#sitembox > dl",
      "bookName": "dd > h3 > a",
      "author": "dd:nth-child(3) > span:nth-child(1)",
      "category": "dd:nth-child(3) > span:nth-child(3)",
      "latestChapter": "dd:nth-child(5) > a",
      "lastUpdateTime": "dd:nth-child(5) > span",
      "wordCount": "dd:nth-child(3) > span:nth-child(4)",
      "status": "dd:nth-child(3) > span:nth-child(2)",
      "nextPage": "#pagelink > a:not(.pgroup):not(.ngroup)"
    },
    "book": {
      "intro": "#intro > p:nth-child(1)"
    },
    "toc": {
      "item": "dl > dt:nth-of-type(2) ~ dd > a"
    },
    "chapter": {
      "title": ".bookname > h1",
      "content": "#content",
      "paragraphTagClosed": true,
      "filterTxt": "本小章还未完，请点击下一页继续阅读后面精彩内容！|小主，这个章节后面还有哦，请点击下一页继续阅读，后面更精彩！|这章没有结束，请点击下一页继续阅读！|喜欢(.+?)请大家收藏：\\(([^)]+)\\)\\1书海阁小说网更新速度全网最快。|\\(本章完\\)",
      "filterTag": ".bottem2, hr, script, table",
      "nextPage": "#pager_next"
    }
  }
]
''';

/// 内置 so-novel 种子（经 [BookSource.fromJson] 指纹识别成方言源，与其他导入同路）。
final List<BookSource> builtinSoNovelSources = [
  for (final raw in (jsonDecode(_seedJson) as List<dynamic>))
    BookSource.fromJson((raw as Map<String, dynamic>)),
];
