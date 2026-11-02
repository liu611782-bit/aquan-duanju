import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/books/provider/book_source_provider.dart';
import 'package:aquan_duanju/core/books/provider/wenku8_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<BookSourceStore> newStore() async {
    final prefs = await SharedPreferences.getInstance();
    final store = BookSourceStore(prefs);
    await store.ensureLoaded();
    return store;
  }

  group('内置源注入', () {
    test('首次加载自动注入 Wenku8 且启用', () async {
      final store = await newStore();
      final builtin = store.sources
          .where((s) => s.format == BookSourceFormat.wenku8)
          .toList();
      expect(builtin, hasLength(1));
      expect(builtin.single.url, kWenku8DefaultBase);
      expect(builtin.single.enabled, isTrue);
      expect(store.isBuiltin(kWenku8DefaultBase), isTrue);
      expect(store.enabled.any((s) => s.format == BookSourceFormat.wenku8),
          isTrue);
    });

    test('重启后不重复注入，且停用状态被强制恢复', () async {
      SharedPreferences.setMockInitialValues({
        'bookSource.enabled':
            '[{"bookSourceUrl":"https://www.wenku8.net","bookSourceName":"旧名",'
                '"enabled":false,"aquanFormat":"wenku8"}]',
      });
      final store = await newStore();
      expect(store.sources, hasLength(1));
      final s = store.sources.single;
      expect(s.enabled, isTrue, reason: '内置源必须常驻启用');
      expect(s.name, '轻小说文库（Wenku8）', reason: '元数据应刷新');
      expect(s.format, BookSourceFormat.wenku8);
    });

    test('内置源拒绝删除，普通源可删', () async {
      final store = await newStore();
      expect(await store.remove(kWenku8DefaultBase), isFalse);
      expect(store.byUrl(kWenku8DefaultBase), isNotNull);

      const userSource = BookSource(
        url: 'https://user.example',
        name: '用户源',
        format: BookSourceFormat.legado,
      );
      await store.importAll([userSource]);
      expect(await store.remove('https://user.example'), isTrue);
      expect(store.byUrl('https://user.example'), isNull);
    });

    test('内置源停用被忽略', () async {
      final store = await newStore();
      await store.setEnabled(kWenku8DefaultBase, false);
      expect(store.byUrl(kWenku8DefaultBase)!.enabled, isTrue);
    });

    test('可注入自定义注册表（测试替身）', () async {
      final prefs = await SharedPreferences.getInstance();
      const fakeBuiltin = BookSource(
        url: 'https://fake.example',
        name: '替身内置源',
        format: BookSourceFormat.wenku8,
      );
      final store = BookSourceStore(
        prefs,
        registry: BookSourceProviderRegistry([
          _BuiltinOnlyProvider(fakeBuiltin),
        ]),
      );
      await store.ensureLoaded();
      expect(store.sources.single.url, 'https://fake.example');
      expect(store.builtinUrls, {'https://fake.example'});
    });
  });
}

class _BuiltinOnlyProvider extends Wenku8Provider {
  _BuiltinOnlyProvider(this._source);

  final BookSource _source;

  @override
  List<BookSource> get builtinSources => [_source];
}
