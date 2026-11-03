/// 阅读进度补封面：只补空封面，绝不动进度/序号/时间。
///
/// 背景：第三方书源的书籍进阅读器时还拿不到封面，历史记录里是空串；
/// 详情页拿到封面后要能回填，但不能把自己当成一次新的阅读。
library;

import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late ReadingProgressStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reading_cover');
    store = ReadingProgressStore(testDirectory: tmp);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  Future<void> record({required String coverUrl}) => store.record(
    bookId: 'booksrc:https://a.example:https://a.example/book/1',
    title: '一本书',
    coverUrl: coverUrl,
    chapterId: 'https://a.example/c/3',
    chapterTitle: '第三章',
    chapterIndex: 2,
    chapters: 10,
    offset: 0.42,
    charOffset: 120,
  );

  test('补空封面：进度、序号、更新时间全部原样', () async {
    await record(coverUrl: '');
    final before = store.entry('booksrc:https://a.example:https://a.example/book/1')!;
    expect(before.coverUrl, isEmpty);

    final filled = await store.fillCover(
      'booksrc:https://a.example:https://a.example/book/1',
      'https://img.example/cover.jpg',
    );
    expect(filled, isTrue);

    final after = store.entry('booksrc:https://a.example:https://a.example/book/1')!;
    expect(after.coverUrl, 'https://img.example/cover.jpg');
    expect(after.chapterIndex, before.chapterIndex);
    expect(after.chapterId, before.chapterId);
    expect(after.chapterTitle, before.chapterTitle);
    expect(after.offset, before.offset);
    expect(after.charOffset, before.charOffset);
    expect(after.revision, before.revision, reason: '补封面不是一次新阅读，不许抬序号');
    expect(after.updatedAt, before.updatedAt, reason: '不许把书顶到「最近在读」最前');
  });

  test('已有封面不覆盖', () async {
    await record(coverUrl: 'https://img.example/old.jpg');
    final filled = await store.fillCover(
      'booksrc:https://a.example:https://a.example/book/1',
      'https://img.example/new.jpg',
    );
    expect(filled, isFalse);
    expect(
      store.entry('booksrc:https://a.example:https://a.example/book/1')!.coverUrl,
      'https://img.example/old.jpg',
    );
  });

  test('没有记录 / 空封面地址：不写入、不报错', () async {
    expect(await store.fillCover('nope', 'https://img.example/x.jpg'), isFalse);
    await record(coverUrl: '');
    expect(await store.fillCover('booksrc:https://a.example:https://a.example/book/1', '  '),
        isFalse);
  });
}
