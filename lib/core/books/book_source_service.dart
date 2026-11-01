import 'dart:convert';

import 'book_source_model.dart';
import 'book_source_runtime.dart';
import 'so_novel_runtime.dart';
import 'so_novel_source.dart';

/// 书源服务门面：按 [BookSource.format] 分派到 legado 或 so-novel 运行时，
/// 对上层（聚合搜索/详情/阅读）暴露统一接口。可插拔多格式引擎的分派层。
class BookSourceService {
  BookSourceService({
    BookSourceRuntime? legado,
    SoNovelRuntime? soNovel,
  })  : _legado = legado ?? BookSourceRuntime(),
        _soNovel = soNovel ?? SoNovelRuntime();

  final BookSourceRuntime _legado;
  final SoNovelRuntime _soNovel;

  Future<List<BookHit>> search(BookSource source, String query) =>
      source.format == BookSourceFormat.soNovel
          ? _soNovel.search(_rule(source), query)
          : _legado.search(source, query);

  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    if (source.format == BookSourceFormat.soNovel) {
      final rule = _rule(source);
      final meta = await _soNovel.bookInfo(rule, bookUrl);
      final chapters = await _soNovel.toc(rule, bookUrl);
      return BookDetailData(
        name: meta.name,
        author: meta.author,
        intro: meta.intro,
        coverUrl: meta.coverUrl,
        chapters: chapters,
      );
    }
    final info = await _legado.bookInfo(source, bookUrl);
    return BookDetailData(
      name: info.name,
      author: info.author,
      intro: info.intro,
      coverUrl: info.coverUrl,
      chapters: info.chapters,
    );
  }

  Future<String> content(BookSource source, String chapterUrl) =>
      source.format == BookSourceFormat.soNovel
          ? _soNovel.content(_rule(source), chapterUrl)
          : _legado.content(source, chapterUrl);

  SoRule _rule(BookSource source) =>
      SoRule.fromJson(jsonDecode(source.rawRuleJson) as Map<String, dynamic>);
}

/// 详情聚合返回（两方言统一）。
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
