import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// ReplaceRuleStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：阅读器并发加规则（`add`）、切换内置开关（`setEnabled`）、删规则
/// （`remove`）。混合调用全部完成后重读 `aquan_replace_rules.json`：
/// 键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_replace_rules.json');

Future<ReplaceRuleStore> _newStore(Directory dir) async {
  final store = ReplaceRuleStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：加规则 + 内置开关 + 删除，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('replace_rule_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：3 条自定义规则 + 内置开关 + 删内置规则。
    final futures = <Future<void>>[
      for (var i = 1; i <= 3; i++)
        store.add(name: '规则$i', pattern: '广告$i', replacement: ''),
      store.setEnabled('builtin_url', false),
      store.remove('builtin_promo'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、三键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['rules', 'hidden_builtin', 'builtin_enabled']));
    final rules = json['rules'] as List;
    expect(rules.length, 3, reason: '自定义规则不被并发写抹掉');
    expect((json['hidden_builtin'] as List), contains('builtin_promo'));
    expect(json['builtin_enabled'], containsPair('builtin_url', false));

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    // 4 条内置 − 1 条已删（hidden）= 3 条可见内置 + 3 条自定义 = 6。
    expect(store2.rules.length, 6, reason: '3 条自定义 + 3 条可见内置');
    expect(store2.rules.any((r) => r.name == '规则3'), isTrue);
    expect(store2.forBook('').any((r) => r.id == 'builtin_promo'), isFalse,
        reason: '删除内置不被并发写回');
    expect(
        store2.rules
            .firstWhere((r) => r.id == 'builtin_url')
            .enabled,
        isFalse,
        reason: '内置开关不被并发写覆盖');
  });
}
