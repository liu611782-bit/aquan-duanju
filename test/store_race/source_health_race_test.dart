import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/store/stores.dart';

/// SourceHealthStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：搜索/播放回调并发记健康（`recordSuccess` / `recordFailure`，本库
/// 写放大最重的混合场景）。混合调用全部完成后重读 `aquan_source_health.json`：
/// 键全在、值正确，JSON 完整可读、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_source_health.json');

Future<SourceHealthStore> _newStore(Directory dir) async {
  final store = SourceHealthStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：多次成功 + 失败 + 备份恢复，全部落盘无键丢失', () async {
    final dir = await Directory.systemTemp.createTemp('source_health_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：5 个源的成功/失败回调 + 1 条备份恢复。
    final futures = <Future<void>>[
      for (var i = 1; i <= 5; i++) store.recordSuccess('src$i', 100 * i),
      store.recordFailure('src3', '超时'),
      store.recordFailure('src4', '404', playFailure: true),
      store.importData(<String, dynamic>{
        'health': <String, dynamic>{
          'src-bak': <String, dynamic>{'successes': 3, 'failures': 1},
        },
      }),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、键全在。
    final json =
        jsonDecode(_file(dir).readAsStringSync()) as Map<String, dynamic>;
    final health = json['health'] as Map<String, dynamic>;
    expect(
      health.keys,
      containsAll(<String>['src1', 'src2', 'src3', 'src4', 'src5', 'src-bak']),
    );
    expect(json['version'], 1);

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = await _newStore(dir);
    expect(store2.recordOf('src1').successes, 1);
    expect(store2.recordOf('src3').failures, 1,
        reason: '失败回调不被并发成功回调覆盖');
    expect(store2.recordOf('src3').lastError, '超时');
    expect(store2.recordOf('src4').lastError, '404');
    expect(store2.recordOf('src-bak').successes, 3,
        reason: '备份恢复不被并发回调覆盖');
    expect(store2.recordOf('src-bak').failures, 1);
  });
}
