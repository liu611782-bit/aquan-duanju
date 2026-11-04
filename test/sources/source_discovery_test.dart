import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_discovery.dart';

void main() {
  group('SourceDiscovery.isConfigCandidate', () {
    final discovery = SourceDiscovery();

    test('接受配置载体：json / txt / 无后缀 / 以 /tv 结尾', () {
      expect(discovery.isConfigCandidate('https://x/tvbox.json'), isTrue);
      expect(discovery.isConfigCandidate('https://x/api.txt'), isTrue);
      expect(discovery.isConfigCandidate('http://x.com/tv'), isTrue);
      expect(discovery.isConfigCandidate('http://example.com'), isTrue);
      expect(discovery.isConfigCandidate('json/config.json'), isTrue);
    });

    test('过滤静态资源与依赖清单', () {
      expect(discovery.isConfigCandidate('https://x/a.png'), isFalse);
      expect(discovery.isConfigCandidate('https://x/a.apk'), isFalse);
      expect(discovery.isConfigCandidate('https://x/package.json'), isFalse);
      expect(discovery.isConfigCandidate('https://x/node_modules/a.json'),
          isFalse);
      expect(discovery.isConfigCandidate('https://x/js.134584.xyz/a.json'),
          isFalse);
    });
  });
}
