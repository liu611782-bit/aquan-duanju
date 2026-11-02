import 'book_source_model.dart';
import 'book_source_runtime.dart';
import 'provider/book_source_provider.dart';
import 'provider/legado_provider.dart';
import 'provider/so_novel_provider.dart';
import 'so_novel_runtime.dart';

export 'book_source_model.dart' show BookDetailData;

/// 书源服务门面：**只做注册表分派**，不含任何方言分支。
///
/// 新增方言 = 写一个 `BookSourceProvider` + 注册进 [registry]，本文件不动。
/// 构造参数 `{legado, soNovel}` 保留（测试注入锚点）；显式传 [registry] 时以它为准。
class BookSourceService {
  BookSourceService({
    BookSourceRuntime? legado,
    SoNovelRuntime? soNovel,
    BookSourceProviderRegistry? registry,
  }) : registry = registry ??
            BookSourceProviderRegistry(<BookSourceProvider>[
              LegadoProvider(runtime: legado),
              SoNovelProvider(runtime: soNovel),
            ]);

  final BookSourceProviderRegistry registry;

  /// 内置源（Wenku8 等）：书源列表据此常驻显示。
  List<BookSource> get builtinSources => registry.builtinSources;

  // 注意：三个方法都是 async —— 未注册方言的异常要变成「失败的 Future」，
  // 不能在调用点同步抛出（`expectLater(service.search(...), throwsA(...))` 会漏）。
  Future<List<BookHit>> search(BookSource source, String query,
      {int page = 1}) async {
    return registry.resolve(source).search(source, query, page: page);
  }

  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    return registry.resolve(source).detail(source, bookUrl);
  }

  Future<String> content(BookSource source, String chapterUrl) async {
    return registry.resolve(source).content(source, chapterUrl);
  }
}
