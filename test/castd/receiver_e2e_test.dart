/// AC-5 端到端（PRD R5.2）：自家发送端栈（DlnaDevice 解析 / SoapClient /
/// DlnaTransport / GenaSubscriber，全程真实）→ 接收端（ReceiverController
/// 真实 HTTP socket + stub 引擎）→ 投送本地 HTTP 夹具 URL → PLAYING →
/// Pause / Seek / Stop 全链路。
///
/// 环境结论（Phase A 实测）：同机 SSDP 组播不可靠（Windows SSDPSRV 抢占
/// 1900 + 多 TAP 网卡），端到端走「直连 description.xml / addByIp 显式
/// 端口」路径；组播部分单独做**尽力而为**断言（收到了才断言形状，收不到
/// 不算失败——见「SSDP 尽力而为」组）。
///
/// 代理环境剥离：发送端 HTTP 客户端全部显式 `findProxy = DIRECT`
/// （dart:io HttpClient 默认读 *_proxy 环境变量，会劫持 127.0.0.1），
/// 跑法上仍推荐 `env -u http_proxy … flutter test`（与仓库验证命令一致）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/dlna_transport.dart';
import 'package:aquan_duanju/core/cast/gena_subscriber.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/cast/ssdp_discovery.dart';
import 'package:aquan_duanju/core/castd/receiver_admission.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// 显式直连的 HTTP 客户端（不走 *_proxy 环境变量）。
http.Client directHttpClient() {
  final inner = HttpClient()..findProxy = (_) => 'DIRECT';
  return IOClient(inner);
}

/// 本地媒体夹具：真实 HTTP 伺服一段字节，充当「投给接收端的媒体 URL」。
class _MediaFixture {
  HttpServer? _server;
  int requestCount = 0;

  Uri get url =>
      Uri.parse('http://127.0.0.1:${_server!.port}/fixture/e2e-video.mp4');

  /// 封面 URL（query 带 & 验证 full 变体转义 → 接收端实体还原的往返）。
  Uri get coverUrl => Uri.parse(
      'http://127.0.0.1:${_server!.port}/fixture/e2e-cover.jpg?w=600&h=800');

