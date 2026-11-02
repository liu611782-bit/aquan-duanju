import 'dart:io';

import 'package:aquan_duanju/core/books/book_source_runtime.dart';
import 'package:aquan_duanju/core/books/builtin_sources.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内置源**真站**守卫测试：只在 `AQUAN_NET_TESTS=1` 时跑（会发真实请求）。
///
/// 跑法：`AQUAN_NET_TESTS=1 flutter test test/books/builtin_source_net_test.dart`
/// 目的：内置源一旦被站点改版打破，CI/本地能立刻发现，而不是等用户报 403。
final bool _netEnabled =
    Platform.environment['AQUAN_NET_TESTS'] == '1';

void main() {
  group('内置源（真站）', () {
    test('规则四连：搜索 → 详情/目录 → 正文', () async {
      final sources = builtinBookSources();
      expect(sources, isNotEmpty);
      final source = sources.first;
      final runtime = BookSourceRuntime(
        connectTimeout: const Duration(seconds: 15),
        readTimeout: const Duration(seconds: 25),
      );

      final hits = await runtime.search(source, '火影');
      expect(hits, isNotEmpty, reason: '搜索应返回结果（站点结构可能改版）');
      final hit = hits.firstWhere((h) => h.isMeaningful);
      expect(hit.name, isNotEmpty);
      expect(hit.bookUrl, contains('/book/'));

      final info = await runtime.bookInfo(source, hit.bookUrl);
      expect(info.chapters, isNotEmpty, reason: '目录应解析出章节');
      expect(info.name, isNotEmpty);
      final chapter = info.chapters.firstWhere((c) => c.url.isNotEmpty);

      final text = await runtime.content(source, chapter.url);
      expect(text.trim().length, greaterThan(100), reason: '正文应有点长度');
      // `@html` 保留段落：应当还能看到标签（阅读器随后切段）。
      expect(text.contains('<p') || text.contains('\n'), isTrue);
    }, skip: _netEnabled ? false : '设 AQUAN_NET_TESTS=1 才跑真站测试', timeout: const Timeout(Duration(minutes: 2)));

    test('每个内置源都能被注册表识别为 legado', () {
      for (final source in builtinBookSources()) {
        expect(source.url, isNotEmpty);
        expect(source.name, isNotEmpty);
        expect(source.requiresJs, isFalse, reason: '内置源不依赖 js，避免引擎环境问题');
      }
    });
  });
}
