/// 书源 **provider 可插拔层的公共契约**。
///
/// 设计目标（用户需求 R1）：新增一种书源方言只写一个 provider 并注册，不改分派代码。
/// `BookSourceService`（上层门面）与 `BookSourceChecker`（三连校验）都只认本接口。
///
/// 与 `BookRule` / `SoNovelRule` 的关系：provider 只做「方言 → 统一数据面」的适配，
/// 规则求值仍在各自 runtime 内，互不引用。
library;

import '../book_source_model.dart';
import '../book_source_runtime.dart' show BookSourceException;

/// 一条 provider 支持的方言实现。
///
/// 所有失败必须抛异常并带可读原因（`BookSourceException` / 方言自有异常），
/// 不允许返回空列表冒充「没搜到」。
abstract class BookSourceProvider {
  /// 本 provider 负责的方言。
  BookSourceFormat get format;

  /// 展示名（书源管理 UI 用）。
  String get displayName;

  /// 内置 provider（如 Wenku8）：其源自动注入且不可删除。
  bool get builtin => false;

  /// 内置源清单（[builtin] 为 true 时通常非空）。
  List<BookSource> get builtinSources => const <BookSource>[];

  /// 搜书。[page] 从 1 开始，不支持分页的方言可忽略。
  Future<List<BookHit>> search(BookSource source, String query, {int page = 1});

  /// 详情（名称/作者/简介/封面/目录）。目录为空不算失败。
  Future<BookDetailData> detail(BookSource source, String bookUrl);

  /// 正文（未清洗的原始正文；`##` 清洗由调用方或方言内部完成）。
  Future<String> content(BookSource source, String chapterUrl);

  /// 三连校验（搜索 → 目录 → 正文），失败给出阶段与原因。
  Future<BookSourceCheck> probe(
    BookSource source, {
    String query = '我的',
    bool fetchContent = true,
  });
}

/// provider 注册表：**唯一的方言分派点**。
///
/// - 同 [BookSourceFormat] 后注册者覆盖先注册者（便于测试替身与热替换）；
/// - 未知方言抛出可读异常，绝不回落 legado（回落会把 so-novel/wenku8 源解成垃圾）。
class BookSourceProviderRegistry {
  BookSourceProviderRegistry([Iterable<BookSourceProvider>? providers]) {
    if (providers != null) {
      for (final p in providers) {
        register(p);
      }
    }
  }

  final Map<BookSourceFormat, BookSourceProvider> _byFormat =
      <BookSourceFormat, BookSourceProvider>{};

  void register(BookSourceProvider provider) {
    _byFormat[provider.format] = provider;
  }

  /// 已注册的全部 provider（按 format 声明顺序）。
  List<BookSourceProvider> get all => List<BookSourceProvider>.unmodifiable(
        BookSourceFormat.values
            .where(_byFormat.containsKey)
            .map((f) => _byFormat[f]!),
      );

  BookSourceProvider? byFormat(BookSourceFormat format) => _byFormat[format];

  /// 解析源对应的 provider；未注册 → 抛 [BookSourceException]。
  BookSourceProvider resolve(BookSource source) {
    final provider = _byFormat[source.format];
    if (provider == null) {
      throw BookSourceException(
        '未注册的书源方言：${source.format.name}（源「${source.name}」）',
      );
    }
    return provider;
  }

  /// 所有 provider 声明的内置源（去重：同 url 只留第一条）。
  List<BookSource> get builtinSources {
    final seen = <String>{};
    final out = <BookSource>[];
    for (final p in all) {
      for (final s in p.builtinSources) {
        if (s.url.isEmpty || !seen.add(s.url)) continue;
        out.add(s);
      }
    }
    return out;
  }

  /// 内置源 url 集合（书源仓库据此拒绝删除）。
  Set<String> get builtinUrls =>
      {for (final s in builtinSources) s.url}.toSet();
}
