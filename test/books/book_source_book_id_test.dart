/// 第三方书源书籍 id（`booksrc:<源url>:<书url>`）的还原规则。
///
/// 「最近在读 / 书架」重开这类书只能靠这段前缀匹配：源 url 与书 url 都含 `://`，
/// 按冒号硬拆必然拆错，所以这里把匹配规则钉死。
library;

import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const sourceA = BookSource(url: 'https://a.example', name: 'A');
  const sourceB = BookSource(url: 'https://a.example/sub', name: 'B');

  test('拼出的 id 与阅读器口径一致，且能原样还原书 URL', () {
    final id = bookSourceBookId(sourceA, 'https://a.example/book/1.html');
    expect(id, 'booksrc:https://a.example:https://a.example/book/1.html');

    expect(bookSourceOf(const [sourceA, sourceB], id)?.url, sourceA.url);
    expect(
      bookUrlOf(sourceA, id),
      'https://a.example/book/1.html',
      reason: '书 URL 里的 :// 不能被当成分隔符',
    );
  });

  test('多个源 url 互为前缀时取更长的那个', () {
    final id = bookSourceBookId(sourceB, 'https://b.example/x');
    expect(bookSourceOf(const [sourceA, sourceB], id)?.url, sourceB.url);
  });

  test('前缀必须严格到冒号：相似但不同的源不匹配', () {
    final id = bookSourceBookId(sourceA, 'https://a.example/book/1');
    // sourceB 的 url 是 sourceA 的子路径，不能反过来说 sourceA 匹配 sourceB 的书。
    expect(bookSourceOf(const [sourceB], id), isNull);
    expect(bookUrlOf(sourceB, id), isNull);
  });

  test('书源被删（源表里没有）→ 还原失败，调用方据此给明确文案', () {
    final id = bookSourceBookId(sourceA, 'https://a.example/book/1');
    expect(bookSourceOf(const <BookSource>[], id), isNull);
    expect(bookSourceOf(const [sourceB], id), isNull);
  });

  test('非 booksrc id（番茄数字 id / local:）一律不碰', () {
    expect(bookSourceOf(const [sourceA], '7001'), isNull);
    expect(bookSourceOf(const [sourceA], 'local:abc'), isNull);
  });
}
