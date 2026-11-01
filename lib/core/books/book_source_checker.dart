import 'dart:convert';

import 'book_source_model.dart';
import 'book_source_runtime.dart';
import 'so_novel_runtime.dart';
import 'so_novel_source.dart';

/// 书源三连校验：搜书 → 详情 → 正文，逐级验证可用性。
///
/// 每一级失败都给出「停在哪一级、为什么」，导入 UI 据此展示；从不静默放行。
/// 按 [BookSource.format] 分派方言：legado（含 js 规则，按需走 js 引擎）/
/// so-novel（专用运行时）。js 源不再入口即拒——真实执行、失败诚实归因。
class BookSourceChecker {
  BookSourceChecker({this.runtime, this.soNovelRuntime});

  final BookSourceRuntime? runtime;
  final SoNovelRuntime? soNovelRuntime;

  Future<BookSourceCheck> check(
    BookSource source,
    String query, {
    bool fetchContent = true,
  }) async {
    if (source.url.trim().isEmpty) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: '缺少 bookSourceUrl',
      );
    }
    return source.format == BookSourceFormat.soNovel
        ? _checkSoNovel(source, query, fetchContent)
        : _checkLegado(source, query, fetchContent);
  }

  Future<BookSourceCheck> _checkLegado(
    BookSource source,
    String query,
    bool fetchContent,
  ) async {
    final rt = runtime ?? BookSourceRuntime();
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

  Future<BookSourceCheck> _checkSoNovel(
    BookSource source,
    String query,
    bool fetchContent,
  ) async {
    final rt = soNovelRuntime ?? SoNovelRuntime();
    final SoRule rule;
    try {
      rule = SoRule.fromJson(
          jsonDecode(source.rawRuleJson) as Map<String, dynamic>);
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.none,
        reason: 'so-novel 规则解析失败：$e',
      );
    }
    BookHit? hit;
    try {
      final hits = await rt.search(rule, query);
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
      await rt.bookInfo(rule, hit.bookUrl);
      final chapters = await rt.toc(rule, hit.bookUrl);
      chapterCount = chapters
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
          rule,
          chapters.firstWhere((c) => c.url.isNotEmpty).url,
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
