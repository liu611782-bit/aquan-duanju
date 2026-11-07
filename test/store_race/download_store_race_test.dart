import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// DownloadStore 写队列并发回归锁（11-07-store-write-race-migration）。
///
/// 场景：多任务并行下载各自完成即落盘（`record`，`download_service.dart:542`）、
/// 下载目录迁移改路径（`updateFilePath`，:437）、用户删除（`removeEpisode` /
/// `removeSeries`，:341/:364）同刻并发触发。混合调用全部完成后重读
/// `aquan_downloads.json`：两层嵌套键全在、值正确、无键丢失。

File _file(Directory dir) =>
    File('${dir.path}${Platform.pathSeparator}aquan_downloads.json');

DownloadEntry _entry(String series, int n) => DownloadEntry(
  seriesId: series,
  seriesTitle: '剧$series',
  coverUrl: 'cover-$series',
  episodeId: '$series-ep$n',
  number: n,
  title: '第$n集',
  filePath: '/old/$series/$n.mp4',
  sizeBytes: 1024 * n,
  keyHex: '',
  quality: '1080P',
  downloadedAt: DateTime.now(),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('download_race');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  test('Future.wait 多任务并发：8 集完成写 + 改路径 + 删集 + 删剧，无键丢失', () async {
    final store = DownloadStore();
    await store.ensureLoaded();

    // 先落将被并发改路径/删除的记录（真实时序：先有记录再迁移/删除）。
    await store.record(_entry('s0', 1));
    await store.record(_entry('s0', 2));
    await store.record(_entry('s-del', 1));
    await store.record(_entry('s-del', 2));

    // 同一事件循环内的并发混合写（模拟多任务并行下载各集完成）：
    // 两部剧 × 4 集的完成写 + 两集改路径 + 一集删除 + 一部剧删除。
    final futures = <Future<void>>[
      for (final series in <String>['s1', 's2'])
        for (var n = 1; n <= 4; n++) store.record(_entry(series, n)),
      store.updateFilePath('s0-ep1', '/new/s0/1.mp4'),
      store.updateFilePath('s0-ep2', '/new/s0/2.mp4'),
      store.removeEpisode('s-del-ep1'),
      store.removeSeries('s-del'),
    ];
    await Future.wait(futures);

    // 全部完成后重读 JSON：完整可读、两层键全在。
    final json =
        jsonDecode(_file(support).readAsStringSync()) as Map<String, dynamic>;
    expect(json.keys, containsAll(<String>['s0', 's1', 's2']));
    expect(json.containsKey('s-del'), isFalse, reason: '并发删剧不被旧快照写回');
    final s1 = json['s1'] as Map<String, dynamic>;
    final s2 = json['s2'] as Map<String, dynamic>;
    expect(
      s1.keys,
      containsAll(<String>['s1-ep1', 's1-ep2', 's1-ep3', 's1-ep4']),
    );
    expect(s2.keys, hasLength(4));
    expect((json['s0'] as Map)['s0-ep1']['file_path'], '/new/s0/1.mp4');
    expect((json['s0'] as Map)['s0-ep2']['file_path'], '/new/s0/2.mp4');

    // 新实例（模拟重启）读回：全部键值正确。
    final store2 = DownloadStore();
    await store2.ensureLoaded();
    expect(store2.episodesOf('s1'), hasLength(4));
    expect(store2.episodesOf('s2'), hasLength(4));
    expect(store2.entryOf('s1-ep3')!.sizeBytes, 1024 * 3);
    expect(
      store2.entryOf('s0-ep1')!.filePath,
      '/new/s0/1.mp4',
      reason: '路径迁移不被并发完成写覆盖',
    );
    expect(store2.entryOf('s-del-ep2'), isNull, reason: '整剧删除后无残留集');
    expect(store2.has('s-del-ep1'), isFalse);
  });

  test('同一写者多次 + 顺序写回归：同集重下新记录胜出', () async {
    final store = DownloadStore();
    await store.ensureLoaded();

    await store.record(_entry('s1', 1));
    await store.record(_entry('s1', 1).copyWith(filePath: '/retry/s1/1.mp4'));
    await store.record(_entry('s1', 2));

    final store2 = DownloadStore();
    await store2.ensureLoaded();
    expect(
      store2.entryOf('s1-ep1')!.filePath,
      '/retry/s1/1.mp4',
      reason: '同集重复下载以新记录为准',
    );
    expect(store2.episodesOf('s1'), hasLength(2));
  });
}
