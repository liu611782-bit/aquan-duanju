import 'book_source_model.dart';
import 'book_source_runtime.dart';

/// 书源三连校验：搜书 → 详情 → 正文，逐级验证可用性。
///
/// 每一级失败都给出「停在哪一级、为什么」，导入 UI 据此展示；从不静默放行。
class BookSourceChecker {
  BookSourceChecker({this.runtime});

  final BookSourceRuntime? runtime;

  Future<BookSourceCheck> check(
    BookSource source,
    String query, {
    bool fetchContent = true,
  }) async {
    final rt = runtime ?? BookSourceRuntime();
    if (source.url.trim().isEmpty) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: '缺少 bookSourceUrl',
      );
    }
    if (source.requiresJs) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: '含脚本规则（js:），暂不支持',
      );
    }
    BookHit? hit;
    try {
      final hits = await rt.search(source, query);
      hit = hits.firstWhere(
        (h) => h.isMeaningful,
        orElse: () => const BookHit(),
      );
      if (!hit.isMeaningful) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.search,
          reason: '搜索无结果',
        );
      }
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.search,
        reason: '$e',
      );
    }
    var chapterCount = 0;
    var contentLength = 0;
    try {
      final info = await rt.bookInfo(source, hit.bookUrl);
      chapterCount = info.chapters
          .where((c) => c.title.trim().isNotEmpty && c.url.isNotEmpty)
          .length;
      if (chapterCount == 0) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.bookInfo,
          reason: '目录为空',
          sampleHit: hit,
        );
      }
      if (fetchContent) {
        final text = await rt.content(
          source,
          info.chapters.firstWhere((c) => c.url.isNotEmpty).url,
        );
        contentLength = text.trim().length;
        if (contentLength < 30) {
          return BookSourceCheck(
            source: source,
            ok: false,
            stage: BookCheckStage.content,
            reason: '正文过短（$contentLength 字）',
            sampleHit: hit,
            sampleChapterCount: chapterCount,
          );
        }
      }
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.bookInfo,
        reason: '$e',
        sampleHit: hit,
        sampleChapterCount: chapterCount,
      );
    }
    return BookSourceCheck(
      source: source,
      ok: true,
      sampleHit: hit,
      sampleChapterCount: chapterCount,
      sampleContentLength: contentLength,
    );
  }
}