  Future<void> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((req) async {
      requestCount++;
      final body = Uint8List.fromList(
        List<int>.generate(4096, (i) => (i * 7 + 13) & 0xff),
      );
      req.response.headers.contentType = ContentType('video', 'mp4');
      req.response.headers.set('Accept-Ranges', 'bytes');
      req.response.contentLength = body.length;
      if (req.method == 'HEAD') {
        await req.response.close();
        return;
      }
      req.response.add(body);
      await req.response.close();
    });
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

void main() {
  const testBudget = Timeout(Duration(seconds: 25));

  /// 本文件专用的 HTTP 首选端口：`flutter test` 多文件并行跑在各自进程里，
  /// receiver_controller_test 等既有文件用默认 18099——Windows 允许第二个
  /// 进程重复绑定同一端口（不设 SO_EXCLUSIVEADDRUSE），会让旧文件的
  /// 「stop 后端口关闭」断言收到本文件的响应。错开首选端口消除竞争。
  const e2ePreferredPort = 18200;

  group('AC-5 端到端：发送端全真实链路 → 接收端（stub 引擎）', () {
    final fixture = _MediaFixture();
    ReceiverController? controller;
    StubReceiverPlayer stub = StubReceiverPlayer();

    setUp(() async {
      await fixture.start();
      stub = StubReceiverPlayer();
    });

    tearDown(() async {
      await controller?.stop();
      controller = null;
      await fixture.close();
    });

    test(
      'addByIp 直连描述 → DlnaTransport.load → PLAYING → pause/seek/stop →'
      ' STOPPED；GENA 事件同链推送',
      () async {
        final gotSession = Completer<ReceiverSession>();
        controller = ReceiverController(
          playerOverride: stub,
          udnSeed: 'udn-e2e-main',
          friendlyNameSeed: '端到端自测（aquan 接收）',
          preferredPort: e2ePreferredPort,
          enableSsdp: false,
          onIncomingSession: (s) {
            if (!gotSession.isCompleted) gotSession.complete(s);
          },
        );
        await controller!.start();
        final port = controller!.port!;
        expect(port, greaterThanOrEqualTo(e2ePreferredPort));

        // --- 发送端发现：addByIp 显式端口（同机组播不可靠的替代路径）---
        final discovery = SsdpDiscovery();
        final device = await discovery
            .addByIp('127.0.0.1', port: port)
            .timeout(const Duration(seconds: 10));
        expect(device, isNotNull, reason: 'addByIp 应经 /description.xml 命中');
        expect(device!.udn, 'uuid:udn-e2e-main');
        expect(device.friendlyName, '端到端自测（aquan 接收）');
        expect(
          device.controlUrl,
          'http://127.0.0.1:$port/AVTransport/control',
        );
        expect(
          device.eventSubUrl,
          'http://127.0.0.1:$port/AVTransport/event',
        );

        // --- GENA 订阅（真实 GenaSubscriber；先收初始事件再投送）---
        final genaClient = HttpClient()..findProxy = (_) => 'DIRECT';
        final subscriber = GenaSubscriber(
          device.eventSubUrl,
          client: genaClient,
          hostOverride: '127.0.0.1',
        );
        addTearDown(subscriber.stop);
        final events = <String>[];
        final gotInitial = Completer<void>();
        final gotPlaying = Completer<void>();
        final gotPaused = Completer<void>();
        final gotStoppedByEvent = Completer<void>();
        final sub = subscriber.events.listen((poll) {
          events.add(poll.transportState);
          if (!gotInitial.isCompleted) gotInitial.complete();
          if (poll.transportState == 'PLAYING' && !gotPlaying.isCompleted) {
            gotPlaying.complete();
          }
          if (poll.transportState == 'PAUSED_PLAYBACK' &&
              !gotPaused.isCompleted) {
            gotPaused.complete();
          }
          if (poll.transportState == 'STOPPED' &&
              !gotStoppedByEvent.isCompleted) {
            gotStoppedByEvent.complete();
          }
        });
        addTearDown(sub.cancel);
        expect(
          await subscriber.subscribe().timeout(const Duration(seconds: 6)),
          isTrue,
          reason: 'SUBSCRIBE 应成功（真实 GenaSubscriber → 接收端 GENA）',
        );
        // 初始事件（订阅时无 URI → NO_MEDIA_PRESENT）。
        await gotInitial.future.timeout(const Duration(seconds: 6));
        expect(events.first, 'NO_MEDIA_PRESENT');

        // --- 投送：DlnaTransport.load（预检 → SetAVTransportURI → Play 门控）---
        final transport = DlnaTransport(
          device,
          client: SoapClient(client: directHttpClient()),
          playPollInterval: const Duration(milliseconds: 100),
          playGateTimeout: const Duration(seconds: 5),
          retryBudget: const Duration(seconds: 10),
        );
        addTearDown(transport.close);
        final mediaUrl = fixture.url;
        final recipe = await transport
            .load(CastLoadRequest(
              url: mediaUrl,
              didl: DidlRequest(
                uri: mediaUrl,
                title: '端到端自测',
                mimeType: 'video/mp4',
                duration: const Duration(minutes: 10),
                // 封面投送（AC-3，11-07-cast-cover-art）：发送端 DIDL full
                // 变体带 albumArtURI → 接收端提取 → 会话字段端到端一致。
                albumArtUrl: fixture.coverUrl,
              ),
              title: '端到端自测',
            ))
            .timeout(const Duration(seconds: 12));
        expect(recipe, isNotNull, reason: 'full/standard 首档配方即应命中');

        // 引擎收到 load（stub 状态），GetTransportInfo=PLAYING（真实 SOAP）。
        expect(stub.loadCount, 1);
        expect(stub.loadedUri, mediaUrl);
        expect(stub.loadedTitle, '端到端自测');
        expect(stub.playCount, 1);
        expect(
          await transport
              .getTransportState()
              .timeout(const Duration(seconds: 4)),
          'PLAYING',
        );

        // 会话回调：投送方地址 / UA / 标题 / 封面（实体转义往返后还原）。
        final s = await gotSession.future.timeout(const Duration(seconds: 4));
        expect(s.url, mediaUrl.toString());
        expect(s.title, '端到端自测');
        expect(s.senderAddress, '127.0.0.1');
        expect(s.senderUserAgent, isNotEmpty);
        expect(s.albumArtUrl, fixture.coverUrl.toString(),
            reason: '发送端 albumArtURI → 接收端会话封面端到端一致');

        // 状态变化 → NOTIFY LastChange → GenaSubscriber 事件。
        await gotPlaying.future.timeout(const Duration(seconds: 6));

        // --- Pause ---
        await transport.pause();
        expect(stub.pauseCount, 1);
        expect(
          await transport
              .getTransportState()
              .timeout(const Duration(seconds: 4)),
          'PAUSED_PLAYBACK',
        );
        await gotPaused.future.timeout(const Duration(seconds: 6));

        // --- Seek（REL_TIME）→ GetPositionInfo 读引擎实况 ---
        await transport.seekTo(const Duration(minutes: 1, seconds: 30));
        expect(stub.seeks.last, const Duration(minutes: 1, seconds: 30));
        stub.duration = const Duration(minutes: 10);
        final poll = await transport.poll().timeout(const Duration(seconds: 4));
        expect(poll.transportState, 'PAUSED_PLAYBACK');
        expect(poll.position, const Duration(minutes: 1, seconds: 30));
        expect(poll.duration, const Duration(minutes: 10));

        // --- Stop → 最终 STOPPED ---
        await transport.stop();
        expect(stub.stopCount, 1);
        expect(
          await transport
              .getTransportState()
              .timeout(const Duration(seconds: 4)),
          'STOPPED',
        );
        await gotStoppedByEvent.future.timeout(const Duration(seconds: 6));

        // 媒体夹具可达（真实引擎从该 URL 拉流的等价路径）。
        final head = await directHttpClient()
            .head(mediaUrl)
            .timeout(const Duration(seconds: 4));
        expect(head.statusCode, 200);
        expect(fixture.requestCount, greaterThanOrEqualTo(1));
      },
      timeout: testBudget,
    );

    test('直连 description.xml 可被自家 DlnaDevice 解析（互操作回归）', () async {
      controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-e2e-desc',
        preferredPort: e2ePreferredPort,
        enableSsdp: false,
      );
      await controller!.start();
      final client = directHttpClient();
      final res = await client
          .get(Uri.parse('http://127.0.0.1:${controller!.port}/description.xml'))
          .timeout(const Duration(seconds: 4));
      expect(res.statusCode, 200);
      expect(res.body, contains('urn:schemas-upnp-org:device:MediaRenderer:1'));

      final device = parseDeviceDescription(
        res.body,
        'http://127.0.0.1:${controller!.port}/description.xml',
      );
      expect(device, isNotNull);
      expect(device!.udn, 'uuid:udn-e2e-desc');
      expect(
        device.serviceType,
        'urn:schemas-upnp-org:service:AVTransport:1',
      );
      expect(device.connectionManagerUrl,
          'http://127.0.0.1:${controller!.port}/ConnectionManager/control');
    }, timeout: testBudget);
  });

