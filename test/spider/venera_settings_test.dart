// Venera 源设置闭环集成测试：settings schema 读取 → loadSetting 默认值 →
// saveSetting 持久化 → 重启（dispose 重载）仍生效。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/venera/venera_js_runtime.dart';
import 'package:aquan_duanju/core/sources/venera/venera_manga_source.dart';
import 'package:aquan_duanju/store/stores.dart';

import 'native_lib_guard.dart';

const _fixtureJs = '''
class SettingsFixture extends ComicSource {
    name = "设置夹具"
    key = "settings_fixture"
    version = "1.0.0"

    base = '';

    settings = {
        domains: {title: "域名", type: "input", default: "default.example.com"},
        mirror: {
            title: "线路",
            type: "select",
            options: [
                {value: "1", text: "线路一"},
                {value: "2", text: "线路二"}
            ],
            default: "1"
        },
        nsfw: {title: "显示", type: "switch", default: false},
        cleanup: {
            title: "清理", type: "callback", buttonText: "清一下",
            callback: () => { this.cleaned = true; }
        }
    }

    cleaned = false;

    get baseUrl() { return this.loadSetting("domains"); }

    function_probe() { return "probe"; }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory support;
  setUp(() {
    HttpOverrides.global = null;
    support = Directory.systemTemp.createTempSync('aquan_venera_settings');
    addTearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  Future<VeneraMangaSource> makeSource(VeneraJsRuntime runtime) async {
    final store = VeneraStore(testDirectory: support);
    await store.ensureLoaded();
    runtime.store = store;
    final source = VeneraMangaSource(_fixtureJs);
    await source.load();
    return source;
  }

  test('设置闭环：schema/默认值/saveSetting 持久化/callback/重载生效', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final runtime = VeneraJsRuntime.instance;
    addTearDown(runtime.dispose);
    var source = await makeSource(runtime);

    // schema：四个声明键 + 类型/默认值。
    final schema = await source.settingsSchema();
    expect(schema.keys, containsAll(['domains', 'mirror', 'nsfw', 'cleanup']));
    expect(schema['domains']!['type'], 'input');
    expect(schema['mirror']!['type'], 'select');
    expect((schema['mirror']!['options'] as List), hasLength(2));
    expect(schema['nsfw']!['default'], false);

    // 默认值经 loadSetting 回落。
    expect(await source.loadSettingValue('domains'), 'default.example.com');
    expect(await source.loadSettingValue('mirror'), '1');
    expect(await source.loadSettingValue('nsfw'), false);

    // baseUrl getter 同步读设置（同步通道验证）。
    expect(
        await runtime.evalJson(
            'globalThis.__veneraSources["settings_fixture"].baseUrl'),
        'default.example.com');

    // 保存 → 持久化 → 重启（dispose 重载）仍生效。
    await source.saveSettingValue('domains', 'custom.example.org');
    await source.saveSettingValue('mirror', '2');
    await source.saveSettingValue('nsfw', true);
    runtime.dispose();
    source = await makeSource(runtime);
    // ignore: avoid_print
    print('[VSDBG] store direct=${runtime.store.value('setting/settings_fixture/domains')} '
        'kvAll=${runtime.store.exportData()}');
    expect(await source.loadSettingValue('domains'), 'custom.example.org');
    expect(await source.loadSettingValue('mirror'), '2');
    expect(await source.loadSettingValue('nsfw'), true);
    expect(
        await runtime.evalJson(
            'globalThis.__veneraSources["settings_fixture"].baseUrl'),
        'custom.example.org');

    // callback 型：经 settings.<k>.callback 调用（this 绑定到源实例）。
    await VeneraJsRuntime.instance
        .callMethod('settings_fixture', 'settings.cleanup.callback', []);
    expect(
        await runtime.evalJson(
            'globalThis.__veneraSources["settings_fixture"].cleaned'),
        true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
