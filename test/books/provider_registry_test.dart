import 'dart:async';

import 'package:aquan_duanju/core/books/book_source_checker.dart';
import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_service.dart';
import 'package:aquan_duanju/core/books/provider/book_source_provider.dart';
import 'package:flutter_test/flutter_test.dart';

/// 只记录调用、返回固定值的替身 provider。
class _FakeProvider implements BookSourceProvider {
  _FakeProvider({
    required this.format,
    this.builtin = false,
    this.builtinSources = const <BookSource>[],
    this.failWith,
  });

  @override
  final BookSourceFormat format;
  @override
  String get displayName => 'fake';
  @override
  final bool builtin;
  @override
  final List<BookSource> builtinSources;

  /// 非空时所有方法抛该异常（验证失败归因）。
  final Object? failWith;

  final List<String> calls = <String>[];

  @override
  Future<List<BookHit>> search(BookSource source, String query,
      {int page = 1}) async {
    calls.add('search:$query:$page');
    if (failWith != null) throw failWith!;
    return [
      BookHit(bookUrl: 'fake://b1', name: '书目'),
    ];
  }

  @override
  Future<BookDetailData> detail(BookSource source, String bookUrl) async {
    calls.add('detail:$bookUrl');
    if (failWith != null) throw failWith!;
    return const BookDetailData(
      name: '书目',
      chapters: [BookTocItem(title: '第一章', url: 'fake://c1')],
    );
  }

  @override
  Future<String> content(BookSource source, String chapterUrl) async {
    calls.add('content:$chapterUrl');
    if (failWith != null) throw failWith!;
    return '正文' * 30;
  }

  @override
  Future<BookSourceCheck> probe(
    BookSource source, {
    String query = kDefaultProbeQuery,
    bool fetchContent = true,
  }) async {
    calls.add('probe:$query');
    if (failWith != null) {
      return BookSourceCheck(
        source: source,
        ok: false,
        stage: BookCheckStage.search,
        reason: describeProbeFailure(failWith!),
      );
    }
    return BookSourceCheck(source: source, ok: true, sampleChapterCount: 1);
  }
}

BookSource _source(BookSourceFormat format) => BookSource(
      url: 'fake://source',
      name: '替身源',
      format: format,
    );