  group('AC-5b 端到端·准入控制（R3.2）：ask 超时 401 / 允许 → PLAYING / 白名单拒绝', () {
    final fixture = _MediaFixture();

    setUp(() async {
      await fixture.start();
    });

    tearDown(() async {
      await fixture.close();
    });

    /// 原始 SOAP POST（不经 SoapClient 的重试/异常包装，锁线缆形状）。
    Future<http.Response> postSetUri(int port, {String metadata = ''}) async {
      final body = '<?xml version="1.0" encoding="utf-8"?>'
          '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
          's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
          '<s:Body><u:SetAVTransportURI '
          'xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
          '<InstanceID>0</InstanceID>'
          '<CurrentURI>${fixture.url}</CurrentURI>'
          '<CurrentURIMetaData>$metadata</CurrentURIMetaData>'
          '</u:SetAVTransportURI></s:Body></s:Envelope>';
      final client = directHttpClient();
      try {
        return await client.post(
          Uri.parse('http://127.0.0.1:$port/AVTransport/control'),
          headers: {
            'SOAPACTION':
                '"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"',
            'Content-Type': 'text/xml; charset="utf-8"',
          },
          body: body,
        );
      } finally {
        client.close();
      }
    }

    test('ask 模式 + 假 handler 超时 → fault 401（线缆形状 + 不开会话）',
        () async {
      var prompts = 0;
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptTimeout: const Duration(milliseconds: 150),
        promptHandler: (_) async {
          prompts++;
          return Completer<AdmissionPromptOutcome>().future; // 永不响应
        },
      );
      final stub = StubReceiverPlayer();
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-e2e-adm-ask',
        preferredPort: e2ePreferredPort + 1,
        enableSsdp: false,
        admission: policy,
      );
      addTearDown(controller.stop);
      await controller.start();

      final res = await postSetUri(controller.port!)
          .timeout(const Duration(seconds: 8));
      expect(res.statusCode, 500, reason: 'fault 走 HTTP 500');
      expect(res.body, contains('<errorCode>401</errorCode>'));
      expect(res.body, contains('Action Not Authorized'));
      expect(prompts, 1, reason: 'ask 模式询问过一次（然后超时拒绝）');
      expect(stub.loadCount, 0, reason: '拒绝不进引擎');
      expect(controller.currentSession, isNull);
    }, timeout: const Timeout(Duration(seconds: 25)));

