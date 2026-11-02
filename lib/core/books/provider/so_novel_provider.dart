/// so-novel 方言 provider：把 [SoNovelRuntime] 的四连适配到统一数据面。
library;

import 'dart:convert';

import '../book_source_model.dart';
import '../so_novel_runtime.dart';
import '../so_novel_source.dart';
import 'book_source_provider.dart';
import 'source_probe.dart';

class SoNovelProvider implements BookSourceProvider {
  SoNovelProvider({SoNovelRuntime? runtime})
      : runtime = runtime ?? SoNovelRuntime();

  final SoNovelRuntime runtime;

  @override
  BookSourceFormat get format => BookSourceFormat.soNovel;

  @override
  String get displayName => 'so-novel';

  @override
  bool get builtin => false;

  @override
  List<BookSource> get builtinSources => const <BookSource>[];

  @override
  Future<List<BookHit>> search(BookSource source, String query, {int page = 1}) =>
      runtime.search(ruleOf(source), query);

  @override
  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    final rule = ruleOf(source);
    final meta = await runtime.bookInfo(rule, bookUrl);
    final chapters = await runtime.toc(rule, bookUrl);
    return BookDetailData(
      name: meta.name,
      author: meta.author,
      intro: meta.intro,
      coverUrl: meta.coverUrl,
      chapters: chapters,
    );
  }

  @override
  Future<String> content(BookSource source, String chapterUrl) =>
      runtime.content(ruleOf(source), chapterUrl);

  @override
  Future<BookSourceCheck> probe(
    BookSource source, {
    String query = kDefaultProbeQuery,
    bool fetchContent = true,
  }) =>
      probeSoNovel(runtime, source, query: query, fetchContent: fetchContent);

  /// 从 `rawRuleJson` 还原 so-novel 规则对象。
  static SoRule ruleOf(BookSource source) {
    final raw = jsonDecode(source.rawRuleJson);
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('so-novel 源缺少规则对象（rawRuleJson）');
    }
    return SoRule.fromJson(raw);
  }
}
