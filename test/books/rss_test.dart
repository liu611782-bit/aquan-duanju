import 'dart:convert';

import 'package:aquan_duanju/core/rss/rss_feed.dart';
import 'package:aquan_duanju/core/rss/rss_models.dart';
import 'package:aquan_duanju/core/rss/rss_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _rss = '''
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>测试源</title>
<item><title>第一篇</title><link>https://a.example/1</link>
  <pubDate>Mon, 02 Nov 2026</pubDate>
  <description>&lt;p&gt;摘要一&lt;/p&gt;</description>
  <content:encoded>&lt;p&gt;正文一&lt;/p&gt;&lt;p&gt;第二段&lt;/p&gt;</content:encoded>
</item>
<item><title>第二篇</title><link>https://a.example/2</link></item>
</channel></rss>''';

const _atom = '''
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom 源</title>
<entry><title>Atom 文章</title><link href="https://b.example/x"/>
<updated>2026-11-02T10:00:00Z</updated>
<summary>摘要</summary><content>正文内容</content></entry>
</feed>''';

void main() {
  group('RSS/Atom 解析', () {
    test('RSS 2.0：标题/链接/正文/摘要', () {
      final items = parseRssArticles(_rss);
      expect(items, hasLength(2));
      expect(items.first.title, '第一篇');
      expect(items.first.link, 'https://a.example/1');
      expect(items.first.content, contains('正文一'));
      expect(items.first.summary, '摘要一');
      expect(items.last.title, '第二篇');
    });

    test('Atom：link href 与 content', () {
      final items = parseRssArticles(_atom);
      expect(items.single.title, 'Atom 文章');
      expect(items.single.link, 'https://b.example/x');
      expect(items.single.content, contains('正文内容'));
    });

    test('不是 XML / 无条目 → RssException', () {
      expect(() => parseRssArticles('not xml'), throwsA(isA<RssException>()));
      expect(
        () => parseRssArticles('<rss><channel></channel></rss>'),
        throwsA(isA<RssException>()),
      );
    });
  });

  group('网页规则订阅源', () {
    test('ruleArticles 选出条目，子规则取标题/链接并补全绝对地址', () {
      const page = '''
<div id="content">
  <h3><a href="/book/1.html">第一条</a></h3>
  <h3><a href="https://x.example/2.html">第二条</a></h3>
</div>''';
      const source = RssSource(
        url: 'https://site.example/list',
        name: '规则源',
        ruleArticles: 'id.content@h3',
        ruleTitle: 'a@textNodes',
        ruleLink: 'a@href',
      );
      final items = parseRuleBasedArticles(source, page);
      expect(items, hasLength(2));
      expect(items.first.title, '第一条');
      expect(items.first.link, 'https://site.example/book/1.html');
      expect(items.last.link, 'https://x.example/2.html');
    });

    test('规则匹配不到 → RssException（不静默返回空）', () {
      const source = RssSource(
        url: 'https://site.example/list',
        name: '规则源',
        ruleArticles: 'id.nope@h3',
      );
      expect(
        () => parseRuleBasedArticles(source, '<html><body></body></html>'),
        throwsA(isA<RssException>()),
      );
    });
  });

  group('订阅源仓库', () {
    // 关掉内置订阅源注入，让用例只考察导入/去重/已读。
    setUp(() => SharedPreferences.setMockInitialValues({'rss.seeded.v1': true}));

    test('导入 legado rssSource 数组，按 url 去重', () async {
      final store = RssStore(await SharedPreferences.getInstance());
      await store.ensureLoaded();
      final json = jsonEncode([
        {'sourceUrl': 'https://a.example/rss', 'sourceName': 'A', 'sourceGroup': 'G'},
        {'sourceUrl': 'https://a.example/rss', 'sourceName': '重复'},
        {'sourceName': '没有地址'},
      ]);
      expect(await store.importJson(json), 1);
      expect(await store.importJson(json), 0);
      expect(store.sources.single.name, 'A');
    });

    test('已读状态持久化', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RssStore(prefs);
      await store.ensureLoaded();
      await store.markRead('https://a.example/1');
      expect(store.isRead('https://a.example/1'), isTrue);

      final reopened = RssStore(prefs);
      await reopened.ensureLoaded();
      expect(reopened.isRead('https://a.example/1'), isTrue);
    });

    test('RssSource 往返 + 启停', () {
      const source = RssSource(
        url: 'https://a.example/rss',
        name: 'A',
        group: 'G',
        header: '{"Referer":"https://a.example"}',
      );
      final restored = RssSource.fromJson(source.toJson());
      expect(restored.url, source.url);
      expect(restored.header, source.header);
      expect(restored.copyWith(enabled: false).enabled, isFalse);
    });
  });
}
