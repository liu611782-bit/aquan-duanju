import 'dart:async';
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
        reason: describeBookCheckFailure(e),
      );
    }
    var chapterCount = 0;
    var contentLength = 0;
    List<BookTocItem> chapters;
    try {
      final info = await rt.bookInfo(source, hit.bookUrl);
      chapters = info.chapters;
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
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.bookInfo,
        reason: describeBookCheckFailure(e),
        sampleHit: hit,
        sampleChapterCount: chapterCount,
      );
    }
    if (fetchContent) {
      // 正文阶段单独 try：过去与目录共用 catch，正文失败被误标成 bookInfo。
      try {
        final text = await rt.content(
          source,
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
      } catch (e) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.content,
          reason: describeBookCheckFailure(e),
          sampleHit: hit,
          sampleChapterCount: chapterCount,
        );
      }
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
        reason: describeBookCheckFailure(e),
      );
    }
    var chapterCount = 0;
    var contentLength = 0;
    List<BookTocItem> chapters;
    try {
      await rt.bookInfo(rule, hit.bookUrl);
      chapters = await rt.toc(rule, hit.bookUrl);
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
    } catch (e) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.bookInfo,
        reason: describeBookCheckFailure(e),
        sampleHit: hit,
        sampleChapterCount: chapterCount,
      );
    }
    if (fetchContent) {
      try {
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
      } catch (e) {
        return BookSourceCheck(
          source: source,
          ok: false,
          stage: BookCheckStage.content,
          reason: describeBookCheckFailure(e),
          sampleHit: hit,
          sampleChapterCount: chapterCount,
        );
      }
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

/// 把校验链上的异常翻成「分类原因 + 原始信息」。
///
/// 分类只用于让用户一眼看出是网络、SSRF、超时还是规则/js 问题；
/// 原始信息一律保留在冒号后面，便于定位（禁止吞掉）。
String describeBookCheckFailure(Object e) {
  final raw = e
      .toString()
      .replaceFirst(
        RegExp(
            r'^(Exception|StateError|FormatException|BookSourceException|'
            r'SoNovelException|LegadoJsException|SoNovelSelectorException):\s*'),
        '',
      )
      .trim();
  final lower = raw.toLowerCase();
  final String cause;
  if (e is TimeoutException || lower.contains('timeout') || lower.contains('超时')) {
    cause = '请求超时';
  } else if (lower.contains('ssrf') || lower.contains('非法地址')) {
    cause = '地址被安全策略拒绝';
  } else if (lower.contains('socketexception') ||
      lower.contains('connection') ||
      lower.contains('连接') ||
      lower.contains('网络')) {
    cause = '网络不可达';
  } else if (lower.contains('js') && lower.contains('规则')) {
    cause = '脚本规则执行失败';
  } else if (lower.contains('目录为空') || lower.contains('搜索无结果')) {
    cause = '站点结构或规则不匹配';
  } else {
    return raw.isEmpty ? '未知失败' : raw;
  }
  return raw.isEmpty ? cause : '$cause：$raw';
}
