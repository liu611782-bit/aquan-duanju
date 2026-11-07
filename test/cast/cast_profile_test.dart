import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_profile.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

DlnaDevice device({
  String udn = 'uuid:profile-1',
  String renderingControlUrl = '',
  String eventSubUrl = '',
  String serviceType = 'urn:schemas-upnp-org:service:AVTransport:1',
}) =>
    DlnaDevice(
      udn: udn,
      friendlyName: '测试电视',
      modelName: 'LCD-XXDEM6A-B',
      manufacturer: 'DLNA.LCD',
      serviceType: serviceType,
      controlUrl: 'http://192.168.1.9/AVTransport/control',
      renderingControlUrl: renderingControlUrl,
      eventSubUrl: eventSubUrl,
      location: 'http://192.168.1.9/description.xml',
    );

/// 一次「带 dc:title 但被拒」的 SetAVTransportURI（不含 .m3u8）。
SoapTrace failedSetWithTitle({bool hlsUrl = false}) => SoapTrace(
      action: 'SetAVTransportURI',
      requestBody: '<DIDL-Lite><item id="aquan-1">'
          '<dc:title>剧名 · 第1集</dc:title>'
          '<res protocolInfo="http-get:*:video/mp4:*">'
          'http://192.168.1.5:18280/p/AbC/${hlsUrl ? 'index.m3u8' : 'video.mp4'}'
          '</res></item></DIDL-Lite>',
      httpStatus: 500,
      faultCode: 'UPnPError',
    );

/// 一次「缺 dc:title 被拒」的 SetAVTransportURI（空 metadata 重试路径）。
SoapTrace failedSetWithoutTitle() => SoapTrace(
      action: 'SetAVTransportURI',
      requestBody: '<DIDL-Lite><item id="aquan-1"></item></DIDL-Lite>',
      httpStatus: 402,
      faultCode: 'UPnPError',
      faultDescription: 'Invalid Metadata',
    );

