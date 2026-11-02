/// 随应用内置的**可用**书源（legado 规则，非远程仓库）。
///
/// 选源标准：公开页可直连（免登录、无 Cloudflare 人机校验）、搜索/详情/目录/正文
/// 四连可跑通。远程种子（XIU2/大灰狼等仓库）里的源大量已失效，用户扫一轮全是失败，
/// 因此这里只保留实测通过的少量源，其余交由用户自行导入。
///
/// 内置源可停用/删除，删掉后不再注入（`bookSource.builtinDismissed`）。
library;

import 'dart:convert';

import 'book_source_model.dart';

/// 内置源原始 JSON（便于与用户导入的 legado 源同格式往返）。
const List<String> builtinBookSourceJson = [
  '''
{
  "bookSourceUrl": "https://www.linovel.net",
  "bookSourceName": "轻之文库",
  "bookSourceGroup": "内置 · 免登录",
  "enabled": true,
  "searchUrl": "https://www.linovel.net/search/?kw={{key}}",
  "ruleSearch": {
    "bookList": "class.search-book",
    "name": "class.book-name@text",
    "author": "class.book-extra@text##丨[\\\\s\\\\S]*",
    "coverUrl": "class.book-cover@tag.img@src",
    "bookUrl": "href",
    "intro": "class.book-intro@text"
  },
  "ruleBookInfo": {
    "name": "class.book-title@text",
    "author": "class.book-extra@text##丨[\\\\s\\\\S]*",
    "coverUrl": "class.book-cover@tag.img@src",
    "intro": "class.about-text@text"
  },
  "ruleToc": {
    "chapterList": "class.chapter-list@tag.a",
    "chapterName": "text",
    "chapterUrl": "href"
  },
  "ruleContent": {
    "content": "class.article-text@html"
  }
}
''',
];

/// 解析成书源对象（坏 JSON 静默跳过：内置源坏一个不该影响启动）。
List<BookSource> builtinBookSources() {
  final out = <BookSource>[];
  for (final json in builtinBookSourceJson) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) {
        out.add(BookSource.fromJson(decoded));
      }
    } catch (_) {
      continue;
    }
  }
  return out;
}
