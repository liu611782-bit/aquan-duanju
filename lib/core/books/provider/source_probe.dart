/// 三连校验的**方言无关实现**（provider 的 `probe` 直接复用）。
///
/// 从原 `BookSourceChecker` 迁出：那里用 if/else 分派两种方言，现在由 provider
/// 各自引用本文件的对应函数，校验逻辑仍只有一份。
library;

import 'dart:convert';

import '../book_source_model.dart';
import '../book_source_runtime.dart';
import '../so_novel_runtime.dart';
import '../so_novel_source.dart';

/// 默认校验关键词（书源市场与导入 UI 共用）。
const String kDefaultProbeQuery = '我的';

/// legado 方言三连。
Future<BookSourceCheck> probeLegado(
  BookSourceRuntime runtime,
  BookSource source, {
  String query = kDefaultProbeQuery,
  bool fetchContent = true,
}) async {
  BookHit? hit;
  try {
    final hits = await runtime.search(source, query);
    hit = _firstMeaningful(hits);
    if (hit == null) {
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
      reason: describeProbeFailure(e),
    );
  }

  var chapterCount = 0;
  List<BookTocItem> chapters;
  try {
    final info = await runtime.bookInfo(source, hit.bookUrl);
    chapters = info.chapters;
    chapterCount =
        chapters.where((c) => c.title.trim().isNotEmpty && c.url.isNotEmpty).length;
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
      reason: describeProbeFailure(e),
      sampleHit: hit,
      sampleChapterCount: chapterCount,
    );
  }

  return _probeContent(
    source: source,
    hit: hit,
    chapterUrl: chapters.firstWhere((c) => c.url.isNotEmpty).url,
    chapterCount: chapterCount,
    fetchContent: fetchContent,
    load: (url) => runtime.content(source, url),
  );
}

/// so-novel 方言三连。
Future<BookSourceCheck> probeSoNovel(
  SoNovelRuntime runtime,
  BookSource source, {
  String query = kDefaultProbeQuery,
  bool fetchContent = true,
}) async {
  final SoRule rule;
  try {
    rule = SoRule.fromJson(_decodeRule(source));
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
    final hits = await runtime.search(rule, query);
    hit = _firstMeaningful(hits);
    if (hit == null) {
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
      reason: describeProbeFailure(e),
    );
  }

  var chapterCount = 0;
  List<BookTocItem> chapters;
  try {
    await runtime.bookInfo(rule, hit.bookUrl);
    chapters = await runtime.toc(rule, hit.bookUrl);
    chapterCount =
        chapters.where((c) => c.title.trim().isNotEmpty && c.url.isNotEmpty).length;
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
      reason: describeProbeFailure(e),
      sampleHit: hit,
      sampleChapterCount: chapterCount,
    );
  }

  return _probeContent(
    source: source,
    hit: hit,
    chapterUrl: chapters.firstWhere((c) => c.url.isNotEmpty).url,
    chapterCount: chapterCount,
    fetchContent: fetchContent,
    load: (url) => runtime.content(rule, url),
  );
}

/// 正文阶段（独立于目录阶段捕获，避免把正文失败误标成 bookInfo）。
Future<BookSourceCheck> _probeContent({
  required BookSource source,
  required BookHit hit,
  required String chapterUrl,
  required int chapterCount,
  required bool fetchContent,
  required Future<String> Function(String url) load,
}) async {
  var contentLength = 0;
  if (fetchContent) {
    try {
      final text = await load(chapterUrl);
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
        reason: describeProbeFailure(e),
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

BookHit? _firstMeaningful(List<BookHit> hits) {
  for (final h in hits) {
    if (h.isMeaningful) return h;
  }
  return null;
}

Map<String, dynamic> _decodeRule(BookSource source) {
  if (source.rawRuleJson.trim().isEmpty) {
    throw const FormatException('rawRuleJson 为空');
  }
  final decoded = jsonDecode(source.rawRuleJson);
  if (decoded is Map<String, dynamic>) return decoded;
  throw const FormatException('rawRuleJson 不是对象');
}

/// 把校验链上的异常翻成「分类原因 + 原始信息」。
///
/// 分类只用于让用户一眼看出是网络、SSRF、超时还是规则/js 问题；
/// 原始信息一律保留在冒号后面，便于定位（禁止吞掉）。
String describeProbeFailure(Object e) {
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
  if (lower.contains('timeout') || lower.contains('超时')) {
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
