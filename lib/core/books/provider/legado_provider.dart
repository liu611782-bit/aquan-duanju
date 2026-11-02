/// legado（阅读3.0）方言 provider：把 [BookSourceRuntime] 的四连适配到统一数据面。
library;

import '../book_source_model.dart';
import '../book_source_runtime.dart';
import 'book_source_provider.dart';
import 'source_probe.dart';

class LegadoProvider implements BookSourceProvider {
  LegadoProvider({BookSourceRuntime? runtime})
      : runtime = runtime ?? BookSourceRuntime();

  /// 运行时（可注入：测试用 `enforceSsrf: false` + 本地 HttpServer）。
  final BookSourceRuntime runtime;

  @override
  BookSourceFormat get format => BookSourceFormat.legado;

  @override
  String get displayName => 'legado';

  @override
  bool get builtin => false;

  @override
  List<BookSource> get builtinSources => const <BookSource>[];

  @override
  Future<List<BookHit>> search(BookSource source, String query, {int page = 1}) =>
      runtime.search(source, query, page: page);

  @override
  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    final info = await runtime.bookInfo(source, bookUrl);
    return BookDetailData(
      name: info.name,
      author: info.author,
      intro: info.intro,
      coverUrl: info.coverUrl,
      chapters: info.chapters,
    );
  }

  @override
  Future<String> content(BookSource source, String chapterUrl) =>
      runtime.content(source, chapterUrl);

  @override
  Future<BookSourceCheck> probe(
    BookSource source, {
    String query = kDefaultProbeQuery,
    bool fetchContent = true,
  }) =>
      probeLegado(runtime, source, query: query, fetchContent: fetchContent);
}
