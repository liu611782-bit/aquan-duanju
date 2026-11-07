import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/dlna_transport.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DlnaDevice _device({String serviceType = kDefaultAvtServiceType}) => DlnaDevice(
      udn: 'uuid:test-sink',
      friendlyName: '测试电视',
      serviceType: serviceType,
      controlUrl: 'http://127.0.0.1:1/ctrl',
      connectionManagerUrl: 'http://127.0.0.1:1/cm',
    );

/// 假 SOAP 客户端：脚本化各 action 的返回值/异常并捕获全部调用。
class _FakeSoapClient extends SoapClient {
  _FakeSoapClient() : super();

  final List<(String serviceType, String action, Map<String, String> args)>
      calls = <(String, String, Map<String, String>)>[];
  Map<String, String> Function(String action)? responder;
  SoapException? Function(String action)? thrower;

  int get setUriCount =>
      calls.where((c) => c.$2 == 'SetAVTransportURI').length;
  int get stopCount => calls.where((c) => c.$2 == 'Stop').length;
  int get playCount => calls.where((c) => c.$2 == 'Play').length;
  String? get lastSetUriMetadata {
    for (final c in calls.reversed) {
      if (c.$2 == 'SetAVTransportURI') return c.$3['CurrentURIMetaData'];
    }
    return null;
  }

  @override
  Future<Map<String, String>> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args, {
    bool mPost = false,
  }) async {
    calls.add((serviceType, action, args));
    final thrown = thrower?.call(action);
    if (thrown != null) throw thrown;
    return responder?.call(action) ?? const <String, String>{};
  }
}

CastLoadRequest _request({
  String mimeType = 'application/vnd.apple.mpegurl',
  Set<String> protocolInfo = const <String>{},
  List<CastRecipe> recipes = const <CastRecipe>[],
}) =>
    CastLoadRequest(
      url: Uri.parse('http://192.168.1.5:18280/p/tok/index.m3u8'),
      title: '第1集',
      didl: DidlRequest(
        uri: Uri.parse('http://192.168.1.5:18280/p/tok/index.m3u8'),
        title: '第1集',
        mimeType: mimeType,
      ),
      recipes: recipes,
      protocolInfo: protocolInfo,
    );

DlnaTransport _transport(_FakeSoapClient soap,
        {DlnaDevice? device, Duration? playGateTimeout}) =>
    DlnaTransport(
      device ?? _device(),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
      playGateTimeout: playGateTimeout ?? const Duration(milliseconds: 40),
    );

