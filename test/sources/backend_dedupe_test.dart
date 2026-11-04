import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/backend_dedupe.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';

SourceConfig _cms(String id, String api, {bool pinned = false}) => SourceConfig(
      id: id,
      name: id,
      apis: [api],
      pinned: pinned,
    );

void main() {
  group('backendSignature', () {
    test('协议 / 尾斜杠 / at-xml 视为同一后端', () {
      final a = backendSignature(_cms('a', 'http://A.com/api.php/provide/vod/'));
      final b = backendSignature(_cms('b', 'https://a.com/api.php/provide/vod'));
      final c =
          backendSignature(_cms('c', 'https://a.com/api.php/provide/vod/at/xml'));
      expect(a, b);
      expect(a, c);
    });

    test('不同接口路径不合并', () {
      final a = backendSignature(_cms('a', 'http://a.com/api.php/provide/vod'));
      final b = backendSignature(_cms('b', 'http://a.com/api.php/app/vod'));
      expect(a, isNot(b));
    });

    test('爬虫源按 ext/spiderKey 区分', () {
      final a = SourceConfig(
        id: 'a',
        name: 'a',
        apis: const ['https://x/spider.js'],
        kind: SourceKind.spiderJs,
        spiderKey: 'csp_a',
        ext: '1',
      );
      final b = SourceConfig(
        id: 'b',
        name: 'b',
        apis: const ['https://x/spider.js'],
        kind: SourceKind.spiderJs,
        spiderKey: 'csp_a',
        ext: '2',
      );
      expect(backendSignature(a), isNot(backendSignature(b)));
    });
  });

  group('dedupeByBackend', () {
    test('保留首个，主页源提到首位', () {
      final list = [
        _cms('a', 'http://same/api'),
        _cms('b', 'https://same/api/'),
        _cms('c', 'http://other/api'),
      ];
      expect(dedupeByBackend(list).map((s) => s.id), ['a', 'c']);
      expect(
        dedupeByBackend(list, priorityId: 'b').map((s) => s.id),
        ['b', 'c'],
      );
    });

    test('空 api 被跳过', () {
      final list = [_cms('a', '  '), _cms('b', 'http://b/api')];
      expect(dedupeByBackend(list).map((s) => s.id), ['b']);
    });
  });
}
