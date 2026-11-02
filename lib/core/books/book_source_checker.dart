import 'book_source_model.dart';
import 'book_source_runtime.dart';
import 'provider/book_source_provider.dart';
import 'provider/legado_provider.dart';
import 'provider/source_probe.dart';
import 'provider/so_novel_provider.dart';
import 'so_novel_runtime.dart';

export 'provider/source_probe.dart' show kDefaultProbeQuery, describeProbeFailure;

/// 书源三连校验：搜书 → 详情 → 正文，逐级验证可用性。
///
/// 每一级失败都给出「停在哪一级、为什么」，导入 UI 据此展示；从不静默放行。
/// 方言分派完全交给 [BookSourceProviderRegistry]（新增方言不需要改本文件）。
class BookSourceChecker {
  BookSourceChecker({
    this.runtime,
    this.soNovelRuntime,
    BookSourceProviderRegistry? registry,
  }) : _registry = registry ??
            BookSourceProviderRegistry(<BookSourceProvider>[
              LegadoProvider(runtime: runtime),
              SoNovelProvider(runtime: soNovelRuntime),
            ]);

  /// 注入的 legado 运行时（测试用；null = provider 自建默认实例）。
  final BookSourceRuntime? runtime;

  /// 注入的 so-novel 运行时（同上）。
  final SoNovelRuntime? soNovelRuntime;

  final BookSourceProviderRegistry _registry;

  Future<BookSourceCheck> check(
    BookSource source,
    String query, {
    bool fetchContent = true,
  }) {
    if (source.url.trim().isEmpty) {
      return Future<BookSourceCheck>.value(BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: '缺少 bookSourceUrl',
      ));
    }
    final BookSourceProvider provider;
    try {
      provider = _registry.resolve(source);
    } catch (e) {
      return Future<BookSourceCheck>.value(BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: describeProbeFailure(e),
      ));
    }
    return provider.probe(source, query: query, fetchContent: fetchContent);
  }
}
