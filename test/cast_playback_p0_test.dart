import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/local_media_server.dart';
import 'package:aquan_duanju/core/player/playback_buffer_monitor.dart';
import 'package:aquan_duanju/core/player/playback_health.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  // 刻意不初始化 TestWidgetsFlutterBinding：它会把所有 HttpClient 请求
  // 拦成 400，本地媒体服务的 Range 测试就没法做了。
  group('R1 controlURL 兜底', () {
    const location = 'http://192.168.1.20:49152/description.xml';

    test('localhost 换成 LOCATION 的 host 并继承端口', () {
      final uri = rebuildControlUrl(
        controlUrl: 'http://localhost/AVTransport/control',
        location: location,
      )!;
      expect(uri.host, '192.168.1.20');
      expect(uri.port, 49152);
      expect(uri.path, '/AVTransport/control');
    });

    test('127.0.0.1 同样被替换', () {
      final uri = rebuildControlUrl(
        controlUrl: 'http://127.0.0.1:9999/ctl',
        location: location,
      )!;
      expect(uri.host, '192.168.1.20');
      // controlURL 自己写了端口就尊重它（部分设备控制端口与描述端口不同）。
      expect(uri.port, 9999);
    });

    test('域名 + LOCATION 是 IP 时优先 IP', () {
      final uri = rebuildControlUrl(
        controlUrl: 'http://tvbox.local:8080/upnp/control/AVTransport',
        location: location,
      )!;
      expect(uri.host, '192.168.1.20');
      expect(uri.port, 8080);
    });

    test('controlURL 为空时按惯例路径猜', () {
      final uri = rebuildControlUrl(controlUrl: '', location: location)!;
      expect(uri.toString(), 'http://192.168.1.20:49152/AVTransport/control');
    });

    test('LOCATION 不可解析时原样返回 controlURL', () {
      final uri = rebuildControlUrl(
        controlUrl: 'http://10.0.0.2:80/ctl',
        location: '',
      )!;
      expect(uri.host, '10.0.0.2');
    });

    test('设备描述缺 controlURL 也能解析出设备', () {
      const xml = '''
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <device>
    <UDN>uuid:test</UDN>
    <friendlyName>客厅电视</friendlyName>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <controlURL>http://localhost:49152/AVTransport/control</controlURL>
      </service>
    </serviceList>
  </device>
</root>''';
      final device = parseDeviceDescription(xml, location);
      expect(device, isNotNull);
      expect(device!.controlUrl, contains('192.168.1.20'));
      expect(device.friendlyName, '客厅电视');
    });
  });

  group('R3 本地媒体服务', () {
    late Directory dir;
    late File file;
    late LocalMediaServer server;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('media_server');
      file = File('${dir.path}${Platform.pathSeparator}ep1.mp4');
      // 1000 字节递增内容，便于校验 Range 区间。
      await file.writeAsBytes(
        List<int>.generate(1000, (i) => i % 256),
      );
      server = LocalMediaServer(
        defaultPort: 18200,
        portAttempts: 10,
        hostOverride: '127.0.0.1',
      );
    });

    tearDown(() async {
      await server.stop();
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    test('MIME 推断', () {
      expect(mimeTypeForPath('/a/b.mp4'), 'video/mp4');
      expect(mimeTypeForPath('/a/b.MKV'), 'video/x-matroska');
      expect(mimeTypeForPath('/a/b.m3u8'), 'application/vnd.apple.mpegurl');
      expect(mimeTypeForPath('/a/b.unknown'), 'application/octet-stream');
    });

    test('Range 返回 206 且区间正确', () async {
      final url = await server.urlFor(file.path);
      expect(url, isNotNull);
      final res = await http.get(
        Uri.parse(url!),
        headers: <String, String>{'Range': 'bytes=100-199'},
      );
      expect(res.statusCode, 206);
      expect(res.bodyBytes.length, 100);
      expect(res.headers['content-range'], 'bytes 100-199/1000');
      expect(res.headers['content-type'], contains('video/mp4'));
    });

    test('无 Range 返回整文件，HEAD 给长度', () async {
      final url = await server.urlFor(file.path);
      final res = await http.get(Uri.parse(url!));
      expect(res.statusCode, 200);
      expect(res.bodyBytes.length, 1000);

      final head = await http.head(Uri.parse(url));
      expect(head.statusCode, 200);

      // Dart 的 HttpClient 会把 HEAD 响应的 contentLength 归零（不管服务器发什么），
      // 所以这里用裸 socket 校验服务端真的发了正确的头。
      final uri = Uri.parse(url);
      final socket = await Socket.connect(uri.host, uri.port);
      socket.write('HEAD ${uri.path} HTTP/1.1\r\nHost: ${uri.host}\r\n\r\n');
      await socket.flush();
      final raw = await socket.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      await socket.close();
      final headerText = ascii.decode(raw, allowInvalid: true);
      expect(headerText, contains('HTTP/1.1 200 OK'));
      expect(headerText, contains('Content-Length: 1000'));
      expect(headerText, contains('Accept-Ranges: bytes'));
    });

    test('未知 token 返回 404，路径不暴露真实文件名', () async {
      final url = await server.urlFor(file.path);
      expect(url!.contains('ep1.mp4'), isFalse);
      final base = server.baseUrl!;
      final res = await http.get(Uri.parse('$base/m/nope'));
      expect(res.statusCode, 404);
    });

    test('suffix Range（bytes=-n）返回末尾 n 字节', () async {
      final url = await server.urlFor(file.path);
      final res = await http.get(
        Uri.parse(url!),
        headers: <String, String>{'Range': 'bytes=-100'},
      );
      expect(res.statusCode, 206);
      expect(res.bodyBytes.length, 100);
      expect(res.headers['content-range'], 'bytes 900-999/1000');
    });

    test('不可满足的 Range → 416（不再退化整文件 200）', () async {
      final url = await server.urlFor(file.path);
      for (final bad in ['bytes=1000-', 'bytes=1000-2000', 'bytes=5-2',
        'bytes=0-1,3-4', 'bytes=abc']) {
        final res = await http.get(
          Uri.parse(url!),
          headers: <String, String>{'Range': bad},
        );
        expect(res.statusCode, 416, reason: '$bad 应判不可满足');
      }
    });

    test('方法白名单：POST → 405', () async {
      final url = await server.urlFor(file.path);
      final res = await http.post(Uri.parse(url!), body: 'x');
      expect(res.statusCode, 405);
    });

    test('start 幂等', () async {
      expect(await server.start(), isTrue);
      final first = server.baseUrl;
      expect(await server.start(), isTrue);
      expect(server.baseUrl, first);
    });
  });

  group('R4 慢缓冲判定', () {
    late DateTime now;
    late PlaybackBufferMonitor monitor;

    setUp(() {
      now = DateTime(2026, 10, 30, 12);
      monitor = PlaybackBufferMonitor(clock: () => now);
    });

    void advance(int seconds) => now = now.add(Duration(seconds: seconds));

    test('起播超时', () {
      monitor.onOpen();
      advance(10);
      expect(monitor.tick(), isNull);
      advance(6);
      final verdict = monitor.tick();
      expect(verdict?.issue, BufferIssue.startupTimeout);
    });

    test('起播成功后不再判超时', () {
      monitor.onOpen();
      advance(3);
      monitor.onPlaying();
      advance(30);
      expect(monitor.tick(), isNull);
    });

    test('单次长缓冲', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onBuffering(true);
      advance(9);
      final verdict = monitor.tick();
      expect(verdict?.issue, BufferIssue.longBuffer);
    });

    test('频繁缓冲', () {
      monitor.onOpen();
      monitor.onPlaying();
      for (var i = 0; i < 3; i++) {
        monitor.onBuffering(true);
        advance(1);
        monitor.onBuffering(false);
        advance(5);
      }
      final verdict = monitor.tick();
      expect(verdict?.issue, BufferIssue.frequentBuffer);
    });

    test('累计缓冲', () {
      // 关掉频繁判定，专测累计时长。
      monitor = PlaybackBufferMonitor(clock: () => now, frequentCount: 99);
      monitor.onOpen();
      monitor.onPlaying();
      // 6 次各 5s，中间留 1s 播放 → 累计 30s。
      for (var i = 0; i < 6; i++) {
        monitor.onBuffering(true);
        advance(5);
        monitor.onBuffering(false);
        advance(1);
      }
      final verdict = monitor.tick();
      expect(verdict?.issue, BufferIssue.accumulatedBuffer);
    });

    test('seek 宽限期内不判', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onSeek();
      monitor.onBuffering(true);
      advance(3);
      expect(monitor.tick(), isNull);
      // 宽限期结束且单次缓冲已达 8s → 判长缓冲。
      advance(6);
      expect(monitor.tick()?.issue, BufferIssue.longBuffer);
    });

    test('冷却期内不重复上报', () {
      monitor.onOpen();
      monitor.onPlaying();
      monitor.onBuffering(true);
      advance(9);
      expect(monitor.tick(), isNotNull);
      monitor.onBuffering(true);
      advance(9);
      expect(monitor.tick(), isNull);
      advance(60);
      expect(monitor.tick(), isNotNull);
    });
  });

  group('R5 线路健康度', () {
    late DateTime now;
    late PlaybackHealthRegistry registry;

    setUp(() {
      now = DateTime(2026, 10, 30, 12);
      registry = PlaybackHealthRegistry(clock: () => now);
    });

    test('key 拼装与占位', () {
      expect(
        PlaybackHealthRegistry.keyOf(
          sourceKey: 's1',
          seriesId: 'drama1',
          episode: 3,
          line: 1,
        ),
        's1|drama1|3|1',
      );
      expect(
        PlaybackHealthRegistry.keyOf(sourceKey: '', seriesId: 'd'),
        '-|d|0|0',
      );
    });

    test('成功加分、慢缓冲减分、失败大幅减分', () {
      const key = 's|d|1|0';
      expect(registry.scoreOf(key), PlaybackHealthRecord.defaultScore);
      registry.record(key, PlaybackHealthEvent.success);
      expect(registry.scoreOf(key), 68);
      registry.record(key, PlaybackHealthEvent.slowBuffer);
      expect(registry.scoreOf(key), 62);
      registry.record(key, PlaybackHealthEvent.failed);
      expect(registry.scoreOf(key), 42);
    });

    test('失败后冷却，成功后解除', () {
      const key = 's|d|1|0';
      registry.record(key, PlaybackHealthEvent.failed);
      expect(registry.isCoolingDown(key), isTrue);
      now = now.add(const Duration(minutes: 31));
      expect(registry.isCoolingDown(key), isFalse);
      registry.record(key, PlaybackHealthEvent.failed);
      registry.record(key, PlaybackHealthEvent.success);
      expect(registry.isCoolingDown(key), isFalse);
    });

    test('冷却中的线路排到最后，其余按分降序且稳定', () {
      const healthy = 's|d|1|0';
      const shaky = 's|d|1|1';
      const dead = 's|d|1|2';
      registry.record(healthy, PlaybackHealthEvent.success);
      registry.record(healthy, PlaybackHealthEvent.success);
      registry.record(shaky, PlaybackHealthEvent.slowBuffer);
      registry.record(dead, PlaybackHealthEvent.failed);
      final ranked = registry.rankLines<String>(
        <String>[dead, shaky, healthy],
        (key) => key,
      );
      expect(ranked, <String>[healthy, shaky, dead]);
    });

    test('超过保留期淘汰', () {
      const key = 's|d|1|0';
      registry.record(key, PlaybackHealthEvent.success);
      now = now.add(const Duration(days: 31));
      registry.prune();
      expect(registry.records.containsKey(key), isFalse);
    });

    test('JSON 往返', () {
      registry.record('s|d|1|0', PlaybackHealthEvent.success);
      final restored = PlaybackHealthRegistry(clock: () => now)
        ..loadFromJson(registry.toJson());
      expect(restored.scoreOf('s|d|1|0'), 68);
    });
  });

  group('R6 进度语义', () {
    late Directory dir;
    late HistoryStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('history');
      store = HistoryStore(testDirectory: dir);
      await store.ensureLoaded();
    });

    tearDown(() async {
      if (await dir.exists()) await dir.delete(recursive: true);
    });

    Future<void> record({
      required double position,
      required double duration,
      bool? finished,
    }) =>
        store.record(
          seriesId: 'd1',
          title: '剧',
          coverUrl: '',
          episode: 1,
          episodes: 10,
          episodeId: 'e1',
          position: position,
          durationSeconds: duration,
          finished: finished,
        );

    test('看完阈值', () {
      expect(HistoryEntry.shouldMarkFinished(960, 1000), isTrue);
      expect(HistoryEntry.shouldMarkFinished(900, 1000), isFalse);
      expect(HistoryEntry.shouldMarkFinished(100, 0), isFalse);
    });

    test('未显式传 finished 时按时长判定', () async {
      await record(position: 960, duration: 1000);
      expect(store.entry('d1')!.finished, isTrue);
    });

    test('时长未知时沿用旧值', () async {
      await record(position: 50, duration: 0, finished: false);
      await record(position: 60, duration: 0);
      expect(store.entry('d1')!.finished, isFalse);
    });

    test('resumable 语义', () {
      final short = HistoryEntry(
        seriesId: 'a',
        position: 10,
        updatedAt: DateTime(2026),
      );
      final long = HistoryEntry(
        seriesId: 'b',
        position: 300,
        updatedAt: DateTime(2026),
      );
      final done = HistoryEntry(
        seriesId: 'c',
        position: 1000,
        finished: true,
        updatedAt: DateTime(2026),
      );
      expect(short.resumable, isFalse);
      expect(long.resumable, isTrue);
      expect(done.resumable, isFalse);
    });
  });
}
