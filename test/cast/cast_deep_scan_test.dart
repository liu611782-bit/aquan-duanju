import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/dlna_transport.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/store/stores.dart';

DlnaDevice _device(String udn) => DlnaDevice(
      udn: udn,
      friendlyName: '测试电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
      connectionManagerUrl: 'http://127.0.0.1:1/cm',
    );

/// 假 SOAP 客户端：脚本化各 action 的返回值/异常并捕获全部调用。
class _FakeSoapClient extends SoapClient {
  _FakeSoapClient() : super();

  final List<(String serviceType, String action, Map<String, String> args)>
      calls = <(String, String, Map<String, String>)>[];
  Map<String, String> Function(String action)? responder;

  /// 前 [setUriSuccesses] 次 SetAVTransportURI 成功，其后确定性 fault 401；
  /// null = 全部按 [responder]/成功处理。
  int? setUriSuccesses;
  bool delayEachCall = false;

  int get setUriCount =>
      calls.where((c) => c.$2 == 'SetAVTransportURI').length;
  int get playCount => calls.where((c) => c.$2 == 'Play').length;
  int get getTransportInfoCount =>
      calls.where((c) => c.$2 == 'GetTransportInfo').length;

  @override
  Future<Map<String, String>> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args, {
    bool mPost = false,
  }) async {
    calls.add((serviceType, action, args));
    if (delayEachCall) {
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    if (action == 'SetAVTransportURI' && setUriSuccesses != null) {
      if (setUriCount > setUriSuccesses!) {
        throw const SoapException('401 无效动作',
            faultCode: 's:Client', faultDescription: 'errorCode 401');
      }
    }
    return responder?.call(action) ?? const <String, String>{};
  }
}

CastLoadRequest _request({
  String mimeType = 'video/mp4',
  Set<String> protocolInfo = const <String>{},
}) =>
    CastLoadRequest(
      url: Uri.parse('http://192.168.1.5:18280/m/tok/video.mp4'),
      title: '第1集',
      didl: DidlRequest(
        uri: Uri.parse('http://192.168.1.5:18280/m/tok/video.mp4'),
        title: '第1集',
        mimeType: mimeType,
      ),
      protocolInfo: protocolInfo,
    );

DlnaTransport _transport(_FakeSoapClient soap, {DlnaDevice? device}) =>
    DlnaTransport(
      device ?? _device('uuid:scan-sink'),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
      playGateTimeout: const Duration(milliseconds: 40),
    );

CastMedia _media() =>
    const CastMedia(url: 'http://192.168.1.10/1.mp4', title: '测试 · 第1集');

CastTarget _target(String udn) => CastTarget.dlna(_device(udn));