void main() {
  group('BookSourceProviderRegistry', () {
    test('按 format 解析到对应 provider', () {
      final legado = _FakeProvider(format: BookSourceFormat.legado);
      final local = _FakeProvider(format: BookSourceFormat.local);
      final reg = BookSourceProviderRegistry([legado, local]);

      expect(reg.resolve(_source(BookSourceFormat.legado)), same(legado));
      expect(reg.resolve(_source(BookSourceFormat.local)), same(local));
      expect(reg.all, hasLength(2));
      expect(reg.all.every((p) => p.displayName == 'fake'), isTrue);
    });

    test('后注册覆盖先注册（测试替身/热替换）', () {
      final first = _FakeProvider(format: BookSourceFormat.legado);
      final second = _FakeProvider(format: BookSourceFormat.legado);
      final reg = BookSourceProviderRegistry([first, second]);
      expect(reg.resolve(_source(BookSourceFormat.legado)), same(second));
      expect(reg.all, hasLength(1));
    });

    test('未注册方言抛可读异常，不回落 legado', () {
      final reg = BookSourceProviderRegistry([
        _FakeProvider(format: BookSourceFormat.legado),
      ]);
      expect(
        () => reg.resolve(_source(BookSourceFormat.wenku8)),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('未注册的书源方言'),
        )),
      );
    });

    test('内置源聚合去重', () {
      const s1 = BookSource(url: 'https://a', name: 'A', format: BookSourceFormat.wenku8);
      const s2 = BookSource(url: 'https://a', name: 'A重复', format: BookSourceFormat.wenku8);
      final reg = BookSourceProviderRegistry([
        _FakeProvider(
          format: BookSourceFormat.wenku8,
          builtin: true,
          builtinSources: [s1, s2],
        ),
      ]);
      expect(reg.builtinSources, hasLength(1));
      expect(reg.builtinUrls, {'https://a'});
    });
  });

  group('BookSourceService 分派', () {
    test('按源方言走对应 provider，page 透传', () async {
      final legado = _FakeProvider(format: BookSourceFormat.legado);
      final soNovel = _FakeProvider(format: BookSourceFormat.soNovel);
      final service = BookSourceService(
        registry: BookSourceProviderRegistry([legado, soNovel]),
      );

      await service.search(_source(BookSourceFormat.soNovel), '词', page: 3);
      expect(soNovel.calls, ['search:词:3']);
      expect(legado.calls, isEmpty);

      final detail = await service.detail(_source(BookSourceFormat.legado), 'u');
      expect(legado.calls, ['detail:u']);
      expect(detail.chapters, hasLength(1));

      await service.content(_source(BookSourceFormat.soNovel), 'c');
      expect(soNovel.calls.last, 'content:c');
    });

    test('未知方言在 service 层同样诚实报错', () async {
      final service = BookSourceService(
        registry: BookSourceProviderRegistry([
          _FakeProvider(format: BookSourceFormat.legado),
        ]),
      );
      await expectLater(
        service.search(_source(BookSourceFormat.wenku8), 'x'),
        throwsA(isA<Exception>()),
      );
    });

    test('内置源从注册表透出', () {
      const builtin = BookSource(
        url: 'https://wenku8',
        name: '轻小说文库',
        format: BookSourceFormat.wenku8,
      );
      final service = BookSourceService(
        registry: BookSourceProviderRegistry([
          _FakeProvider(
            format: BookSourceFormat.wenku8,
            builtin: true,
            builtinSources: const [builtin],
          ),
        ]),
      );
      expect(service.builtinSources.single.url, 'https://wenku8');
    });
  });

  group('BookSourceChecker 走 provider', () {
    test('成功路径由 provider 给出结果', () async {
      final fake = _FakeProvider(format: BookSourceFormat.wenku8);
      final checker = BookSourceChecker(
        registry: BookSourceProviderRegistry([fake]),
      );
      final check = await checker.check(_source(BookSourceFormat.wenku8), '词');
      expect(check.ok, isTrue);
      expect(fake.calls, ['probe:词']);
    });

    test('未注册方言 → stage none + 可读原因', () async {
      final checker = BookSourceChecker(
        registry: BookSourceProviderRegistry([
          _FakeProvider(format: BookSourceFormat.legado),
        ]),
      );
      final check =
          await checker.check(_source(BookSourceFormat.soNovel), '词');
      expect(check.ok, isFalse);
      expect(check.stage, BookCheckStage.none);
      expect(check.reason, contains('未注册的书源方言'));
    });

    test('失败原因经分类透传（超时 / 网络）', () async {
      final fake = _FakeProvider(
        format: BookSourceFormat.legado,
        failWith: TimeoutException('backend timeout'),
      );
      final checker = BookSourceChecker(
        registry: BookSourceProviderRegistry([fake]),
      );
      final check = await checker.check(_source(BookSourceFormat.legado), '词');
      expect(check.ok, isFalse);
      expect(check.stage, BookCheckStage.search);
      expect(check.reason, contains('请求超时'));
      expect(check.reason, contains('backend timeout'));
    });

    test('空 bookSourceUrl 直接拒绝（不进 provider）', () async {
      final fake = _FakeProvider(format: BookSourceFormat.legado);
      final checker = BookSourceChecker(
        registry: BookSourceProviderRegistry([fake]),
      );
      final check = await checker.check(
        const BookSource(url: '  ', format: BookSourceFormat.legado),
        '词',
      );
      expect(check.reason, '缺少 bookSourceUrl');
      expect(fake.calls, isEmpty);
    });
  });

  group('BookSource 方言持久化往返', () {
    test('wenku8 / local 经 toJson → fromJson 保真', () {
      for (final format in [
        BookSourceFormat.wenku8,
        BookSourceFormat.local,
        BookSourceFormat.legado,
      ]) {
        final src = BookSource(
          url: 'fake://${format.name}',
          name: '名',
          format: format,
          searchUrl: 'x',
        );
        final round = BookSource.fromJson(src.toJson());
        expect(round.format, format, reason: '${format.name} 往返丢方言');
      }
    });

    test('旧数据不含 aquanFormat 时回落 legado', () {
      final round = BookSource.fromJson({'bookSourceUrl': 'https://x'});
      expect(round.format, BookSourceFormat.legado);
    });

    test('未知 aquanFormat 值回落 legado（前向兼容）', () {
      final round = BookSource.fromJson({
        'bookSourceUrl': 'https://x',
        'aquanFormat': 'futureDialect',
      });
      expect(round.format, BookSourceFormat.legado);
    });

    test('requiresJs 只对 legado 生效', () {
      const jsRule = 'js:result';
      expect(
        const BookSource(
          url: 'a',
          format: BookSourceFormat.legado,
          searchUrl: jsRule,
        ).requiresJs,
        isTrue,
      );
      for (final f in [BookSourceFormat.soNovel, BookSourceFormat.wenku8, BookSourceFormat.local]) {
        expect(
          BookSource(url: 'a', format: f, searchUrl: jsRule).requiresJs,
          isFalse,
          reason: '${f.name} 不应被 legado 的 js 闸门拦住',
        );
      }
    });
  });
}
