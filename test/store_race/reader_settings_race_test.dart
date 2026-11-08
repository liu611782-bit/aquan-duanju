import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/reader/reader_settings.dart';
import 'package:aquan_duanju/store/stores.dart';

/// ReaderSettingsStore 写队列并发回归锁（11-08-store-race-final）。
///
/// 场景：阅读器全局设置替换（`update`，高频——面板拖动字号/行距逐帧写）与
/// 按书覆盖（`setBookOverride`）、备份恢复（`importData`）并发触发。
///
/// 本库语义：三个写者都是**全量覆写**（整文档由内存态构建），后写者胜是既有
/// 语义（importData 整体替换内存态，会把更早的全局替换/按书覆盖合法覆盖掉）。
/// 并发锁要锁住的是：**落盘文档 == 最终内存态**——队列外的旧版读改写会把
/// 中间快照写回盘（盘上出现比内存旧的撕裂文档），入队后不可能。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_reader_settings.json');

Future<ReaderSettingsStore> _newStore(Directory dir) async {
  final store = ReaderSettingsStore(testDirectory: dir);
  await store.loadFromDisk();
  return store;
}

void main() {
  test('Future.wait 混合写：整体替换 + 按书覆盖 + 备份恢复，落盘=最终内存态',
      () async {
    final dir = await Directory.systemTemp.createTemp('reader_settings_race');
    addTearDown(() => dir.delete(recursive: true));
    final store = await _newStore(dir);

    // 同一事件循环内的并发混合写：整体替换（模拟面板连续调整）+ 2 本书的
    // 按书覆盖 + 备份恢复（带独立标记 volumeKeyPage，用于判定最后写者）。
    final futures = <Future<void>>[
      store.update(const ReaderSettings(
        mode: ReaderMode.paged,
        autoTurn: true,
        autoIntervalSec: 90,
      )),
      store.setBookOverride(
          'book-a', ReaderSettings.bookFieldMode, ReaderMode.scroll.name),
      store.setBookOverride(
          'book-b', ReaderSettings.bookFieldFontScale, 1.25),
      store.importData(<String, dynamic>{
        'settings': const ReaderSettings(
          mode: ReaderMode.scroll,
          volumeKeyPage: true,
        ).toJson(),
      }),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、settings 键在。
    final raw = _file(dir).readAsStringSync();
    final json = jsonDecode(raw) as Map<String, dynamic>;
    expect(json.containsKey('settings'), isTrue);

    // 关键回归锁：落盘文档逐字节等于最终内存态（无旧快照回写/撕裂文档）。
    expect(
      raw,
      jsonEncode(<String, dynamic>{'settings': store.value.toJson()}),
    );

    // 后写者胜（既有全量覆写语义）：importData 整体替换内存态。
    final store2 = await _newStore(dir);
    expect(store2.value.volumeKeyPage, isTrue, reason: '备份恢复（最后写者）胜出');
    expect(store2.value.mode, ReaderMode.scroll);
    expect(store2.value.bookOverrideOf('book-a'), isNull,
        reason: 'importData 全量替换内存态属既有语义（非竞态丢失，盘内存一致）');
    expect(store2.value.bookOverrideOf('book-b'), isNull);
  });
}
