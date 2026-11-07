import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// SearchHistoryStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：连续搜索提交（`record`，去重置顶）与删除（`remove`）同刻并发触发。
/// 混合调用全部完成后重读 `aquan_search_history.json`：queries 全部在、
/// 顺序与去重正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_search_history.json');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('search_history_race');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  test('Future.wait 混合写：多次搜索 + 同词重复 + 删除，全部落盘无键丢失', () async {
    final store = SearchHistoryStore();
    await store.ensureLoaded();

    // 先落一条将被并发删除的词。
    await store.record('旧词');

    // 同一事件循环内的并发混合写：6 个新词 + 同一词重复 3 次（去重置顶）+
    // 1 个删除。
    final futures = <Future<void>>[
      for (var i = 1; i <= 6; i++) store.record('词$i'),
      for (var i = 1; i <= 3; i++) store.record('重复词'),
      store.remove('旧词'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(support).readAsStringSync()) as Map<String, dynamic>;
    final queries = (json['queries'] as List).cast<String>();
    expect(queries.first, '重复词', reason: '最后提交的词置顶');
    expect(queries, containsAll(<String>['词1', '词2', '词3', '词4', '词5', '词6']));
    expect(queries, isNot(contains('旧词')), reason: '并发删除不被旧快照写回');
    expect(queries.where((q) => q == '重复词').length, 1, reason: '去重');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = SearchHistoryStore();
    await store2.ensureLoaded();
    expect(store2.queries, queries);
  });

  test('条件跳过语义回归：删除不存在的词不写盘', () async {
    final store = SearchHistoryStore();
    await store.ensureLoaded();
    await store.record('词1');

    final before = _file(support).readAsStringSync();
    await store.remove('不存在');
    expect(_file(support).readAsStringSync(), before, reason: '无变化不写盘');
  });
}