void main() {
  test('AC-13：Sink 里的 video/mp4 不覆盖我们的 HLS mime', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) =>
          action == 'GetTransportInfo'
              ? {'CurrentTransportState': 'PLAYING'}
              : const <String, String>{};
    final transport = _transport(soap);

    final recipe = await transport.load(_request(
      protocolInfo: {
        'http-get:*:video/mp4:*',
        'http-get:*:video/mpeg:*',
      },
      recipes: const [CastRecipe(didl: DidlVariant.full)],
    ));

    expect(recipe, isNotNull);
    final metadata = soap.lastSetUriMetadata!;
    expect(metadata, contains('application/vnd.apple.mpegurl'),
        reason: 'DIDL mime 必须是媒体自身判定的容器');
    expect(metadata, isNot(contains('video/mp4')),
        reason: '设备 Sink 不得覆盖 mime（AC-13）');
    transport.close();
  });

  test('AC-13：旧配方里持久化的 protocolMime 同样不再生效', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) =>
          action == 'GetTransportInfo'
              ? {'CurrentTransportState': 'PLAYING'}
              : const <String, String>{};
    final transport = _transport(soap);

    await transport.load(_request(
      protocolInfo: {'http-get:*:video/mp4:*'},
      recipes: const [
        CastRecipe(didl: DidlVariant.full, protocolMime: 'video/mp4'),
      ],
    ));

    expect(soap.lastSetUriMetadata, contains('application/vnd.apple.mpegurl'));
    expect(soap.lastSetUriMetadata, isNot(contains('video/mp4')));
    transport.close();
  });

  test('Sink 大类校验：连 video/* 都没有 → 记 warning 不阻断，仍按原 mime 投',
      () async {
    final soap = _FakeSoapClient()
      ..responder = (action) =>
          action == 'GetTransportInfo'
              ? {'CurrentTransportState': 'PLAYING'}
              : const <String, String>{};
    final transport = _transport(soap);

    final recipe = await transport.load(_request(
      protocolInfo: {'http-get:*:audio/mpeg:*'},
      recipes: const [CastRecipe(didl: DidlVariant.full)],
    ));

    expect(recipe, isNotNull, reason: 'Sink 缺大类不拒投（go2tv 原则）');
    expect(soap.lastSetUriMetadata, contains('application/vnd.apple.mpegurl'));
    // 不再降到 compact：full 变体带 DLNA.ORG_OP 标志段。
    expect(soap.lastSetUriMetadata, contains('DLNA.ORG_OP=01'));
    transport.close();
  });

  test('Sink 为空（预检失败）→ 不告警不阻断', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) => const <String, String>{};
    final transport = _transport(soap);

    final recipe = await transport.load(_request(
      protocolInfo: const <String>{},
      recipes: const [CastRecipe(didl: DidlVariant.full)],
    ));
    expect(recipe, isNotNull);
    transport.close();
  });

  test('preflight：GetProtocolInfo 的 Sink 解析为条目集合', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) => action == 'GetProtocolInfo'
          ? {
              'Sink':
                  'http-get:*:video/mp4:*, http-get:*:application/vnd.apple.mpegurl:*'
            }
          : const <String, String>{};
    final transport = DlnaTransport(_device(), client: soap);

    final sink = await transport.preflight();
    expect(sink, containsAll(<String>[
      'http-get:*:video/mp4:*',
      'http-get:*:application/vnd.apple.mpegurl:*',
    ]));
    transport.close();
  });

  group('M2-3 真实 serviceType', () {
    test('xmlns:u / SOAPACTION 用设备宣告的 serviceType（多版本解析层取最高）',
        () async {
      final soap = _FakeSoapClient()
        ..responder = (action) =>
            action == 'GetTransportInfo'
                ? {'CurrentTransportState': 'PLAYING'}
                : const <String, String>{};
      final transport = _transport(soap,
          device: _device(
              serviceType: 'urn:schemas-upnp-org:service:AVTransport:2'));

      await transport.load(_request(
        recipes: const [CastRecipe(didl: DidlVariant.full)],
      ));
      expect(soap.setUriCount, 1);
      expect(
        soap.calls
            .firstWhere((c) => c.$2 == 'SetAVTransportURI')
            .$1,
        'urn:schemas-upnp-org:service:AVTransport:2',
        reason: 'xmlns:u / SOAPACTION 用设备宣告的 AVTransport serviceType',
      );
      transport.close();
    });
  });

  group('M2-6 降级链 v2', () {
    test('AC-23 回归：requirePlayConfirmation=false（默认）门控超时仍视为成功',
        () async {
      final soap = _FakeSoapClient()
        // GetTransportInfo 永远不回 PLAYING → 门控超时。
        ..responder = (action) => const <String, String>{};
      final transport = _transport(soap);

      final recipe = await transport.load(_request(
        recipes: const [CastRecipe(didl: DidlVariant.full)],
      ));

      expect(recipe, isNotNull, reason: '默认行为与现状一致：Play 门控超时不算失败');
      expect(soap.playCount, 1);
      transport.close();
    });

    test('requirePlayConfirmation=true：双确认（PLAYING 且 TrackURI 一致）命中',
        () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => switch (action) {
              'GetTransportInfo' => {'CurrentTransportState': 'PLAYING'},
              'GetPositionInfo' => {
                  'TrackURI': 'http://192.168.1.5:18280/p/tok/index.m3u8'
                },
              _ => const <String, String>{},
            };
      final transport = _transport(soap);

      final recipe = await transport.load(_request(
        recipes: const [
          CastRecipe(didl: DidlVariant.full, requirePlayConfirmation: true)
        ],
      ));
      expect(recipe, isNotNull);
      transport.close();
    });

    test('requirePlayConfirmation=true：PLAYING 但放的是旧片（URI 不一致）→ 不算命中',
        () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => switch (action) {
              'GetTransportInfo' => {'CurrentTransportState': 'PLAYING'},
              // 电视上残留的旧播放。
              'GetPositionInfo' => {'TrackURI': 'http://old/tv/content.mp4'},
              'GetMediaInfo' => {'CurrentURI': 'http://old/tv/content.mp4'},
              _ => const <String, String>{},
            };
      final transport = _transport(soap);

      await expectLater(
        transport.load(_request(
          recipes: const [
            CastRecipe(didl: DidlVariant.full, requirePlayConfirmation: true)
          ],
        )),
        throwsA(isA<SoapException>()),
      );
      transport.close();
    });

    test('requirePlayConfirmation=true：门控超时后 GetMediaInfo 归属校验是我们'
        '的流 → 归属成立视为成功（castor session.go 二次仲裁）', () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => switch (action) {
              // 状态一直 TRANSITIONING（设备起播慢）。
              'GetTransportInfo' => {'CurrentTransportState': 'TRANSITIONING'},
              'GetMediaInfo' => {
                  'CurrentURI': 'http://192.168.1.5:18280/p/tok/index.m3u8'
                },
              _ => const <String, String>{},
            };
      final transport = _transport(soap);

      final recipe = await transport.load(_request(
        recipes: const [
          CastRecipe(didl: DidlVariant.full, requirePlayConfirmation: true)
        ],
      ));
      expect(recipe, isNotNull);
      transport.close();
    });

    test('requirePlayConfirmation=true：门控超时且归属不一致 → 进下一变体',
        () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => switch (action) {
              'GetTransportInfo' => {'CurrentTransportState': 'STOPPED'},
              'GetMediaInfo' => {'CurrentURI': 'http://old/tv/content.mp4'},
              _ => const <String, String>{},
            };
      final transport = _transport(soap);

      await expectLater(
        transport.load(_request(
          recipes: const [
            CastRecipe(
                didl: DidlVariant.full, requirePlayConfirmation: true),
            CastRecipe(
                didl: DidlVariant.compact, requirePlayConfirmation: true),
          ],
        )),
        throwsA(isA<SoapException>()),
      );
      expect(soap.setUriCount, 2, reason: '确认失败后应尝试下一个变体');
      transport.close();
    });

    test('701/705：Stop → 延迟 → 重设 URI → 延迟 → 重 Play（一次）', () async {
      var setUriFailures = 0;
      final soap = _FakeSoapClient()
        ..thrower = (action) {
          if (action != 'SetAVTransportURI') return null;
          if (setUriFailures++ == 0) {
            return const SoapException('705 状态冲突',
                faultCode: 's:Client', faultDescription: 'errorCode 705');
          }
          return null;
        }
        ..responder = (action) =>
            action == 'GetTransportInfo'
                ? {'CurrentTransportState': 'PLAYING'}
                : const <String, String>{};
      final transport = _transport(soap);

      final recipe = await transport.load(_request(
        recipes: const [CastRecipe(didl: DidlVariant.full)],
      ));

      expect(recipe, isNotNull);
      expect(soap.setUriCount, 2, reason: '705 后重设 URI 一次');
      expect(soap.stopCount, 1, reason: '状态冲突先 Stop');
      expect(soap.playCount, 1, reason: '重设后重 Play');
      transport.close();
    });

    test('sinkEntry 模板：Sink 含同容器条目 → 第 4 段逐字复用', () async {
      final soap = _FakeSoapClient()
        ..responder = (action) =>
            action == 'GetTransportInfo'
                ? {'CurrentTransportState': 'PLAYING'}
                : const <String, String>{};
      final transport = _transport(soap);

      await transport.load(_request(
        mimeType: 'video/mp4',
        protocolInfo: {
          'http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_BL_CIF15_AAC;DLNA.ORG_OP=10',
          'http-get:*:audio/mpeg:*',
        },
        recipes: const [
          CastRecipe(
              didl: DidlVariant.full,
              protocolInfoTemplate: DidlProtocolInfoTemplate.sinkEntry)
        ],
      ));

      expect(
        soap.lastSetUriMetadata,
        contains('protocolInfo="http-get:*:video/mp4:'
            'DLNA.ORG_PN=AVC_MP4_BL_CIF15_AAC;DLNA.ORG_OP=10"'),
        reason: '照抄设备自己的 PN/OP 拼写（castor didl.go）',
      );
      transport.close();
    });

    test('sinkEntry 模板：Sink 无同容器条目 → 回落 standard', () async {
      final soap = _FakeSoapClient()
        ..responder = (action) =>
            action == 'GetTransportInfo'
                ? {'CurrentTransportState': 'PLAYING'}
                : const <String, String>{};
      final transport = _transport(soap);

      await transport.load(_request(
        mimeType: 'application/vnd.apple.mpegurl',
        protocolInfo: {'http-get:*:video/mp4:*'},
        recipes: const [
          CastRecipe(
              didl: DidlVariant.full,
              protocolInfoTemplate: DidlProtocolInfoTemplate.sinkEntry)
        ],
      ));

      expect(soap.lastSetUriMetadata, contains('DLNA.ORG_OP=01;DLNA.ORG_CI=0'));
      expect(soap.lastSetUriMetadata, contains('application/vnd.apple.mpegurl'));
      transport.close();
    });

    test('withPn 变体仅当 Sink 条目全部带 DLNA.ORG_PN 才尝试（省必败往返）',
        () async {
      // Sink 不按 PN 匹配：确定性 fault 让每个变体都失败，用 setUri 计数
      // 反映有效变体数。
      SoapException? fault714(String action) =>
          const SoapException('714 不支持的容器',
              faultCode: 's:Client', faultDescription: 'errorCode 714');
      final noPnSink = _FakeSoapClient()..thrower = fault714;
      final transportNoPn = _transport(noPnSink);
      await expectLater(
        transportNoPn.load(_request(
          protocolInfo: {'http-get:*:video/mp4:*', 'http-get:*:video/mpeg:*'},
        )),
        throwsA(isA<SoapException>()),
      );
      expect(noPnSink.setUriCount, 6, reason: '梯度 7 项去掉 withPn');
      transportNoPn.close();

      final pnSink = {'http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_HD_AAC'};
      final withPn = _FakeSoapClient()..thrower = fault714;
      final transportPn = _transport(withPn);
      await expectLater(
        transportPn.load(_request(protocolInfo: pnSink)),
        throwsA(isA<SoapException>()),
      );
      expect(withPn.setUriCount, 7, reason: 'Sink 全带 PN → withPn 保留');
      transportPn.close();
    });

    test('配方链逐变体使用各自的模板与字幕模式（compact 不写 duration）', () async {
      final soap = _FakeSoapClient()
        ..responder = (action) => const <String, String>{};
      final transport = _transport(soap);

      await transport.load(_request(
        recipes: const [
          CastRecipe(didl: DidlVariant.compact, subtitleMode: CastSubtitleMode.none)
        ],
      ));
      final metadata = soap.lastSetUriMetadata!;
      expect(metadata, contains('<dc:title>第1集</dc:title>'));
      expect(metadata, contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(metadata, isNot(contains('sec:')));
      expect(metadata, isNot(contains('duration=')));
      transport.close();
    });
  });

  test('最坏耗时公式常量断言（playbridge dlna_tests.rs:399 先例）', () {
    // 梯度全集 7 个变体（withPn 之外的 6 个无条件尝试）。
    expect(CastRecipeStore.gradient.length, 7);
    expect(CastRecipeStore.gradient.first.didl, DidlVariant.full,
        reason: '首项必须是现状默认形态 full+standard，保证不回归');
    expect(CastRecipeStore.gradient.first.protocolInfoTemplate,
        DidlProtocolInfoTemplate.standard);

    final soapCap = SoapClient().timeout; // 单次 SOAP 上限 4s（AC-26 后 fault 恰 1 次请求）
    const maxDelay =
        Duration(milliseconds: DlnaTransport.maxPlayDelayMs); // 500ms
    final transport = DlnaTransport(_device());
    final budget = transport.retryBudget; // 12s
    final gate = transport.playGateTimeout; // 10s

    // 预算必须覆盖：2 个满配变体（SOAP 上限 + 最大播放延迟）+ 门控下限窗口
    // （门控受预算钳制，不独立突破 12s）。
    expect(
      budget >= soapCap * 2 + maxDelay * 2 + const Duration(seconds: 2),
      isTrue,
      reason: '加变体或调大延迟/超时前，先重估最坏耗时公式',
    );
    // 门控上限本身也受预算钳制（_earlier），不得大于预算。
    expect(gate <= budget, isTrue);
    transport.close();
  });
}
