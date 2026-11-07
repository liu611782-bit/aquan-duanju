import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_controller.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/dlna_transport.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DlnaDevice _device() => DlnaDevice(
      udn: 'uuid:test-sink',
      friendlyName: '测试电视',
      controlUrl: 'http://127.0.0.1:1/ctrl',
      connectionManagerUrl: 'http://127.0.0.1:1/cm',
    );

/// 假 SOAP 客户端：脚本化各 action 的返回值并捕获全部调用。
class _FakeSoapClient extends SoapClient {
  _FakeSoapClient() : super();

  final List<(String action, Map<String, String> args)> calls = [];
  Map<String, String> Function(String action)? responder;

  @override
  Future<Map<String, String>> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args, {
    bool quotedSoapAction = true,
    bool uppercaseSoapAction = true,
    bool mPost = false,
  }) async {
    calls.add((action, args));
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

void main() {
  test('AC-13：Sink 里的 video/mp4 不覆盖我们的 HLS mime', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) =>
          action == 'GetTransportInfo'
              ? {'CurrentTransportState': 'PLAYING'}
              : const <String, String>{};
    final transport = DlnaTransport(
      _device(),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
    );

    final recipe = await transport.load(_request(
      protocolInfo: {
        'http-get:*:video/mp4:*',
        'http-get:*:video/mpeg:*',
      },
      recipes: const [CastRecipe(didl: DidlVariant.full)],
    ));

    expect(recipe, isNotNull);
    final setUri = soap.calls
        .firstWhere((c) => c.$1 == 'SetAVTransportURI')
        .$2;
    final metadata = setUri['CurrentURIMetaData']!;
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
    final transport = DlnaTransport(
      _device(),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
    );

    await transport.load(_request(
      protocolInfo: {'http-get:*:video/mp4:*'},
      recipes: const [
        CastRecipe(didl: DidlVariant.full, protocolMime: 'video/mp4'),
      ],
    ));

    final metadata = soap.calls
        .firstWhere((c) => c.$1 == 'SetAVTransportURI')
        .$2['CurrentURIMetaData']!;
    expect(metadata, contains('application/vnd.apple.mpegurl'));
    expect(metadata, isNot(contains('video/mp4')));
    transport.close();
  });

  test('Sink 大类校验：连 video/* 都没有 → 记 warning 不阻断，仍按原 mime 投',
      () async {
    final soap = _FakeSoapClient()
      ..responder = (action) =>
          action == 'GetTransportInfo'
              ? {'CurrentTransportState': 'PLAYING'}
              : const <String, String>{};
    final transport = DlnaTransport(
      _device(),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
    );

    final recipe = await transport.load(_request(
      protocolInfo: {'http-get:*:audio/mpeg:*'},
      recipes: const [CastRecipe(didl: DidlVariant.full)],
    ));

    expect(recipe, isNotNull, reason: 'Sink 缺大类不拒投（go2tv 原则）');
    final metadata = soap.calls
        .firstWhere((c) => c.$1 == 'SetAVTransportURI')
        .$2['CurrentURIMetaData']!;
    expect(metadata, contains('application/vnd.apple.mpegurl'));
    // 不再降到 minimal：full 变体带 DLNA.ORG_OP 标志段。
    expect(metadata, contains('DLNA.ORG_OP=01'));
    transport.close();
  });

  test('Sink 为空（预检失败）→ 不告警不阻断', () async {
    final soap = _FakeSoapClient()
      ..responder = (action) => const <String, String>{};
    final transport = DlnaTransport(
      _device(),
      client: soap,
      playPollInterval: const Duration(milliseconds: 1),
    );

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
}
