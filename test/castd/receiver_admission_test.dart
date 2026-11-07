/// 准入控制单测（AC-2 / AC-3，11-07-cast-receiver-advanced R3.1）：
/// - AdmissionPolicy 状态机全矩阵（三模式 × 陌生/已允许/已拒绝）；
/// - 询问超时 = 拒绝（promptTimeout 注入）且不记住；
/// - renderer 拒绝路径回 SOAP fault 401（报文形状与既有 fault 表一致）；
/// - 名单 JSON 持久化往返（policy ↔ 字符串 ↔ SettingsStore）。
library;

import 'dart:async';

import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_admission.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_renderer.dart';
import 'package:aquan_duanju/core/castd/receiver_service.dart';
import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('AdmissionPolicy 状态机全矩阵（R1.1 三模式 × 陌生/已允许/已拒绝）', () {
    test('anyone：一律放行，名单不影响，从不弹窗', () async {
      var prompts = 0;
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.anyone,
        promptHandler: (_) async {
          prompts++;
          return const AdmissionPromptOutcome(allow: false);
        },
      );
      policy.allowDevice('192.168.1.9');
      policy.denyDevice('192.168.1.10');
      expect(await policy.decide(senderIp: '192.168.1.20'), isTrue,
          reason: '陌生设备放行');
      expect(await policy.decide(senderIp: '192.168.1.9'), isTrue,
          reason: '允许名单在 anyone 下无所谓');
      expect(await policy.decide(senderIp: '192.168.1.10'), isTrue,
          reason: '拒绝名单在 anyone 下也不拦截');
      expect(prompts, 0, reason: 'anyone 从不询问');
    });

    test('whitelist：只看允许表，名单外直接拒（不询问），拒绝名单无关', () async {
      var prompts = 0;
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.whitelist,
        promptHandler: (_) async {
          prompts++;
          return const AdmissionPromptOutcome(allow: true);
        },
      );
      policy.allowDevice('192.168.1.9');
      policy.denyDevice('192.168.1.10');
      expect(await policy.decide(senderIp: '192.168.1.9'), isTrue);
      expect(await policy.decide(senderIp: '192.168.1.20'), isFalse,
          reason: '名单外直接拒');
      expect(await policy.decide(senderIp: '192.168.1.10'), isFalse,
          reason: '只看允许表 → 拒（拒绝表不影响白名单语义）');
      expect(prompts, 0, reason: '白名单模式不询问');
    });

    test('ask：陌生 → 询问结果决定；记住后不再询问（允许优先于拒绝）', () async {
      final requests = <ReceiverAdmissionRequest>[];
      var outcome = const AdmissionPromptOutcome(allow: true);
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptHandler: (req) async {
          requests.add(req);
          return outcome;
        },
      );

      // 陌生设备：询问允许但不记住 → 下次再问。
      outcome = const AdmissionPromptOutcome(allow: true, remember: false);
      expect(await policy.decide(senderIp: '192.168.1.20'), isTrue);
      expect(await policy.decide(senderIp: '192.168.1.20'), isTrue);
      expect(requests.length, 2, reason: '未记住，每次都问');
      expect(requests.first.ip, '192.168.1.20');

      // 陌生设备：询问允许且记住 → 名单命中，不再问。
      outcome = const AdmissionPromptOutcome(allow: true, remember: true);
      expect(await policy.decide(senderIp: '192.168.1.21'), isTrue);
      final promptsAfterRemember = requests.length;
      expect(await policy.decide(senderIp: '192.168.1.21'), isTrue);
      expect(requests.length, promptsAfterRemember, reason: '记住后不再询问');
      expect(policy.allowEntries.single.ip, '192.168.1.21');
      expect(policy.allowEntries.single.userAgent, isEmpty,
          reason: 'decide 未带 UA 时记空（HTTP 路径会带）');

      // 陌生设备：询问拒绝且记住 → 进拒绝名单，之后直接拒。
      outcome = const AdmissionPromptOutcome(allow: false, remember: true);
      expect(await policy.decide(senderIp: '192.168.1.22'), isFalse);
      expect(await policy.decide(senderIp: '192.168.1.22'), isFalse,
          reason: '记住的拒绝不再询问');
      expect(policy.denyEntries.single.ip, '192.168.1.22');

      // 已允许/已拒绝的设备：不再触发询问。
      outcome = const AdmissionPromptOutcome(allow: false);
      expect(await policy.decide(senderIp: '192.168.1.21'), isTrue);
      expect(await policy.decide(senderIp: '192.168.1.22'), isFalse);
      expect(requests.length, promptsAfterRemember + 1,
          reason: '只有 192.168.1.22 那次询问');
    });

    test('allowDevice/denyDevice 互斥：同 IP 换边会从另一表移除', () {
      final policy = AdmissionPolicy();
      policy.allowDevice('10.0.0.1');
      policy.denyDevice('10.0.0.1');
      expect(policy.allowEntries, isEmpty);
      expect(policy.denyEntries.single.ip, '10.0.0.1');
      policy.allowDevice('10.0.0.1');
      expect(policy.denyEntries, isEmpty);
      expect(policy.allowEntries.single.ip, '10.0.0.1');
    });

    test('名单增删：单删返回是否命中、清空返回条数；条目时间来自注入时钟', () {
      final policy = AdmissionPolicy(clock: () => DateTime(2026, 11, 7, 12));
      policy.allowDevice('10.0.0.1');
      expect(
        policy.allowEntries.single.at,
        DateTime(2026, 11, 7, 12),
      );
      expect(policy.removeAllowed('10.0.0.2'), isFalse);
      expect(policy.removeAllowed('10.0.0.1'), isTrue);
      policy.allowDevice('10.0.0.1');
      policy.allowDevice('10.0.0.2');
      expect(policy.clearAllowed(), 2);
      expect(policy.clearDenied(), 0);
      // 空 IP 忽略。
      policy.allowDevice('  ');
      expect(policy.allowEntries, isEmpty);
    });

    test('ask 模式无 promptHandler → 直接拒（不能静默放行）', () async {
      final policy = AdmissionPolicy(mode: ReceiverAdmissionMode.ask);
      expect(await policy.decide(senderIp: '192.168.1.20'), isFalse);
    });

    test('ask 模式 promptHandler 抛异常 → 按拒绝处理', () async {
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptHandler: (_) async => throw Exception('UI 炸了'),
      );
      expect(await policy.decide(senderIp: '192.168.1.20'), isFalse);
    });

    test('IP 首尾空白归一后命中名单', () async {
      final policy = AdmissionPolicy(mode: ReceiverAdmissionMode.whitelist);
      policy.allowDevice(' 192.168.1.9 ');
      expect(policy.allowEntries.single.ip, '192.168.1.9');
      expect(await policy.decide(senderIp: '192.168.1.9'), isTrue);
    });
  });

  group('询问超时（R1.4：30s 未响应 = 拒绝；promptTimeout 注入）', () {
    test('handler 永不响应 → 超时拒绝且不记住', () async {
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptTimeout: const Duration(milliseconds: 20),
        promptHandler: (_) => Completer<AdmissionPromptOutcome>().future,
      );
      final sw = Stopwatch()..start();
      expect(await policy.decide(senderIp: '192.168.1.20'), isFalse);
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      expect(policy.allowEntries, isEmpty);
      expect(policy.denyEntries, isEmpty, reason: '超时拒绝不记住');
    });

    test('handler 超时后才响应 → 结果不生效（已按拒绝处理）', () async {
      final policy = AdmissionPolicy(
        mode: ReceiverAdmissionMode.ask,
        promptTimeout: const Duration(milliseconds: 20),
        promptHandler: (_) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return const AdmissionPromptOutcome(allow: true, remember: true);
        },
      );
      expect(await policy.decide(senderIp: '192.168.1.20'), isFalse);
      expect(policy.allowEntries, isEmpty, reason: '迟到的允许不写入名单');
    });

    test('默认超时是 30s（R1.4 契约）', () {
      expect(AdmissionPolicy().promptTimeout, const Duration(seconds: 30));
    });
  });

  group('renderer 准入接线：拒绝 → fault 401（报文形状与既有 fault 表一致）', () {
    Future<List<(String, String)>> setUri(
      ReceiverRenderer renderer, {
      String senderAddress = '192.168.1.20',
    }) =>
        renderer.handle(
          service: ReceiverService.avTransport,
          action: const SoapActionRequest('SetAVTransportURI', {
            'InstanceID': '0',
            'CurrentURI': 'http://192.168.1.9:18280/p/tok/e1.mp4',
            'CurrentURIMetaData': '<DIDL-Lite/>',
          }),
          senderAddress: senderAddress,
          senderUserAgent: 'Bidebar/1.0',
        );

    test('anyone（默认）路径行为不变：照常 load + 开会话', () async {
      final stub = StubReceiverPlayer();
      final opened = <ReceiverMediaOpened>[];
      final renderer = ReceiverRenderer(
        player: stub,
        onOpened: opened.add,
        admission: AdmissionPolicy(), // 默认 anyone
      );
      await setUri(renderer);
      expect(stub.loadCount, 1);
      expect(opened, hasLength(1));
    });

    test('无策略（null admission）等价 anyone：旧路径不变', () async {
      final stub = StubReceiverPlayer();
      final renderer = ReceiverRenderer(player: stub);
      await setUri(renderer);
      expect(stub.loadCount, 1);
    });

    test('ask 拒绝 / whitelist 名单外 → fault 401，不 load 不开会话', () async {
      for (final policy in [
        AdmissionPolicy(
          mode: ReceiverAdmissionMode.ask,
          promptHandler: (_) async =>
              const AdmissionPromptOutcome(allow: false),
        ),
        AdmissionPolicy(mode: ReceiverAdmissionMode.whitelist),
      ]) {
        final stub = StubReceiverPlayer();
        final opened = <ReceiverMediaOpened>[];
        final renderer = ReceiverRenderer(
          player: stub,
          onOpened: opened.add,
          admission: policy,
        );
        await expectLater(
          setUri(renderer),
          throwsA(isA<ReceiverFault>()
              .having((f) => f.code, 'code', 401)
              .having(
                  (f) => f.description, 'description', 'Action Not Authorized')),
        );
        expect(stub.loadCount, 0, reason: '拒绝不进引擎');
        expect(opened, isEmpty, reason: '拒绝不开会话');
      }
    });

    test('拒绝后的会话仍是空：Play 拿到 710（无 URI），不是 401', () async {
      final renderer = ReceiverRenderer(
        player: StubReceiverPlayer(),
        admission: AdmissionPolicy(mode: ReceiverAdmissionMode.whitelist),
      );
      await expectLater(
        setUri(renderer),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 401)),
      );
      await expectLater(
        renderer.handle(
          service: ReceiverService.avTransport,
          action: const SoapActionRequest('Play', {'InstanceID': '0'}),
          senderAddress: '192.168.1.20',
        ),
        throwsA(isA<ReceiverFault>().having((f) => f.code, 'code', 710)),
      );
    });

    test('fault 401 报文形状：UPnPError + errorCode，自家 parseSoapFault 可识别',
        () {
      final body =
          soapFaultXml(const ReceiverFault(401, 'Action Not Authorized'));
      expect(body, contains('<errorCode>401</errorCode>'));
      expect(
        body,
        contains(
            '<errorDescription>Action Not Authorized</errorDescription>'),
      );
      expect(body, contains('urn:schemas-upnp-org:control-1-0'));
      final fault = parseSoapFault(body);
      expect(fault, isNotNull);
      expect(fault!.$1, 's:Client');
    });
  });

  group('名单持久化往返（R1.2：SettingsStore JSON 键）', () {
    test('encode → decode 往返；坏串/垃圾值容错', () {
      final entries = [
        ReceiverAdmissionEntry(
          ip: '192.168.1.9',
          userAgent: 'Bidebar/1.0',
          at: DateTime(2026, 11, 7, 10, 30),
        ),
        ReceiverAdmissionEntry(ip: '10.0.0.2', at: DateTime(2026, 1, 1)),
      ];
      final json = encodeAdmissionEntries(entries);
      final decoded = decodeAdmissionEntries(json);
      expect(decoded, hasLength(2));
      expect(decoded[0].ip, '192.168.1.9');
      expect(decoded[0].userAgent, 'Bidebar/1.0');
      expect(decoded[0].at, DateTime(2026, 11, 7, 10, 30));
      expect(decoded[1].ip, '10.0.0.2');
      expect(decoded[1].userAgent, isEmpty);

      // 坏串容错：不抛异常。
      expect(decodeAdmissionEntries(null), isEmpty);
      expect(decodeAdmissionEntries(''), isEmpty);
      expect(decodeAdmissionEntries('   '), isEmpty);
      expect(decodeAdmissionEntries('not json'), isEmpty);
      expect(decodeAdmissionEntries('{"ip":"x"}'), isEmpty,
          reason: '非数组归空');
      expect(decodeAdmissionEntries('[1,2,3]'), isEmpty);
      expect(decodeAdmissionEntries('[{"ua":"no ip"}]'), isEmpty,
          reason: '无 ip 的条目丢弃');
    });

    test('policy load → encode → load（新实例）往返一致；白名单立即生效', () async {
      final source = AdmissionPolicy();
      source.allowDevice('192.168.1.9', userAgent: '投屏助手/2.0');
      source.denyDevice('192.168.1.10', userAgent: 'handset/1');
      final jsonAllow = source.encodeAllowJson();
      final jsonDeny = source.encodeDenyJson();

      final restored = AdmissionPolicy();
      restored.loadAllowJson(jsonAllow);
      restored.loadDenyJson(jsonDeny);
      expect(restored.allowEntries.single.ip, '192.168.1.9');
      expect(restored.allowEntries.single.userAgent, '投屏助手/2.0');
      expect(restored.denyEntries.single.ip, '192.168.1.10');

      restored.mode = ReceiverAdmissionMode.whitelist;
      expect(await restored.decide(senderIp: '192.168.1.9'), isTrue);
      expect(await restored.decide(senderIp: '192.168.1.10'), isFalse);
    });

    test('SettingsStore 键往返 + 非法模式归一 + 备份白名单进出', () async {
      SharedPreferences.setMockInitialValues({});
      final store = SettingsStore(await SharedPreferences.getInstance());

      store.castReceiverAdmissionMode = 'ask';
      store.castReceiverAllowIps = encodeAdmissionEntries(
          [ReceiverAdmissionEntry(ip: '10.0.0.1', at: DateTime(2026, 11, 7))]);
      store.castReceiverDenyIps = encodeAdmissionEntries(
          [ReceiverAdmissionEntry(ip: '10.0.0.2', at: DateTime(2026, 11, 7))]);
      expect(store.castReceiverAdmissionMode, 'ask');

      store.castReceiverAdmissionMode = 'bogus';
      expect(store.castReceiverAdmissionMode, 'anyone', reason: '非法值归一');

      final backup = store.exportBackup();
      expect(backup['cast.receiverAdmissionMode'], 'anyone');
      expect(backup['cast.receiverAllowIps'], contains('10.0.0.1'));
      expect(backup['cast.receiverDenyIps'], contains('10.0.0.2'));

      // 新实例从备份恢复：模式与名单一致。
      SharedPreferences.setMockInitialValues({});
      final fresh = SettingsStore(await SharedPreferences.getInstance());
      final applied = fresh.importBackup(Map<String, dynamic>.from(backup));
      expect(applied, greaterThanOrEqualTo(3));
      expect(fresh.castReceiverAdmissionMode, 'anyone');
      expect(fresh.castReceiverAllowIps, contains('10.0.0.1'));
      expect(fresh.castReceiverDenyIps, contains('10.0.0.2'));

      // 置空串 = 移除键。
      fresh.castReceiverAllowIps = '';
      expect(fresh.castReceiverAllowIps, isEmpty);

      // 备份里的坏名单串照收（运行态 decode 容错归空）。
      SharedPreferences.setMockInitialValues({});
      final corrupt = SettingsStore(await SharedPreferences.getInstance());
      corrupt.importBackup({
        'cast.receiverAllowIps': 'not json',
        'cast.receiverDenyIps': 'not json',
      });
      expect(corrupt.castReceiverAllowIps, 'not json');
      expect(decodeAdmissionEntries(corrupt.castReceiverAllowIps), isEmpty);
    });
  });

  group('CastReceiverService 准入接线', () {
    test('applyAdmissionSettings 应用模式与名单（坏值容错）', () {
      final service = CastReceiverService.forTest(
        controller: ReceiverController(
          playerOverride: StubReceiverPlayer(),
          enableSsdp: false,
        ),
      );
      addTearDown(() => service.setEnabled(false));
      service.applyAdmissionSettings(
        mode: 'whitelist',
        allowJson:
            '[{"ip":"10.1.1.1","ua":"x","at":"2026-11-07T09:00:00.000"}]',
      );
      expect(service.admission.mode, ReceiverAdmissionMode.whitelist);
      expect(service.admission.allowEntries.single.ip, '10.1.1.1');

      service.applyAdmissionSettings(mode: 'nonsense');
      expect(service.admission.mode, ReceiverAdmissionMode.anyone,
          reason: '非法模式回落 anyone');

      service.applyAdmissionSettings(denyJson: 'bad json');
      expect(service.admission.denyEntries, isEmpty);
    });

    test('未注入 admissionPromptHandler → ask 陌生设备兜底拒绝；注入后生效',
        () async {
      final service = CastReceiverService.forTest(
        controller: ReceiverController(
          playerOverride: StubReceiverPlayer(),
          enableSsdp: false,
        ),
      );
      addTearDown(() => service.setEnabled(false));
      service.applyAdmissionSettings(mode: 'ask');
      expect(
        await service.admission.decide(senderIp: '10.9.9.9'),
        isFalse,
        reason: '无 handler 时不能静默放行',
      );

      final requests = <ReceiverAdmissionRequest>[];
      service.admissionPromptHandler = (req) async {
        requests.add(req);
        return const AdmissionPromptOutcome(allow: true, remember: true);
      };
      expect(
        await service.admission.decide(senderIp: '10.9.9.9',
            senderUa: 'test/1.0'),
        isTrue,
      );
      expect(requests.single.ip, '10.9.9.9');
      expect(requests.single.userAgent, 'test/1.0');
      expect(service.admission.allowEntries.single.ip, '10.9.9.9');
    });
  });
}
