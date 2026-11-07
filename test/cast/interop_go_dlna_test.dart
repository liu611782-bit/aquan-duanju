// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';

/// 第三方互操作冒烟（design §9.2 承诺项）：
/// 用本机 windows-dlna-receiver（go-dlna 独立实现 + mpv 真播放）验证发送端全链
/// ——发现 / 投送 / PLAYING / seek / stop。
///
/// 环境门控：设 `AQUAN_INTEROP=1` 才运行（普通 CI/开发机跳过）。可选覆盖：
/// - AQUAN_INTEROP_GODLNA   go-dlna.exe 路径（默认 D:\IdeaProjects\windows-dlna-receiver\go-dlna.exe）
/// - AQUAN_INTEROP_MPV      mpv.exe 路径（默认 C:\Program Files\MPV Player\mpv.exe）
/// - AQUAN_INTEROP_FFMPEG   ffmpeg.exe 路径（默认 PATH / winget Links）
///
/// 运行（Git Bash）：
/// ```bash
/// env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
///   AQUAN_INTEROP=1 C:/flutter/bin/flutter.bat test test/cast/interop_go_dlna_test.dart
/// ```
void main() {
  final enabled = Platform.environment['AQUAN_INTEROP'] == '1';
  if (!enabled) return; // 未开启互操作环境：整文件跳过

  final godlnaPath = Platform.environment['AQUAN_INTEROP_GODLNA'] ??
      r'D:\IdeaProjects\windows-dlna-receiver\go-dlna.exe';
  final mpvPath = Platform.environment['AQUAN_INTEROP_MPV'] ??
      r'C:\Program Files\MPV Player\mpv.exe';
  final ffmpegPath = Platform.environment['AQUAN_INTEROP_FFMPEG'] ?? 'ffmpeg';

  const httpPort = 19091;
  const fixtureSeconds = 12;

  Process? receiver;
  late Directory workDir;
  late Uri mediaUrl;
  HttpServer? mediaServer;

  setUpAll(() async {
    expect(File(godlnaPath).existsSync(), isTrue,
        reason: 'go-dlna.exe 不存在：先 go build -o go-dlna.exe .');
    expect(File(mpvPath).existsSync(), isTrue, reason: 'mpv.exe 不存在');

    // 生成测试媒体（12s testsrc，H.264，320x240）。
    workDir = await Directory.systemTemp.createTemp('interop_godlna');
    final media = File('${workDir.path}${Platform.pathSeparator}smoke.mp4');
    final gen = await Process.run(ffmpegPath, [
      '-y', '-f', 'lavfi', '-i',
      'testsrc=duration=$fixtureSeconds:size=320x240:rate=15',
      '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
      media.path,
    ]);
    expect(gen.exitCode, 0, reason: 'ffmpeg 生成测试媒体失败：${gen.stderr}');

    // 本地伺服测试媒体（真实 HTTP，带 Range）。
    final server = await HttpServer.bind('127.0.0.1', 0);
    mediaServer = server;
    server.listen((req) async {
      final f = File(media.path);
      final length = f.lengthSync();
      final range = req.headers.value('range');
      final status = range == null ? 200 : 206;
      int start = 0, end = length - 1;
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range)!;
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = int.parse(m[2]!);
      }
      req.response.statusCode = status;
      req.response.headers.contentType =
          ContentType.parse('video/mp4; charset=utf-8');
      req.response.headers.set('Content-Length', '${end - start + 1}');
      if (range != null) {
        req.response.headers.set('Content-Range', 'bytes $start-$end/$length');
      }
      req.response.headers.set('Accept-Ranges', 'bytes');
      await req.response.addStream(f.openRead(start, end + 1));
      await req.response.close();
    });
    mediaUrl = Uri.parse('http://127.0.0.1:${server.port}/smoke.mp4');

    // go-dlna 的 configPath() 是 exe 同目录：把 exe 拷进临时目录再配配置。
    final exeCopy =
        File('${workDir.path}${Platform.pathSeparator}go-dlna.exe');
    File(godlnaPath).copySync(exeCopy.path);

    // 预写配置（首启自动生成会用错 mpv 路径与端口）。
    File('${workDir.path}${Platform.pathSeparator}config.ini').writeAsStringSync('''
[config]
mpv_path = $mpvPath
friendly_name = go投屏接收器
http_port = $httpPort
interface_ip =
fullscreen = no
udn =
''');

    receiver = await Process.start(exeCopy.path, [],
        workingDirectory: workDir.path,
        mode: ProcessStartMode.normal);
    receiver!.stdout
        .transform(const SystemEncoding().decoder)
        .listen(print, onDone: () => print('[go-dlna] exited'));
    receiver!.stderr
        .transform(const SystemEncoding().decoder)
        .listen((e) => print('[go-dlna][err] $e'));
    // 等 HTTP 服务就绪。
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(deadline)) {
      try {
        await HttpClient()
            .headUrl(Uri.parse('http://127.0.0.1:$httpPort/rootDesc.xml'))
            .then((r) => r.close());
        return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    fail('go-dlna 15s 内未就绪（HTTP $httpPort）');
  });

  tearDownAll(() async {
    receiver?.kill();
    await mediaServer?.close(force: true);
    try {
      await workDir.delete(recursive: true);
    } catch (_) {}
  });

  test('真实 SSDP 发现（尽力而为：同机组播可达则断言独立实现报文）', () async {
    final discovery = SsdpDiscovery();
    final found = <DlnaDevice>[];
    final sub = discovery.start().listen((e) {
      if (e is SsdpDeviceFound) found.add(e.device);
    });
    // go-dlna 每 60s 发 alive；窗口内收不到算环境限制（SSDPSRV/多 TAP），不算失败。
    await Future<void>.delayed(const Duration(seconds: 12));
    await discovery.stop();
    await sub.cancel();
    final hit = found.where((d) => d.friendlyName.contains('go投屏接收器')).toList();
    if (hit.isEmpty) {
      print('[interop] 12s 窗口内未收到同机组播 NOTIFY（环境限制，addByIp 路径已在用例 2 验证）');
      return;
    }
    expect(hit.first.udn, startsWith('uuid:'));
  });

  test('发现：addByIp 命中 go-dlna 并解析设备描述', () async {
    final discovery = SsdpDiscovery();
    final device = await discovery.addByIp('127.0.0.1', port: httpPort);
    expect(device, isNotNull);
    expect(device!.friendlyName, contains('go投屏接收器'));
    expect(device.controlUrl, isNotEmpty);
  });

  test('全链：投送 → PLAYING → seek → 停止', () async {
    final discovery = SsdpDiscovery();
    final device = (await discovery.addByIp('127.0.0.1', port: httpPort))!;
    final target = CastTarget.dlna(device);
    final transport = defaultTransportFactory(target);

    // 标准序列：SetAVTransportURI → Play（与控制器 castTo 同款）。
    await transport.setUri(mediaUrl, title: 'InteropSmoke');
    await transport.play();

    // 等 mpv 真实起播（独立实现 + 真播放器，预算放宽到 30s）。
    var poll = await transport.poll();
    final playingDeadline = DateTime.now().add(const Duration(seconds: 30));
    while (!poll.isRunning && DateTime.now().isBefore(playingDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      poll = await transport.poll();
    }
    expect(poll.isRunning, isTrue,
        reason: '30s 内未进 PLAYING（state=${poll.transportState}）');

    // seek 到 5s。真实发现（本冒烟的产出之一）：mpv 系接收端在 PLAYING 初段
    // seek 会瞬态失败（mpv IPC seek failed → 接收端 500 fault），生产链路对
    // Seek 失败本就吞掉（M2 契约）；这里按真实使用重试至多 3 次。
    Object? seekError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        await transport.seekTo(const Duration(seconds: 5));
        seekError = null;
        break;
      } catch (e) {
        seekError = e;
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    expect(seekError, isNull, reason: 'seek 三次均失败：$seekError');
    await Future<void>.delayed(const Duration(seconds: 2));
    final afterSeek = await transport.poll();
    expect(afterSeek.position.inMilliseconds,
        inInclusiveRange(3500, 8500),
        reason: 'seek 后位置异常：${afterSeek.position}');

    await transport.stop();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    final afterStop = await transport.poll();
    expect(afterStop.transportState, anyOf('STOPPED', 'NO_MEDIA_PRESENT'));
    transport.close();
  }, timeout: const Timeout(Duration(seconds: 90)));
}
