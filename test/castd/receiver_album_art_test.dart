/// 投送封面单测（AC-1 / AC-4，11-07-cast-receiver-advanced R3.1）：
/// - didlAlbumArtUrl 表驱动（无/单/多/相对/CDATA/坏串/命名空间变体）；
/// - didlMimeType（protocolInfo 第 3 段 / upnp:class 推导）；
/// - RendererMediaOpened → ReceiverSession 透传（albumArtUrl/mimeType）；
/// - 音频投送判定 receiverCastIsAudio（播放页占位逻辑的可测部分）。
library;

import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_renderer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const base = 'http://192.168.1.9:18280/p/tok1/e1.mp4';
  const art = 'http://192.168.1.9:18280/p/tok1/cover.jpg';

  String didl(String albumArtTag) => '<DIDL-Lite '
      'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="1" parentID="0" restricted="1">'
      '<dc:title>第 1 集</dc:title>'
      '<res protocolInfo="http-get:*:video/mp4:*">$base</res>'
      '$albumArtTag'
      '</item></DIDL-Lite>';

  group('didlAlbumArtUrl（R2.1 表驱动：无/单/多/相对/CDATA/坏串）', () {
    final cases = <String, ({String? metadata, String? expect})>{
      // 无封面。
      'null metadata': (metadata: null, expect: null),
      '空 metadata': (metadata: '', expect: null),
      '无 albumArtURI': (
        metadata: didl('<upnp:album>剧集</upnp:album>'),
        expect: null,
      ),
      // 单条 http(s)。
      'upnp:albumArtURI 单条': (
        metadata: didl('<upnp:albumArtURI>$art</upnp:albumArtURI>'),
        expect: art,
      ),
      '带属性': (
        metadata: didl('<upnp:albumArtURI id="1">$art</upnp:albumArtURI>'),
        expect: art,
      ),
      // 命名空间/大小写变体（发送端 DIDL 经常不规范）。
      '无前缀 albumArtURI': (
        metadata: '<item><albumArtURI>$art</albumArtURI></item>',
        expect: art,
      ),
      '自定义前缀 pv:': (
        metadata: '<item><pv:albumArtURI>$art</pv:albumArtURI></item>',
        expect: art,
      ),
      '小写 albumArtUri': (
        metadata: '<item><upnp:albumArtUri>$art</upnp:albumArtUri></item>',
        expect: art,
      ),
      // CDATA 包裹（值可带换行/空白）。
      'CDATA 包裹': (
        metadata: didl('<upnp:albumArtURI><![CDATA[\n  $art  \n]]></upnp:albumArtURI>'),
        expect: art,
      ),
      // 实体转义。
      '实体转义': (
        metadata: didl(
            '<upnp:albumArtURI>http://x/a?b=1&amp;c=2</upnp:albumArtURI>'),
        expect: 'http://x/a?b=1&c=2',
      ),
      // 多条：取文档序第一个可用 URL。
      '多条取第一个': (
        metadata: didl('<upnp:albumArtURI>$art</upnp:albumArtURI>'
            '<upnp:albumArtURI>http://other/cover2.jpg</upnp:albumArtURI>'),
        expect: art,
      ),
      // 相对路径按 CurrentURI resolve。
      '相对路径 resolve': (
        metadata: didl('<upnp:albumArtURI>cover.jpg</upnp:albumArtURI>'),
        expect: 'http://192.168.1.9:18280/p/tok1/cover.jpg',
      ),
      '相对路径（带目录）': (
        metadata: didl('<upnp:albumArtURI>../art/cover.png</upnp:albumArtURI>'),
        expect: 'http://192.168.1.9:18280/p/art/cover.png',
      ),
      // 值里混 HTML/描述文字时取第一个 http(s)。
      '混排取 http(s)': (
        metadata: didl('<upnp:albumArtURI>封面 <a href="$art">图</a></upnp:albumArtURI>'),
        expect: art,
      ),
      // 不可用形态全弃 → null。
      '只有非 http 相对也解析不出': (
        metadata: '<item><upnp:albumArtURI>ftp://x/c.jpg</upnp:albumArtURI></item>',
        expect: null,
      ),
      '空元素': (
        metadata: didl('<upnp:albumArtURI></upnp:albumArtURI>'),
        expect: null,
      ),
      '坏串不抛异常': (metadata: '<<<不是XML', expect: null),
      '配对错乱不跨元素': (
        metadata: '<item><upnp:albumArtURI><upnp:albumArtURI>$art'
            '</upnp:albumArtURI></item>',
        expect: art,
      ),
    };

    cases.forEach((name, c) {
      test(name, () {
        expect(didlAlbumArtUrl(c.metadata, base), c.expect);
      });
    });
  });

  group('didlMimeType（音频投送判定输入，R2.2）', () {
    test('res protocolInfo 第 3 段优先', () {
      expect(
        didlMimeType(didl('')),
        'video/mp4',
      );
      expect(
        didlMimeType('<res protocolInfo="http-get:*:audio/mpeg:*,DLNA.ORG_OP=01">'
            'http://x/a.mp3</res>'),
        'audio/mpeg',
      );
      expect(didlMimeType('<res>无属性</res>'), isNull);
      expect(didlMimeType('<res protocolInfo="http-get:*:*:*">x</res>'), isNull,
          reason: '第 3 段为空回落 class');
    });

    test('upnp:class 推导兜底', () {
      expect(
        didlMimeType(
            '<item><upnp:class>object.item.audioItem.musicTrack</upnp:class></item>'),
        'audio/*',
      );
      expect(
        didlMimeType(
            '<item><upnp:class>object.item.videoItem</upnp:class></item>'),
        'video/*',
      );
      expect(
        didlMimeType(
            '<item><upnp:class>object.item.imageItem</upnp:class></item>'),
        'image/*',
      );
      expect(didlMimeType(null), isNull);
      expect(didlMimeType('<<<'), isNull);
    });
  });

  group('会话透传（R2.1：renderer → ReceiverMediaOpened → ReceiverSession）', () {
    test('onOpened 事件带 albumArtUrl/mimeType', () async {
      final stub = StubReceiverPlayer();
      final opened = <ReceiverMediaOpened>[];
      final renderer = ReceiverRenderer(player: stub, onOpened: opened.add);
      await renderer.handle(
        service: ReceiverService.avTransport,
        action: SoapActionRequest('SetAVTransportURI', {
          'InstanceID': '0',
          'CurrentURI': base,
          'CurrentURIMetaData': didl('<upnp:albumArtURI>$art</upnp:albumArtURI>'),
        }),
        senderAddress: '192.168.1.5',
        senderUserAgent: 'test/1.0',
      );
      expect(opened.single.albumArtUrl, art);
      expect(opened.single.mimeType, 'video/mp4');
      expect(opened.single.subtitleUrl, isNull);
    });

    test('无封面/坏 DIDL → 事件字段为 null（不报错）', () async {
      ReceiverMediaOpened? event;
      final withCapture = ReceiverRenderer(
        player: StubReceiverPlayer(),
        onOpened: (e) => event = e,
      );
      await withCapture.handle(
        service: ReceiverService.avTransport,
        action: const SoapActionRequest('SetAVTransportURI', {
          'InstanceID': '0',
          'CurrentURI': base,
          'CurrentURIMetaData': '<<<不是XML',
        }),
        senderAddress: '192.168.1.5',
      );
      expect(event, isNotNull);
      expect(event!.albumArtUrl, isNull);
      expect(event!.mimeType, isNull);
      expect(withCapture.currentUri, base);
    });
  });

  group('ReceiverController 会话透传（AC-4 可测部分，真实 loopback HTTP）', () {
    test('onIncomingSession 的 ReceiverSession 带 albumArtUrl/mimeType',
        () async {
      final controller = ReceiverController(
        playerOverride: StubReceiverPlayer(),
        udnSeed: 'udn-art-1',
        enableSsdp: false,
      );
      addTearDown(controller.stop);
      ReceiverSession? session;
      controller.onIncomingSession = (s) => session = s;
      await controller.start();

      final client = SoapClient();
      addTearDown(client.close);
      await client.sendAction(
        'http://127.0.0.1:${controller.port}/AVTransport/control',
        ReceiverService.avTransport.type,
        'SetAVTransportURI',
        {
          'InstanceID': '0',
          'CurrentURI': base,
          'CurrentURIMetaData':
              '<item><upnp:albumArtURI>$art</upnp:albumArtURI>'
              '<upnp:class>object.item.audioItem</upnp:class></item>',
        },
      );
      expect(session, isNotNull);
      expect(session!.albumArtUrl, art);
      expect(session!.mimeType, 'audio/*');
      expect(session!.senderAddress, '127.0.0.1');
    });
  });

  group('receiverCastIsAudio（播放页音频占位判定）', () {
    test('mime audio/* 命中；video/ 与空不命中', () {
      expect(
        receiverCastIsAudio(mimeType: 'audio/mpeg', url: base),
        isTrue,
      );
      expect(
        receiverCastIsAudio(mimeType: 'audio/*', url: base),
        isTrue,
      );
      expect(
        receiverCastIsAudio(mimeType: 'video/mp4', url: base),
        isFalse,
      );
      expect(
        receiverCastIsAudio(mimeType: null, url: base),
        isFalse,
      );
    });

    test('无 mime 时按 URL 扩展名兜底', () {
      expect(
        receiverCastIsAudio(mimeType: null, url: 'http://x/music.flac?tok=1'),
        isTrue,
      );
      expect(
        receiverCastIsAudio(mimeType: null, url: 'http://x/voice.M4A'),
        isTrue,
      );
      expect(
        receiverCastIsAudio(mimeType: null, url: 'http://x/e1.mp4'),
        isFalse,
      );
      expect(
        receiverCastIsAudio(mimeType: null, url: ''),
        isFalse,
      );
    });
  });
}
