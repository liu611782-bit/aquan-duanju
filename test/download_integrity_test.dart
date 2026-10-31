import 'dart:io';

import 'package:aquan_duanju/core/download_service.dart';
import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Episode ep(int n) => Episode(
      id: 's1-e$n',
      seriesId: 's1',
      number: n,
      title: '第$n集',
      playable: true,
    );

Series series() => const Series(id: 's1', title: '测试剧');

/// 等服务队列跑完（isBusy 变 false 且二次确认不再变化）。
Future<void> _drain(DownloadService service) async {
  for (var i = 0; i < 200; i++) {
    if (!service.isBusy) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (!service.isBusy) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  fail('下载队列 4 秒内未跑完');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory support;
  setUp(() {
    support = Directory.systemTemp.createTempSync('aquan_dl_integrity');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => support.path);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      support.deleteSync(recursive: true);
    });
  });

  Directory baseDir() => Directory('${support.path}/downloads');

  test('少字节：拒绝 completed，重试预算内续传补齐', () async {
    final store = DownloadStore();
    var attempt = 0;
    final service = DownloadService(
      store: store,
      baseDir: baseDir(),
      resolver: (ep) async =>
          ResolvedMedia(url: 'https://cdn.test/a.mp4', expectedBytes: 100),
      downloader: (url, path, onProgress, isCancelled) async {
        attempt++;
        final existing =
            File(path).existsSync() ? File(path).lengthSync() : 0;
        final add = List.filled(existing == 0 ? 60 : 40, 7);
        final sink = File(path).openWrite(mode: FileMode.append);
        sink.add(add);
        await sink.flush();
        await sink.close();
        return existing + add.length;
      },
      maxRetries: 1,
      retryDelay: const Duration(milliseconds: 10),
    );
    service.enqueue(series(), [ep(1)]);
    await _drain(service);

    expect(attempt, 2, reason: '第一次 60/100 不完整 → 自动重试续传');
    expect(service.taskOf('s1-e1')!.state, DownloadState.done);
    expect(store.entryOf('s1-e1')!.sizeBytes, 100);
  });

  test('重试预算耗尽：标记 failed 但保留 .part 供手动续传', () async {
    final store = DownloadStore();
    final service = DownloadService(
      store: store,
      baseDir: baseDir(),
      resolver: (ep) async =>
          ResolvedMedia(url: 'https://cdn.test/a.mp4', expectedBytes: 100),
      downloader: (url, path, onProgress, isCancelled) async {
        File(path).writeAsBytesSync(List.filled(60, 7));
        return 60;
      },
      maxRetries: 0,
    );
    service.enqueue(series(), [ep(1)]);
    await _drain(service);

    expect(service.taskOf('s1-e1')!.state, DownloadState.failed);
    expect(store.entryOf('s1-e1'), isNull, reason: '不完整不计 completed');
    final part = File('${baseDir().path}/s1/第001集.mp4.part');
    expect(part.existsSync(), isTrue, reason: '.part 保留，重试时续传');
    expect(part.lengthSync(), 60);
  });

  test('超预期：.part 已脏 → 丢弃且不计 completed', () async {
    final store = DownloadStore();
    final service = DownloadService(
      store: store,
      baseDir: baseDir(),
      resolver: (ep) async =>
          ResolvedMedia(url: 'https://cdn.test/a.mp4', expectedBytes: 100),
      downloader: (url, path, onProgress, isCancelled) async {
        File(path).writeAsBytesSync(List.filled(150, 7));
        return 150;
      },
      maxRetries: 0,
    );
    service.enqueue(series(), [ep(1)]);
    await _drain(service);

    expect(service.taskOf('s1-e1')!.state, DownloadState.failed);
    expect(store.entryOf('s1-e1'), isNull);
    expect(
        File('${baseDir().path}/s1/第001集.mp4.part').existsSync(), isFalse,
        reason: '前缀已脏的 .part 必须丢弃，不能作为续传基线');
  });

  test('ensureCurrent：完成前单集被删除 → 不落盘不写记录', () async {
    final store = DownloadStore();
    late DownloadService service;
    service = DownloadService(
      store: store,
      baseDir: baseDir(),
      resolver: (ep) async =>
          ResolvedMedia(url: 'https://cdn.test/a.mp4', expectedBytes: 100),
      downloader: (url, path, onProgress, isCancelled) async {
        File(path).writeAsBytesSync(List.filled(100, 7));
        // 竞态复刻：字节已写满，但用户此刻删除该集。
        await service.deleteEpisode('s1-e1');
        return 100;
      },
    );
    service.enqueue(series(), [ep(1)]);
    await _drain(service);

    expect(service.taskOf('s1-e1')!.state, DownloadState.cancelled);
    expect(store.entryOf('s1-e1'), isNull, reason: '删除后不得写下载记录');
    final seriesDir = Directory('${baseDir().path}/s1');
    final landed = seriesDir
        .listSync()
        .whereType<File>()
        .where((f) => !f.path.endsWith('.part'))
        .toList();
    expect(landed, isEmpty, reason: '不得留下正式 mp4 文件');
  });

  test('defaultDownloader：206 起点错位 → 丢弃 .part 重下', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((req) async {
      if (req.headers.value('range') == 'bytes=50-') {
        // 说谎的 Content-Range：声明的起点与请求不符（源文件已变的形状）。
        req.response.statusCode = 206;
        req.response.headers.set('Content-Range', 'bytes 0-99/100');
        req.response.contentLength = 50;
        req.response.add(List.filled(50, 1));
        await req.response.close();
      } else {
        req.response.statusCode = 200;
        req.response.contentLength = 100;
        req.response.add(List.filled(100, 2));
        await req.response.close();
      }
    });
    HttpOverrides.global = null;
    final partPath = '${support.path}/align_bad.part';
    File(partPath).writeAsBytesSync(List.filled(50, 1));

    final received = await defaultDownloader(
      'http://127.0.0.1:${server.port}/v.mp4',
      partPath,
      null,
      () => false,
    );
    expect(received, 100);
    expect(File(partPath).lengthSync(), 100);
  });

  test('defaultDownloader：对齐的 206 正常续传', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((req) async {
      expect(req.headers.value('range'), 'bytes=50-');
      req.response.statusCode = 206;
      req.response.headers.set('Content-Range', 'bytes 50-99/100');
      req.response.contentLength = 50;
      req.response.add(List.filled(50, 3));
      await req.response.close();
    });
    HttpOverrides.global = null;
    final partPath = '${support.path}/align_ok.part';
    File(partPath).writeAsBytesSync(List.filled(50, 1));

    final received = await defaultDownloader(
      'http://127.0.0.1:${server.port}/v.mp4',
      partPath,
      null,
      () => false,
    );
    expect(received, 100);
    expect(File(partPath).lengthSync(), 100);
  });
}
