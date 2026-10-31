// spider 源 ext 字段落库：SourceConfig 往返 + addCandidates 携带。
import 'dart:io';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_spider_ext');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  test('SourceConfig.ext 持久化往返；缺省为空串（旧 json 兼容）', () {
    final withExt = SourceConfig(
      id: 's1',
      name: 'JS 源',
      apis: ['https://x.example/a.js'],
      kind: SourceKind.spiderJs,
      ext: '{"theme":"dark"}',
    );
    final roundtrip = SourceConfig.fromJson(withExt.toJson());
    expect(roundtrip.ext, '{"theme":"dark"}');

    final legacy = SourceConfig.fromJson({
      'id': 's2',
      'name': '老源',
      'apis': ['https://x.example/b.json'],
    });
    expect(legacy.ext, '');
  });

  test('addCandidates 携带候选的 ext 入库', () async {
    final store = SourcesStore();
    final report = ImportReport();
    report.add(SourceCandidate(
      name: 'JS 测试源',
      api: 'https://x.example/spider.js',
      kind: SourceKind.spiderJs,
      spiderKey: 'js_key',
      ext: '{"site":"demo"}',
    ));
    final added = await store.addCandidates(report.added);
    expect(added, 1);
    final config = store.byApi('https://x.example/spider.js');
    expect(config, isNotNull);
    expect(config!.ext, '{"site":"demo"}');
    expect(config.spiderKey, 'js_key');
    // 重启（重新 loadFromDisk）后仍在。
    final store2 = SourcesStore();
    await store2.ensureLoaded();
    final config2 = store2.byApi('https://x.example/spider.js');
    expect(config2?.ext, '{"site":"demo"}');
  });
}