void main() {
  group('AC-1 全组合枚举（diagnosticScanChain）', () {
    test('基础 7 项：full/compact × standard/bare/wildcard + compatEscaped',
        () {
      final chain = diagnosticScanChain();
      expect(chain.length, 7);
      // 首项必须是现状默认形态（与生产梯度同一不回归约束）。
      expect(chain.first.didl, DidlVariant.full);
      expect(
          chain.first.protocolInfoTemplate, DidlProtocolInfoTemplate.standard);
      // 条件项默认不出现。
      expect(
          chain.where((r) =>
              r.protocolInfoTemplate == DidlProtocolInfoTemplate.withPn),
          isEmpty);
      expect(
          chain.where((r) =>
              r.protocolInfoTemplate == DidlProtocolInfoTemplate.sinkEntry),
          isEmpty);
      expect(
          chain.where(
              (r) => r.protocolInfoTemplate == DidlProtocolInfoTemplate.op11),
          isEmpty,
          reason: 'op11 恒不入（无 Range 场景，谎报 byte-seek 有害）');
      // compatEscaped 变体在列（只配 standard 模板）。
      expect(
        chain
            .where((r) => r.didl == DidlVariant.compatEscaped)
            .map((r) => r.protocolInfoTemplate),
        [DidlProtocolInfoTemplate.standard],
      );
    });

    test('条件全开恰 10 组合且无重复', () {
      final chain = diagnosticScanChain(pnRequired: true, hasSinkEntry: true);
      expect(chain.length, 10);
      expect(
        chain
            .where((r) =>
                r.protocolInfoTemplate == DidlProtocolInfoTemplate.withPn)
            .length,
        2,
        reason: 'withPn ×2（full/compact）仅 PN Sink 时加入',
      );
      expect(
        chain
            .where((r) =>
                r.protocolInfoTemplate == DidlProtocolInfoTemplate.sinkEntry)
            .length,
        1,
        reason: 'sinkEntry 仅 Sink 有同容器条目时加入',
      );
      // CastRecipe 有值相等：无重复组合。
      expect(chain.toSet().length, chain.length);
    });
  });

  group('AC-2 扫描语义（不早停 / 不门控 / 汇总结构）', () {
    test('不早停：全部组合受理也试完（计数 = 组合数）', () async {
      final soap = _FakeSoapClient();
      final transport = _transport(soap);

      final result = await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      // Sink 有 video/mp4 条目（第 4 段 '*'）→ sinkEntry 条件成立 → 8 组合。
      expect(result.attempts.length, 8);
      expect(soap.setUriCount, 8, reason: '每个组合恰一次 SetAVTransportURI');
      expect(result.anyAccepted, isTrue);
      expect(result.accepted.length, 8);
      transport.close();
    });

    test('不早停：确定性 fault 全败同样试完；不发送 Play', () async {
      final soap = _FakeSoapClient()
        ..setUriSuccesses = 0
        ..responder = (action) => const <String, String>{};
      final transport = _transport(soap);

      final result = await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      expect(result.attempts.length, 8);
      expect(soap.setUriCount, 8, reason: '不早停：即使全败也逐组合试完');
      expect(result.anyAccepted, isFalse);
      expect(soap.playCount, 0, reason: '无受理组合时不发 Play');
      transport.close();
    });

    test('混合结果：首个组合受理后继续试完（汇总记录全部结果）', () async {
      final soap = _FakeSoapClient()..setUriSuccesses = 1;
      final transport = _transport(soap);

      final result = await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      expect(result.attempts.length, 8);
      expect(result.accepted.length, 1);
      expect(result.accepted.first.recipe.didl, DidlVariant.full);
      expect(result.accepted.first.recipe.protocolInfoTemplate,
          DidlProtocolInfoTemplate.standard);
      expect(result.attempts.last.accepted, isFalse,
          reason: '受理后仍继续尝试后续组合（不早停）');
      transport.close();
    });

    test('Play 门控跳过：扫描全程无 GetTransportInfo 轮询；收尾恰一次 Play',
        () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => const <String, String>{};
      final transport = _transport(soap);

      await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      expect(soap.getTransportInfoCount, 0,
          reason: '诊断模式只验受理，不做 Play 门控轮询');
      expect(soap.playCount, 1, reason: '试完后按最后受理组合发一次 Play');
      transport.close();
    });

    test('时间线逐项「[诊断] <didl>+<模板> → 结果 (耗时)」', () async {
      final soap = _FakeSoapClient()..setUriSuccesses = 1;
      final transport = _transport(soap);

      await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      final timeline = CastDiagnostics.instance.timeline;
      expect(
        timeline.any((l) =>
            RegExp(r'\[诊断\] full\+standard → 受理 \(\d+\.\d+s\)').hasMatch(l)),
        isTrue,
      );
      expect(
        timeline.any((l) =>
            RegExp(r'\[诊断\] compact\+standard → fault 401 \(\d+\.\d+s\)')
                .hasMatch(l)),
        isTrue,
      );
      transport.close();
    });

    test('汇总结构：summaryLines = 计数行 + 逐组合行', () async {
      final soap = _FakeSoapClient()..setUriSuccesses = 1;
      final transport = _transport(soap);

      final result = await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
      );

      final lines = result.summaryLines();
      expect(lines.length, 1 + result.attempts.length);
      expect(lines.first, contains('共尝试 8 个组合'));
      expect(lines.first, contains('受理 1 个'));
      expect(lines.first, contains('仅验证受理，不验证播放'));
      expect(lines.first, contains('不写入配方记忆'));
      expect(lines[1], startsWith('  full+standard → 受理'));
      transport.close();
    });

    test('withPn 条件：PN Sink 时全组合含 withPn（10 组合）', () async {
      final soap = _FakeSoapClient()..setUriSuccesses = 0;
      final transport = _transport(soap);

      final result = await transport.scanAll(_request(protocolInfo: {
        'http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_HD_AAC',
      }));

      expect(result.attempts.length, 10,
          reason: 'PN Sink：基础 7 + withPn ×2 + sinkEntry');
      expect(
        result.attempts
            .where((a) =>
                a.recipe.protocolInfoTemplate == DidlProtocolInfoTemplate.withPn)
            .length,
        2,
      );
      transport.close();
    });

    test('预算耗尽：deadline 截断链条并记时间线（有界不悬挂）', () async {
      final soap = _FakeSoapClient()..delayEachCall = true;
      final transport = _transport(soap);

      final result = await transport.scanAll(
        _request(protocolInfo: {'http-get:*:video/mp4:*'}),
        scanBudget: const Duration(milliseconds: 5),
      );

      expect(result.attempts.length, lessThan(8));
      expect(result.budgetExhausted, isTrue);
      expect(result.summaryLines().first, contains('预算耗尽'));
      expect(
        CastDiagnostics.instance.timeline
            .any((l) => l.contains('[诊断] 预算耗尽')),
        isTrue,
      );
      transport.close();
    });
  });

  group('AC-1 预算常量断言（playbridge 公式先例）', () {
    test('扫描预算 45s ≥ 全组合数 × 单次 SOAP 上限；生产 12s 预算不受影响', () {
      expect(DlnaTransport.defaultScanBudget, const Duration(seconds: 45));
      final maxCombos =
          diagnosticScanChain(pnRequired: true, hasSinkEntry: true).length;
      expect(maxCombos, 10);
      expect(
        DlnaTransport.defaultScanBudget >= SoapClient().timeout * maxCombos,
        isTrue,
        reason: '新增组合或调大 SOAP 上限前，先重估扫描预算公式',
      );
      // 开关关 = 现状：生产降级链预算仍为 12s，扫描预算不回流。
      final transport = _transport(_FakeSoapClient());
      expect(transport.retryBudget, const Duration(seconds: 12));
      transport.close();
    });
  });

  group('AC-2/AC-3 控制器接线（一次性开关 / 不写配方 / 汇总入报告）', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('开关触发扫描：全败时投屏失败、一次性消费、既有配方不清、报告含汇总段',
        () async {
      final dir = await tempDir('cast_deep_scan_fail');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      // 预置既有配方记忆（经三态写入落 udn 键）：扫描失败不得清掉它。
      await store.recipes
          .setTranscodeMode(_target('d1'), CastTranscodeMode.never);

      final soap = _FakeSoapClient()..setUriSuccesses = 0;
      final transport = DlnaTransport(
        _device('d1'),
        client: soap,
        playPollInterval: const Duration(milliseconds: 1),
        playGateTimeout: const Duration(milliseconds: 40),
      );
      final controller = CastController(
        transportFactory: (_) => transport,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      controller.armDeepDiagnosticScan();
      expect(controller.deepDiagnosticScanArmed, isTrue);

      await expectLater(
        controller.castTo(_target('d1'), _media()),
        throwsA(isA<SoapException>()),
      );
      expect(controller.state, CastSessionState.idle);
      expect(controller.deepDiagnosticScanArmed, isFalse,
          reason: '一次性开关：无论成败即消费');

      // 不写配方（双向）：既有记忆未被清，也未新增成功记忆。
      final remembered = store.recipes.lookup(_target('d1'));
      expect(remembered, isNotNull, reason: '扫描失败不清既有配方（R1.3）');
      expect(remembered!.transcodeMode, CastTranscodeMode.never);

      // 落盘文件同样不含成功配方痕迹。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      final recipes = json['recipes'] as Map<String, dynamic>;
      expect(
        CastRecipe.fromJson(recipes['udn:d1'] as Map<String, dynamic>)
            .successCount,
        0,
      );

      // 报告汇总段（AC-3）：逐组合结果表 + 仅验证受理声明。
      final report = CastDiagnostics.instance.toRedactedReport();
      expect(report.contains('深度诊断扫描汇总'), isTrue);
      expect(report.contains('仅验证受理，不验证播放'), isTrue);
      expect(report.contains('full+standard → fault 401'), isTrue);
      controller.dispose();
    });

    test('开关触发扫描：有受理组合时投屏成功、不写配方、状态进 casting', () async {
      final dir = await tempDir('cast_deep_scan_ok');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      final soap = _FakeSoapClient()
        ..setUriSuccesses = 2
        ..responder = (action) => const <String, String>{};
      final transport = DlnaTransport(
        _device('d2'),
        client: soap,
        playPollInterval: const Duration(milliseconds: 1),
        playGateTimeout: const Duration(milliseconds: 40),
      );
      final controller = CastController(
        transportFactory: (_) => transport,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      controller.armDeepDiagnosticScan();

      await controller.castTo(_target('d2'), _media());

      expect(controller.state, CastSessionState.casting);
      expect(controller.deepDiagnosticScanArmed, isFalse);
      // 「碰巧受理的组合」不固化（R1.3 硬约束）：内存表与落盘都无该设备配方。
      expect(store.recipes.lookup(_target('d2')), isNull);
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect((json['recipes'] as Map).keys, isNot(contains('udn:d2')));

      // 报告汇总段列出全部受理组合。
      final report = CastDiagnostics.instance.toRedactedReport();
      expect(report.contains('深度诊断扫描汇总'), isTrue);
      expect(report.contains('受理 2 个'), isTrue);

      await controller.disconnect();
      controller.dispose();
    });

    test('开关关 = 现状：不触发扫描，compat.load 照常走并正常记忆配方', () async {
      final dir = await tempDir('cast_deep_scan_off');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();

      final soap = _FakeSoapClient()
        ..responder = (action) =>
            action == 'GetTransportInfo'
                ? {'CurrentTransportState': 'PLAYING'}
                : const <String, String>{};
      final transport = DlnaTransport(
        _device('d3'),
        client: soap,
        playPollInterval: const Duration(milliseconds: 1),
        playGateTimeout: const Duration(milliseconds: 40),
      );
      final controller = CastController(
        transportFactory: (_) => transport,
        recipeStore: store.recipes,
        profileStore: store.profiles,
      );
      expect(controller.deepDiagnosticScanArmed, isFalse);

      await controller.castTo(_target('d3'), _media());

      expect(controller.state, CastSessionState.casting);
      // 首组合 full+standard 命中即返回（生产梯度语义），并正常记忆。
      expect(soap.setUriCount, 1);
      expect(soap.getTransportInfoCount, greaterThan(0),
          reason: '现状路径有 Play 门控轮询');
      expect(store.recipes.lookup(_target('d3')), isNotNull);
      await controller.disconnect();
      controller.dispose();
    });
  });
}
