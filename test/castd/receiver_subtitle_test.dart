/// 接收端字幕链路单测（R2.1–R2.4 / B-4）：DIDL sec:CaptionInfo(Ex) 表驱动
/// 解析 + 渲染器/会话/引擎透传。不 import media_kit 适配层（同
/// receiver_settings_tile_test 口径）。
library;

import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';
import 'package:aquan_duanju/core/castd/receiver_controller.dart';
import 'package:aquan_duanju/core/castd/receiver_descriptions.dart';
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:aquan_duanju/core/castd/receiver_renderer.dart';
import 'package:aquan_duanju/core/castd/receiver_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('didlSubtitleUrl（R2.1 表驱动：无/单/多/相对/CDATA/坏串）', () {
    const base = 'http://192.168.1.9:18280/p/tok1/e1.mp4';
    const subtitle = 'http://192.168.1.9:18280/p/tok1/e1.srt';

    String didl(String caption) => '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:sec="http://www.sec.co.kr/">'
        '<item id="1" parentID="0" restricted="1">'
        '<dc:title>第 1 集</dc:title>'
        '<res protocolInfo="http-get:*:video/mp4:*">$base</res>'
        '$caption'
        '</item></DIDL-Lite>';

    final cases = <String, ({String? metadata, String? expect})>{
      // 无字幕。
      'null metadata': (metadata: null, expect: null),
      '空 metadata': (metadata: '', expect: null),
      '无字幕元素': (
        metadata: didl('<upnp:album>剧集</upnp:album>'),
        expect: null,
      ),
      // 单条 http(s)。
      'sec:CaptionInfo 单条': (
        metadata: didl(
            '<sec:CaptionInfo sec:type="srt">$subtitle</sec:CaptionInfo>'),
        expect: subtitle,
      ),
      'sec:CaptionInfoEx 优先': (
        metadata: didl(
            '<sec:CaptionInfoEx sec:type="srt">$subtitle</sec:CaptionInfoEx>'),
        expect: subtitle,
      ),
      // CDATA 包裹（值可带换行/空白）。
      'CDATA 包裹': (
        metadata: didl(
            '<sec:CaptionInfoEx sec:type="srt"><![CDATA[\n  $subtitle  \n]]></sec:CaptionInfoEx>'),
        expect: subtitle,
      ),
      // 多条：取文档序第一个可用 URL。
      '多条取第一个': (
        metadata: didl(
            '<sec:CaptionInfoEx sec:type="srt">$subtitle</sec:CaptionInfoEx>'
            '<sec:CaptionInfo sec:type="srt">http://other/e1.chi.srt</sec:CaptionInfo>'),
        expect: subtitle,
      ),
      '第一条坏串回落第二条': (
        metadata: didl(
            '<sec:CaptionInfoEx><![CDATA[  ]]></sec:CaptionInfoEx>'
            '<sec:CaptionInfo>http://other/e1.srt</sec:CaptionInfo>'),
        expect: 'http://other/e1.srt',
      ),
      // 相对路径按 CurrentURI resolve。
      '相对路径（绝对段）': (
        metadata: didl('<sec:CaptionInfo>/p/tok1/e1.srt</sec:CaptionInfo>'),
        expect: subtitle,
      ),
      '相对路径（相对段）': (
        metadata: didl('<sec:CaptionInfo>sub/e1.srt</sec:CaptionInfo>'),
        expect: 'http://192.168.1.9:18280/p/tok1/sub/e1.srt',
      ),
      // 实体转义。
      'URL 实体转义': (
        metadata: didl(
            '<sec:CaptionInfo>http://a/b?x=1&amp;y=2</sec:CaptionInfo>'),
        expect: 'http://a/b?x=1&y=2',
      ),
      // 容错：任意命名空间前缀 + 大小写。
      '非常规前缀/大小写': (
        metadata: didl('<DLNA:captioninfo>http://a/e1.srt</DLNA:captioninfo>'),
        expect: 'http://a/e1.srt',
      ),
      // 值里混描述文字：优先取第一个 http(s) URL。
      '值混描述文字': (
        metadata: didl(
            '<sec:CaptionInfo>字幕 http://a/e1.srt 请下载</sec:CaptionInfo>'),
        expect: 'http://a/e1.srt',
      ),
      // 坏串 / 非 http(s)。
      '非 http 绝对地址': (
        metadata: didl('<sec:CaptionInfo>ftp://a/e1.srt</sec:CaptionInfo>'),
        expect: null,
      ),
      '纯空白值': (
        metadata: didl('<sec:CaptionInfo><![CDATA[   ]]></sec:CaptionInfo>'),
        expect: null,
      ),
    };

    cases.forEach((name, c) {
      test(name, () {
        expect(didlSubtitleUrl(c.metadata, base), c.expect, reason: name);
      });
    });

    test('坏串不炸：垃圾文本按相对路径 resolve（下游加载失败静默无字幕）', () {
      expect(
        didlSubtitleUrl(
          '<DIDL-Lite><sec:CaptionInfo><![CDATA[ > >>> ]]></sec:CaptionInfo></DIDL-Lite>',
          base,
        ),
        'http://192.168.1.9:18280/p/tok1/%3E%20%3E%3E%3E',
      );
    });

    test('CurrentURI 不可解析 → 相对路径放弃（返回 null）', () {
      expect(
        didlSubtitleUrl(
          '<DIDL-Lite><sec:CaptionInfo>/a.srt</sec:CaptionInfo></DIDL-Lite>',
          'http://[bad',
        ),
        isNull,
      );
    });

    test('自家发送端 buildDidlLite(subtitleUrl:) ↔ 接收端解析互操作', () {
      // 发送端三件套标签（CaptionInfo + CaptionInfoEx + pv:…）由接收端正则
      // 容错解析：互操作回归锁死「自家发送端 ↔ 自家接收端」链路。
      final metadata = buildDidlLite(
        title: '第 1 集',
        subtitleUrl: Uri.parse(subtitle),
      );
      expect(didlSubtitleUrl(metadata, base), subtitle);
    });
  });

  group('SetAVTransportURI 字幕透传（R2.2/R2.3）', () {
    const base = 'http://192.168.1.9:18280/p/tok1/e1.mp4';
    const subtitle = 'http://192.168.1.9:18280/p/tok1/e1.srt';
    final didlWithCaption = '<DIDL-Lite '
        'xmlns:sec="http://www.sec.co.kr/">'
        '<dc:title>第 1 集</dc:title>'
        '<sec:CaptionInfoEx sec:type="srt">$subtitle</sec:CaptionInfoEx>'
        '</DIDL-Lite>';

    test('渲染器把 subtitleUrl 传给引擎与 onOpened 事件', () async {
      final stub = StubReceiverPlayer();
      ReceiverMediaOpened? opened;
      final renderer = ReceiverRenderer(player: stub, onOpened: (e) => opened = e);

      await renderer.handle(
        service: ReceiverService.avTransport,
        action: SoapActionRequest('SetAVTransportURI', {
          'CurrentURI': base,
          'CurrentURIMetaData': didlWithCaption,
        }),
        senderAddress: '192.168.1.5',
        senderUserAgent: 'test/1.0',
      );

      expect(stub.loadedSubtitleUrl, subtitle);
      expect(opened?.subtitleUrl, subtitle);
      expect(opened?.title, '第 1 集');
      expect(opened?.url, base);
    });

    test('无字幕元素 → subtitleUrl null（字幕失败不阻断投送）', () async {
      final stub = StubReceiverPlayer();
      ReceiverMediaOpened? opened;
      final renderer = ReceiverRenderer(player: stub, onOpened: (e) => opened = e);

      await renderer.handle(
        service: ReceiverService.avTransport,
        action: SoapActionRequest('SetAVTransportURI', {
          'CurrentURI': base,
          'CurrentURIMetaData': buildDidlLite(title: '第 1 集'),
        }),
      );

      expect(stub.loadedSubtitleUrl, isNull);
      expect(opened?.subtitleUrl, isNull);
      expect(stub.loadCount, 1, reason: '主投送链不受字幕缺失影响');
    });

    test('StubReceiverPlayer.load 记录 loadedSubtitleUrl（stub 同步字段）', () async {
      final stub = StubReceiverPlayer();
      await stub.load(Uri.parse(base), title: 't', subtitleUrl: subtitle);
      expect(stub.loadedSubtitleUrl, subtitle);
      expect(stub.loadedTitle, 't');

      await stub.load(Uri.parse(base));
      expect(stub.loadedSubtitleUrl, isNull, reason: '新投不带字幕则清空');
    });

    test('SetAVTransportURI 带字幕 → 会话载荷带 subtitleUrl（loopback 全链）', () async {
      final stub = StubReceiverPlayer();
      final controller = ReceiverController(
        playerOverride: stub,
        udnSeed: 'udn-sub',
        enableSsdp: false,
      );
      final service = CastReceiverService.forTest(controller: controller);
      await service.setEnabled(true);
      addTearDown(() => service.setEnabled(false));

      final client = SoapClient();
      try {
        await client.sendAction(
          'http://127.0.0.1:${controller.port}/AVTransport/control',
          ReceiverService.avTransport.type,
          'SetAVTransportURI',
          {
            'InstanceID': '0',
            'CurrentURI': base,
            'CurrentURIMetaData': didlWithCaption,
          },
        );
      } finally {
        client.close();
      }

      expect(stub.loadedSubtitleUrl, subtitle);
      expect(service.session.value?.subtitleUrl, subtitle);
      expect(service.session.value?.title, '第 1 集');
    });
  });
}
