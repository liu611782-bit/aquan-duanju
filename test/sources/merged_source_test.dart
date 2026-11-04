import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/merged_source.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_import.dart';

SourceConfig _cms(
  String id,
  String name,
  String api, {
  SourceKind kind = SourceKind.cmsJson,
  Map<String, String> headers = const {},
  String ext = '',
}) =>
    SourceConfig(
      id: id,
      name: name,
      apis: [api],
      kind: kind,
      headers: headers,
      ext: ext,
    );

void main() {
  group('MergedSourceBuilder', () {
    test('按 type|api|ext 去重，保留第一个', () {
      final result = MergedSourceBuilder.build([
        _cms('a', 'A', 'http://x/api'),
        _cms('b', 'B', 'http://x/api/'),
        _cms('c', 'C', 'http://y/api'),
      ]);
      final sites = (jsonDecode(result.json) as Map)['sites'] as List;
      expect(sites.length, 2);
      expect(result.duplicates, 1);
      expect((sites.first as Map)['name'], 'A');
    });

    test('key 冲突加序号、name 冲突追加来源名', () {
      final result = MergedSourceBuilder.build([
        SourceConfig(id: 'k', name: '同名', apis: const ['http://a/api']),
        SourceConfig(id: 'k', name: '同名', apis: const ['http://b/api']),
      ]);
      final sites = (jsonDecode(result.json) as Map)['sites'] as List;
      expect((sites[0] as Map)['key'], 'k');
      expect((sites[1] as Map)['key'], 'k_2');
      expect((sites[1] as Map)['name'], contains('同名（同名）'));
    });

    test('保留 header / ext / type，jar 爬虫跳过', () {
      final result = MergedSourceBuilder.build([
        _cms('a', 'A', 'http://a/api', headers: {'Referer': 'r'}),
        _cms('b', 'B', 'http://b/api', kind: SourceKind.cmsXml, ext: '{"x":1}'),
        SourceConfig(
          id: 'jar',
          name: 'J',
          apis: const ['csp_X'],
          kind: SourceKind.spider,
        ),
      ]);
      final sites = (jsonDecode(result.json) as Map)['sites'] as List;
      expect(sites.length, 2);
      expect((sites[0] as Map)['header'], {'Referer': 'r'});
      expect((sites[1] as Map)['type'], 0);
      expect((sites[1] as Map)['ext'], '{"x":1}');
    });

    test('parses 按 url 去重', () {
      final result = MergedSourceBuilder.build(
        [_cms('a', 'A', 'http://a/api')],
        parses: const [
          ParseApi(name: 'p1', url: 'http://p/1'),
          ParseApi(name: 'p2', url: 'http://p/1'),
          ParseApi(name: 'p3', url: 'http://p/2'),
        ],
      );
      final parses = (jsonDecode(result.json) as Map)['parses'] as List;
      expect(parses.length, 2);
    });

    test('没有站点时 ok=false', () {
      final result = MergedSourceBuilder.build(const []);
      expect(result.ok, isFalse);
      expect(result.message, '没有可合并的站点');
    });
  });

  group('MergedSourceStore', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('aquan_merged_test');
    });

    tearDown(() async {
      await tmp.delete(recursive: true);
    });

    test('原子写 / 读回 / 元信息', () async {
      final store = MergedSourceStore(supportDirectory: () async => tmp);
      final json = MergedSourceBuilder.build([
        _cms('a', 'A', 'http://a/api'),
      ]).json;
      expect(await store.write(json), isTrue);
      expect(await store.read(), json);
      final info = await store.info();
      expect(info?.siteCount, 1);
      expect(info?.path, contains(mergedSourceFile));
    });

    test('目录不可写时返回 false 而不是抛异常', () async {
      final store = MergedSourceStore(
        supportDirectory: () async => throw const FileSystemException('nope'),
      );
      expect(await store.write('{"sites":[]}'), isFalse);
      expect(await store.read(), isNull);
      expect(await store.info(), isNull);
    });
  });
}
