import 'package:aquan_duanju/core/books/book_source_model.dart';
import 'package:aquan_duanju/core/books/book_source_store.dart';
import 'package:aquan_duanju/core/books/provider/book_source_provider.dart';
import 'package:aquan_duanju/core/books/provider/wenku8_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  // 默认关掉「随应用内置的规则源」，让用例只考察 provider 内置源与用户源。
  Future<BookSourceStore> newStore({bool withBundled = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final store = BookSourceStore(
      prefs,
      bundled: withBundled ? null : () => const [],
    );
    await store.ensureLoaded();
    return store;
  }

  group('内置源注入', () {
    test('首次加载注入 Wenku8，但默认停用（站点需登录）', () async {
      final store = await newStore();
      final builtin = store.sources
          .where((s) => s.format == BookSourceFormat.wenku8)
          .toList();
      expect(builtin, hasLength(1));
      expect(builtin.single.url, kWenku8DefaultBase);
      expect(builtin.single.enabled, isFalse);
      expect(store.isBuiltin(kWenku8DefaultBase), isTrue);
      expect(store.enabled.any((s) => s.format == BookSourceFormat.wenku8),
          isFalse);
    });

    test('用户改过/停用过的内置源不被覆盖（只补缺失）', () async {
      SharedPreferences.setMockInitialValues({
        'bookSource.enabled':
            '[{"bookSourceUrl":"https://www.wenku8.net","bookSourceName":"我改的名字",'
                '"enabled":false,"aquanFormat":"wenku8"}]',
      });
      final store = await newStore();
      expect(store.sources, hasLength(1));
      final s = store.sources.single;
      expect(s.enabled, isFalse, reason: '不能强行把用户关掉的源打开');
      expect(s.name, '我改的名字', reason: '不能覆盖用户编辑');
      expect(s.format, BookSourceFormat.wenku8);
    });

    test('内置源可删除，删后重启不再自动注入', () async {
      final prefs = await SharedPreferences.getInstance();
      final first = BookSourceStore(prefs, bundled: () => const []);
      await first.ensureLoaded();
      expect(await first.remove(kWenku8DefaultBase), isTrue);
      expect(first.byUrl(kWenku8DefaultBase), isNull);
      expect(first.isDismissed(kWenku8DefaultBase), isTrue);

      final reopened = BookSourceStore(prefs, bundled: () => const []);
      await reopened.ensureLoaded();
      expect(reopened.byUrl(kWenku8DefaultBase), isNull, reason: '删过的不再注入');
    });

    test('内置源可启停，重启后保持用户选择', () async {
      final prefs = await SharedPreferences.getInstance();
      final store = BookSourceStore(prefs, bundled: () => const []);
      await store.ensureLoaded();
      await store.setEnabled(kWenku8DefaultBase, true);
      expect(store.byUrl(kWenku8DefaultBase)!.enabled, isTrue);
      await store.setEnabled(kWenku8DefaultBase, false);
      expect(store.byUrl(kWenku8DefaultBase)!.enabled, isFalse);

      final reopened = BookSourceStore(prefs, bundled: () => const []);
      await reopened.ensureLoaded();
      expect(reopened.byUrl(kWenku8DefaultBase)!.enabled, isFalse);
    });

    test('普通源可删；removeAll 批量删并记 dismiss', () async {
      final store = await newStore();
      const userSource = BookSource(
        url: 'https://user.example',
        name: '用户源',
        format: BookSourceFormat.legado,
      );
      await store.importAll([userSource]);
      expect(await store.remove('https://user.example'), isTrue);
      expect(store.byUrl('https://user.example'), isNull);

      final removed = await store.removeAll([kWenku8DefaultBase, '不存在']);
      expect(removed, 1);
      expect(store.sources, isEmpty);
      expect(store.isDismissed(kWenku8DefaultBase), isTrue);
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
        bundled: () => const [],
      );
      await store.ensureLoaded();
      expect(store.sources.single.url, 'https://fake.example');
      expect(store.builtinUrls, {'https://fake.example'});
    });

    test('随应用内置的规则源会被注入且可停用', () async {
      final store = await newStore(withBundled: true);
      final bundled = store.sources.where((s) => s.url == 'https://www.linovel.net');
      expect(bundled, hasLength(1));
      expect(bundled.single.format, BookSourceFormat.legado);
      expect(bundled.single.enabled, isTrue);
      expect(bundled.single.requiresJs, isFalse);

      await store.setEnabled('https://www.linovel.net', false);
      expect(store.byUrl('https://www.linovel.net')!.enabled, isFalse);
    });
  });
}

class _BuiltinOnlyProvider extends Wenku8Provider {
  _BuiltinOnlyProvider(this._source);

  final BookSource _source;

  @override
  List<BookSource> get builtinSources => [_source];
}