    test('ask 允许（记住）→ PLAYING；再次投送不再询问', () async {
      var prompts = 0;
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptHandler: (_) async {
          prompts++;
          return const AdmissionPromptOutcome(allow: true, remember: true);
        },
      );
      final stub = StubReceiverPlayer();
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-e2e-adm-allow',
        preferredPort: e2ePreferredPort + 1,
        enableSsdp: false,
        admission: policy,
      );
      addTearDown(controller.stop);
      await controller.start();

      // 首投：询问 → 允许（记住）→ 正常链路（DlnaTransport 全真实）。
      final discovery = SsdpDiscovery();
      addTearDown(discovery.stop);
      final device = await discovery
          .addByIp('127.0.0.1', port: controller.port!)
          .timeout(const Duration(seconds: 10));
      final transport = DlnaTransport(
        device!,
        client: SoapClient(client: directHttpClient()),
        playPollInterval: const Duration(milliseconds: 100),
        playGateTimeout: const Duration(seconds: 5),
        retryBudget: const Duration(seconds: 10),
      );
      addTearDown(transport.close);
      final mediaUrl = fixture.url;
      final recipe = await transport
          .load(CastLoadRequest(
            url: mediaUrl,
            didl: DidlRequest(
              uri: mediaUrl,
              title: '准入放行',
              mimeType: 'video/mp4',
              duration: const Duration(minutes: 10),
            ),
            title: '准入放行',
          ))
          .timeout(const Duration(seconds: 12));
      expect(recipe, isNotNull);
      expect(prompts, 1);
      expect(stub.loadCount, 1);
      expect(
        await transport.getTransportState().timeout(const Duration(seconds: 4)),
        'PLAYING',
      );

      // 二次投送（新投替换）：记住后不再询问。
      await postSetUri(controller.port!);
      expect(stub.loadCount, 2);
      expect(prompts, 1, reason: '已记住的允许不再询问');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('whitelist 名单外 → fault 401；把发送方 IP 加进允许表后放行',
        () async {
      final policy = AdmissionPolicy(mode: ReceiverAdmissionMode.whitelist);
      final stub = StubReceiverPlayer();
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-e2e-adm-wl',
        preferredPort: e2ePreferredPort + 1,
        enableSsdp: false,
        admission: policy,
      );
      addTearDown(controller.stop);
      await controller.start();

      final denied = await postSetUri(controller.port!)
          .timeout(const Duration(seconds: 8));
      expect(denied.statusCode, 500);
      expect(denied.body, contains('<errorCode>401</errorCode>'));
      expect(stub.loadCount, 0);

      // 名单加入发送方（127.0.0.1）→ 放行（白名单模式不询问）。
      policy.allowDevice('127.0.0.1', userAgent: 'e2e');
      final allowed = await postSetUri(controller.port!)
          .timeout(const Duration(seconds: 8));
      expect(allowed.statusCode, 200, reason: '白名单命中直接放行');
      expect(allowed.body, contains('SetAVTransportURIResponse'));
      expect(stub.loadCount, 1);
    }, timeout: const Timeout(Duration(seconds: 25)));
  });

  group('SSDP 尽力而为（同机组播不可靠：收到才断言，收不到不算失败）', () {
    test('M-SEARCH 搜到本机接收端时，USN/描述/ST 形状正确', () async {
      final controller = ReceiverController(
        playerOverride: StubReceiverPlayer(),
        udnSeed: 'udn-e2e-ssdp',
        friendlyNameSeed: '组播自测（aquan 接收）',
        preferredPort: e2ePreferredPort,
        enableSsdp: true, // 真实 SSDP 服务（绑定失败自动降级，不致命）
      );
      addTearDown(controller.stop);
      await controller.start();

      final discovery = SsdpDiscovery();
      addTearDown(discovery.stop);
      DlnaDevice? found;
      final done = Completer<void>();
      final sub = discovery.start().listen((event) {
        if (event is SsdpDeviceFound &&
            event.device.udn == 'uuid:udn-e2e-ssdp') {
          found = event.device;
          if (!done.isCompleted) done.complete();
        }
        if (event is SsdpScanDone && !done.isCompleted) done.complete();
      });
      addTearDown(sub.cancel);
      // 发现窗口 4 轮 ≈ 6s；超时视为「同机组播不可达」→ 尽力而为通过。
      await done.future.timeout(const Duration(seconds: 10), onTimeout: () {});

      if (found == null) {
        // 同机 SSDP 组播在本环境不可靠（SSDPSRV 抢 1900 / 多 TAP 网卡）——
        // Phase A 已记录的环境结论，不作为失败；端到端走 addByIp 路径。
        return;
      }
      expect(found!.friendlyName, '组播自测（aquan 接收）');
      expect(found!.controlUrl, contains('/AVTransport/control'));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });
}