void main() {
  group('buildProfile · capabilities 判定', () {
    test('getProtocolInfo：预检成功且 Sink 非空才记', () {
      // 预检成功但 Sink 为空 → 不记。
      expect(
        buildProfile(device(), sink: const [], preflightOk: true)
            .hasCapability(kCapGetProtocolInfo),
        isFalse,
      );
      // Sink 非空但预检失败 → 不记。
      expect(
        buildProfile(device(), sink: const ['http-get:*:video/mp4:*'])
            .hasCapability(kCapGetProtocolInfo),
        isFalse,
      );
      // 预检成功且 Sink 非空 → 记。
      expect(
        buildProfile(device(), sink: const ['http-get:*:video/mp4:*'],
                preflightOk: true)
            .hasCapability(kCapGetProtocolInfo),
        isTrue,
      );
    });

    test('renderingControl / eventSub 来自设备描述', () {
      final plain = buildProfile(device());
      expect(plain.hasCapability(kCapRenderingControl), isFalse);
      expect(plain.hasCapability(kCapEventSub), isFalse);

      final full = buildProfile(device(
        renderingControlUrl: 'http://192.168.1.9/RCS/control',
        eventSubUrl: 'http://192.168.1.9/AVT/event',
      ));
      expect(full.hasCapability(kCapRenderingControl), isTrue);
      expect(full.hasCapability(kCapEventSub), isTrue);
    });

    test('rangeSupport / fetchedStream 由电视取流记录推导', () {
      final requests = <MediaRequestTrace>[
        MediaRequestTrace(
          url: 'http://192.168.1.5:18280/p/AbC/video.mp4',
          method: 'GET',
          range: 'bytes=0-',
          statusCode: 206,
          bytesServed: 1024,
          source: 'proxy',
        ),
        MediaRequestTrace(
          url: 'http://192.168.1.5:18280/p/AbC/video.mp4',
          method: 'GET',
          statusCode: 200,
          bytesServed: 4096,
          source: 'proxy',
        ),
      ];
      final p = buildProfile(device(), mediaRequests: requests);
      expect(p.hasCapability(kCapRangeSupport), isTrue);
      expect(p.hasCapability(kCapFetchedStream), isTrue);

      // 全部失败 → 取过流但没取成：不记 fetchedStream。
      final failed = buildProfile(
        device(),
        mediaRequests: <MediaRequestTrace>[
          MediaRequestTrace(
            url: 'http://192.168.1.5:18280/p/AbC/video.mp4',
            method: 'GET',
            statusCode: 500,
            source: 'proxy',
          ),
        ],
      );
      expect(failed.hasCapability(kCapFetchedStream), isFalse);
      // 从未取流 → 不记 rangeSupport。
      expect(buildProfile(device()).hasCapability(kCapRangeSupport), isFalse);
    });

    test('strictTitle：历史因缺 dc:title 被拒（失败请求体里没有 title）', () {
      // 失败但请求体带 title → 不记。
      expect(
        buildProfile(device(), soapTraces: [failedSetWithTitle()])
            .hasCapability(kCapStrictTitle),
        isFalse,
      );
      // 失败且请求体缺 title → 记。
      expect(
        buildProfile(device(), soapTraces: [failedSetWithoutTitle()])
            .hasCapability(kCapStrictTitle),
        isTrue,
      );
      // 成功的请求即使缺 title 也不记（成功不算被拒）。
      expect(
        buildProfile(
          device(),
          soapTraces: [
            SoapTrace(
              action: 'SetAVTransportURI',
              requestBody: '<DIDL-Lite></DIDL-Lite>',
              httpStatus: 200,
            ),
          ],
        ).hasCapability(kCapStrictTitle),
        isFalse,
      );
    });
  });

  group('buildProfile · profileId 四态（行为驱动）', () {
    test('generic：默认', () {
      expect(buildProfile(device()).profileId, kProfileGeneric);
    });

    test('strictTitle：因缺 title 被拒 → 优先级最高', () {
      final p = buildProfile(
        device(),
        sink: const ['http-get:*:video/mp4:DLNA.ORG_PN=MP4_AVC'],
        soapTraces: [failedSetWithoutTitle()],
      );
      expect(p.profileId, kProfileStrictTitle);
      expect(p.hasCapability(kCapStrictTitle), isTrue);
    });

    test('hlsByUrl：Sink 宣告 HLS 且曾拒播 .m3u8 URL', () {
      // Sink 有 HLS 但没拒过 .m3u8 → 不判。
      expect(
        buildProfile(
          device(),
          sink: const ['http-get:*:application/vnd.apple.mpegurl:*'],
          soapTraces: [failedSetWithTitle()],
        ).profileId,
        kProfileGeneric,
      );
      // Sink 有 HLS 且拒过 .m3u8 URL → 判 hlsByUrl。
      expect(
        buildProfile(
          device(),
          sink: const ['http-get:*:application/vnd.apple.mpegurl:*'],
          soapTraces: [failedSetWithTitle(hlsUrl: true)],
        ).profileId,
        kProfileHlsByUrl,
      );
    });

    test('pnRequired：Sink 条目全部带 DLNA.ORG_PN', () {
      expect(
        buildProfile(
          device(),
          sink: const <String>[
            'http-get:*:video/mp4:DLNA.ORG_PN=MP4_AVC;DLNA.ORG_OP=01',
            'http-get:*:video/mpeg:DLNA.ORG_PN=MPEG_TS_HD_NA',
          ],
        ).profileId,
        kProfilePnRequired,
      );
      // 有条目不带 PN → 不判。
      expect(
        buildProfile(
          device(),
          sink: const <String>[
            'http-get:*:video/mp4:DLNA.ORG_PN=MP4_AVC',
            'http-get:*:video/mp4:*',
          ],
        ).profileId,
        kProfileGeneric,
      );
      // 空 Sink → 不判。
      expect(buildProfile(device()).profileId, kProfileGeneric);
    });
  });

  test('serviceType 版本解析与 modelKey', () {
    expect(
      buildProfile(device(serviceType:
          'urn:schemas-upnp-org:service:AVTransport:2')).avTransportVersion,
      2,
    );
    expect(buildProfile(device()).avTransportVersion, 1);
    expect(
      buildProfile(device(serviceType: 'weird-nonstandard'))
          .avTransportVersion,
      1,
      reason: '非标形状回落 1',
    );
    expect(buildProfile(device()).modelKey, 'LCD-XXDEM6A-B|DLNA.LCD');
  });

  group('CastDeviceProfile JSON', () {
    test('往返不丢字段', () {
      const p = CastDeviceProfile(
        udn: 'uuid:profile-1',
        friendlyName: '测试电视',
        manufacturer: 'DLNA.LCD',
        modelName: 'LCD-XXDEM6A-B',
        serviceType: 'urn:schemas-upnp-org:service:AVTransport:2',
        avTransportVersion: 2,
        sinkProtocols: ['http-get:*:video/mp4:*'],
        capabilities: {kCapEventSub, kCapGetProtocolInfo},
        profileId: kProfileHlsByUrl,
      );
      final back = CastDeviceProfile.fromJson(p.toJson());
      expect(back.udn, p.udn);
      expect(back.friendlyName, p.friendlyName);
      expect(back.modelName, p.modelName);
      expect(back.serviceType, p.serviceType);
      expect(back.avTransportVersion, 2);
      expect(back.sinkProtocols, p.sinkProtocols);
      expect(back.capabilities, p.capabilities);
      expect(back.profileId, p.profileId);
      expect(back.modelKey, p.modelKey);
    });

    test('未知 profileId / 缺字段回落默认', () {
      final p = CastDeviceProfile.fromJson(<String, dynamic>{
        'udn': 'uuid:profile-1',
        'profileId': 'vendorFooBar',
      });
      expect(p.profileId, kProfileGeneric);
      expect(p.avTransportVersion, 1);
      expect(p.sinkProtocols, isEmpty);
      expect(p.capabilities, isEmpty);
    });
  });

  group('CastProfileStore', () {
    test('按 udn: 键精确记忆与查找；空 UDN 忽略', () async {
      final store = CastProfileStore();
      await store.remember(CastDeviceProfile(udn: 'uuid:profile-1'));
      expect(store.lookup('uuid:profile-1'), isNotNull);
      expect(store.toJson().keys, contains('udn:uuid:profile-1'));
      expect(store.lookup('uuid:unknown'), isNull);
      expect(store.lookup(''), isNull);
      // 空 UDN 的画像不入表。
      await store.remember(const CastDeviceProfile(udn: ''));
      expect(store.toJson().length, 1);
    });

    test('replaceAll/absorb 只认 udn: 前缀；absorb 只补缺', () async {
      final store = CastProfileStore();
      await store.remember(const CastDeviceProfile(
        udn: 'uuid:mine',
        profileId: kProfileGeneric,
      ));
      store.absorb(<String, dynamic>{
        'udn:uuid:other': <String, dynamic>{'udn': 'uuid:other'},
        // 本机已有的画像不覆盖。
        'udn:uuid:mine': <String, dynamic>{
          'udn': 'uuid:mine',
          'profileId': kProfilePnRequired,
        },
        'model:junk': <String, dynamic>{'udn': 'junk'},
      });
      expect(store.lookup('uuid:other'), isNotNull);
      expect(store.lookup('uuid:mine')!.profileId, kProfileGeneric);
      expect(store.toJson().length, 2);

      // replaceAll 整表替换（读盘路径）。
      store.replaceAll(<String, dynamic>{
        'udn:uuid:fresh': <String, dynamic>{
          'udn': 'uuid:fresh',
          'profileId': kProfileStrictTitle,
        },
      });
      expect(store.toJson().keys, <String>['udn:uuid:fresh']);
    });
  });
}
