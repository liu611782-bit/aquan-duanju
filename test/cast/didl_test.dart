import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/core/cast/soap_client.dart';

DidlRequest _req({
  String title = '第1集',
  String mimeType = 'video/mp4',
  Duration? duration,
  int? sizeBytes,
  bool live = false,
  Uri? subtitleUri,
  Uri? albumArtUrl,
  Map<String, String> headers = const <String, String>{},
}) =>
    DidlRequest(
      uri: Uri.parse('http://192.168.1.5:8080/movie.mp4?a=1&b=2'),
      title: title,
      mimeType: mimeType,
      duration: duration,
      sizeBytes: sizeBytes,
      live: live,
      subtitleUri: subtitleUri,
      albumArtUrl: albumArtUrl,
      headers: headers,
    );

void main() {
  group('AC-11：三变体恒含 dc:title + upnp:class，CurrentURIMetaData 恒非空', () {
    for (final variant in DidlVariant.values) {
      test('variant=${variant.name}', () {
        final didl = buildDidl(_req(), variant);
        expect(didl, isNotEmpty);
        expect(didl, contains('<dc:title>第1集</dc:title>'));
        expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
        final metadata = buildDidlMetadata(_req(), variant);
        expect(metadata, isNotEmpty);
        expect(metadata, startsWith('<![CDATA['));
      });
    }

    test('compatEscaped 同样走 CDATA 包裹（信封识别不二次转义）', () {
      final envelope = buildEnvelope(
        'urn:schemas-upnp-org:service:AVTransport:1',
        'SetAVTransportURI',
        <String, String>{
          'InstanceID': '0',
          'CurrentURI': 'http://x/1.mp4',
          'CurrentURIMetaData':
              buildDidlMetadata(_req(), DidlVariant.compatEscaped),
        },
      );
      expect(envelope, contains('<![CDATA[<DIDL-Lite'));
      expect(envelope, isNot(contains('&lt;DIDL-Lite')));
      expect(XmlDocument.parse(envelope), isA<XmlDocument>());
    });
  });

  group('upnp:class 两段式', () {
    test('video/audio/image 按 mime 推导，不再有 .movie 等三段细分', () {
      expect(buildDidl(_req(), DidlVariant.full),
          contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(buildDidl(_req(mimeType: 'audio/mpeg'), DidlVariant.full),
          contains('<upnp:class>object.item.audioItem</upnp:class>'));
      expect(buildDidl(_req(mimeType: 'image/jpeg'), DidlVariant.full),
          contains('<upnp:class>object.item.imageItem</upnp:class>'));
      expect(buildDidl(_req(), DidlVariant.full), isNot(contains('.movie')));
      expect(
          buildDidl(_req(), DidlVariant.full), isNot(contains('musicTrack')));
    });

    test('HLS/TS 走视频大类', () {
      expect(buildDidl(_req(mimeType: 'application/vnd.apple.mpegurl'), DidlVariant.full),
          contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(buildDidl(_req(mimeType: 'video/mp2t'), DidlVariant.full),
          contains('<upnp:class>object.item.videoItem</upnp:class>'));
    });
  });

  group('full / compact / compatEscaped 形态差异', () {
    test('full：dc:description / duration / size 齐全（真实值才写，AC-27）', () {
      final didl = buildDidl(
        _req(
          duration: const Duration(hours: 1, minutes: 2, seconds: 3),
          sizeBytes: 12345,
          headers: const <String, String>{'Referer': 'http://origin/'},
        ),
        DidlVariant.full,
      );
      expect(didl, contains('<dc:description>'));
      expect(didl, contains('duration="1:02:03"'));
      expect(didl, contains('size="12345"'));
    });

    test('duration 未知/为零不写（写错比不写更糟）', () {
      expect(buildDidl(_req(), DidlVariant.full), isNot(contains('duration=')));
      expect(
        buildDidl(_req(duration: Duration.zero), DidlVariant.full),
        isNot(contains('duration=')),
      );
      expect(
        buildDidl(_req(duration: const Duration(seconds: 2)), DidlVariant.full),
        contains('duration="0:00:02"'),
      );
    });

    test('只有凭据头时不产生 description', () {
      final didl = buildDidl(
        _req(headers: const <String, String>{'Cookie': 'x'}),
        DidlVariant.full,
      );
      expect(didl, isNot(contains('<dc:description>')));
    });

    test('dc:description 只带安全 headers（过滤凭据类键）', () {
      final didl = buildDidl(
        _req(headers: <String, String>{
          'Referer': 'http://origin/?a=1&b=2',
          'User-Agent': 'UA<1>',
          'Cookie': 'sid=SECRET',
          'Authorization': 'Bearer SECRET',
          'X-Token': 'SECRET',
        }),
        DidlVariant.full,
      );
      expect(didl, contains('<dc:description>'));
      expect(didl, contains('Referer'));
      expect(didl, isNot(contains('SECRET')));
      final doc = XmlDocument.parse(didl);
      final desc = doc.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'description')
          .innerText;
      expect(desc, contains('"Referer"'));
    });

    test('sendDcDescription=false：headers 非空也不写 description', () {
      final didl = buildDidl(
        _req(headers: const <String, String>{'Referer': 'http://origin/'}),
        DidlVariant.full,
        sendDcDescription: false,
      );
      expect(didl, isNot(contains('<dc:description>')));
    });

    test('compact：去 description/duration/size，保留 title/class/res', () {
      final didl = buildDidl(
        _req(
          duration: const Duration(minutes: 2),
          sizeBytes: 999,
          headers: const <String, String>{'Referer': 'http://origin/'},
        ),
        DidlVariant.compact,
      );
      expect(didl, contains('<dc:title>第1集</dc:title>'));
      expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(didl, contains('<res protocolInfo='));
      expect(didl, isNot(contains('<dc:description>')));
      expect(didl, isNot(contains('duration=')));
      expect(didl, isNot(contains('size=')));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });

    test('compatEscaped：`"` 不转义 &quot;、`&` 不转义 &amp;（go2tv legacy-compat）',
        () {
      final didl = buildDidl(
        DidlRequest(
          uri: Uri.parse('http://x/a?b=1&c=2'),
          title: 'A & <B> "C"',
        ),
        DidlVariant.compatEscaped,
      );
      // & 与 " 保持原样。
      expect(didl, contains('A & &lt;B&gt; "C"'));
      expect(didl, contains('>http://x/a?b=1&c=2</res>'));
      expect(didl, isNot(contains('&quot;')));
      expect(didl, isNot(contains('&amp;')));
      // 结构性字符仍转义（DIDL 自身标签不串位）。
      expect(didl, contains('&lt;B&gt;'));
      // 对比：full 变体全部转义。
      final full = buildDidl(
        DidlRequest(uri: Uri.parse('http://x/a?b=1&c=2'), title: 'A & <B> "C"'),
        DidlVariant.full,
      );
      expect(full, contains('A &amp; &lt;B&gt; &quot;C&quot;'));
    });

    test('compatEscaped 无特殊字符时仍是合法 XML', () {
      final didl = buildDidl(
        DidlRequest(uri: Uri.parse('http://x/a.mp4'), title: '纯标题'),
        DidlVariant.compatEscaped,
      );
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });
  });

  group('字幕三件套（subtitleMode）', () {
    const subUrl = 'http://192.168.1.5:18280/p/sub.srt';
    Uri sub() => Uri.parse(subUrl);

    test('both：sec:CaptionInfo + sec:CaptionInfoEx + 独立 text/srt res', () {
      final didl = buildDidl(_req(subtitleUri: sub()), DidlVariant.full);
      expect(didl, contains('xmlns:sec="http://www.sec.co.kr/"'));
      expect(didl, contains('<sec:CaptionInfo sec:type="srt">$subUrl</sec:CaptionInfo>'));
      expect(didl, contains('<sec:CaptionInfoEx sec:type="srt">$subUrl</sec:CaptionInfoEx>'));
      expect(didl, contains('<res protocolInfo="http-get:*:text/srt:*">$subUrl</res>'));
      expect(didl, isNot(contains('sec:SubtitleUri')), reason: 'v2 取代 SubtitleUri 三件套');
    });

    test('captionInfoEx：只带 Samsung 优先识别的标签', () {
      final didl = buildDidl(
        _req(subtitleUri: sub()),
        DidlVariant.full,
        subtitleMode: CastSubtitleMode.captionInfoEx,
      );
      expect(didl, contains('<sec:CaptionInfoEx'));
      expect(didl, isNot(contains('<sec:CaptionInfo ')));
      expect(didl, isNot(contains('text/srt')));
    });

    test('none：不写任何字幕标签（不制造噪声）', () {
      final didl = buildDidl(
        _req(subtitleUri: sub()),
        DidlVariant.full,
        subtitleMode: CastSubtitleMode.none,
      );
      expect(didl, isNot(contains('sec:')));
      expect(didl, isNot(contains('text/srt')));
    });

    test('compact 变体同样按 subtitleMode 投送字幕（功能字段）', () {
      final didl = buildDidl(_req(subtitleUri: sub()), DidlVariant.compact);
      expect(didl, contains('<sec:CaptionInfoEx'));
      expect(didl, contains('text/srt'));
    });

    test('无字幕时不带 sec 节点', () {
      expect(buildDidl(_req(), DidlVariant.full), isNot(contains('sec:')));
    });
  });

  group('albumArtURI（发送端封面投送，11-07-cast-cover-art）', () {
    const artUrl = 'http://192.168.1.5:18280/p/tok1/cover.jpg?w=600&h=800';
    Uri art() => Uri.parse(artUrl);

    test('full：res 之后、字幕标签之前输出 <upnp:albumArtURI>', () {
      final didl = buildDidl(
        _req(albumArtUrl: art(), subtitleUri: Uri.parse('http://x/sub.srt')),
        DidlVariant.full,
      );
      // full 口径转义：& → &amp;。
      expect(
          didl,
          contains('<upnp:albumArtURI>'
              'http://192.168.1.5:18280/p/tok1/cover.jpg?w=600&amp;h=800'
              '</upnp:albumArtURI>'));
      // 位置：res → albumArtURI → 字幕三件套（接收端按文档序取值）。
      final resEnd = didl.indexOf('</res>');
      final artIndex = didl.indexOf('<upnp:albumArtURI>');
      final subIndex = didl.indexOf('<sec:CaptionInfo');
      expect(resEnd, greaterThanOrEqualTo(0));
      expect(artIndex, greaterThan(resEnd));
      expect(subIndex, greaterThan(artIndex));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });

    test('full：URL 含 & 转义为 &amp;（沿用 full 转义口径）', () {
      final didl = buildDidl(_req(albumArtUrl: art()), DidlVariant.full);
      expect(didl, contains('<upnp:albumArtURI>'
          'http://192.168.1.5:18280/p/tok1/cover.jpg?w=600&amp;h=800'
          '</upnp:albumArtURI>'));
      // 未转义的裸 & 不出现在 albumArtURI 值里（res 值同口径）。
      expect(didl, isNot(contains('?w=600&h=')));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });

    test('compact：不输出 albumArtURI（最小形态）', () {
      final didl = buildDidl(_req(albumArtUrl: art()), DidlVariant.compact);
      expect(didl, isNot(contains('albumArtURI')));
    });

    test('compatEscaped：不输出 albumArtURI（与 full 保持最小差异）', () {
      final didl = buildDidl(_req(albumArtUrl: art()), DidlVariant.compatEscaped);
      expect(didl, isNot(contains('albumArtURI')));
    });

    test('无封面：三变体都不出该标签（零变化）', () {
      for (final variant in DidlVariant.values) {
        expect(buildDidl(_req(), variant), isNot(contains('albumArtURI')),
            reason: 'variant=${variant.name}');
      }
    });
  });

  group('protocolInfo 六模板', () {
    test('standard（现状默认）：OP=01 + CI=0 + FLAGS', () {
      final didl = buildDidl(_req(), DidlVariant.full);
      expect(
        didl,
        contains('protocolInfo="http-get:*:video/mp4:'
            'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
            'DLNA.ORG_FLAGS=01700000000000000000000000000000"'),
      );
    });

    test('standard + live：OP=00', () {
      final didl = buildDidl(_req(live: true), DidlVariant.full);
      expect(didl, contains('DLNA.ORG_OP=00'));
      expect(didl, isNot(contains('DLNA.ORG_OP=01')));
    });

    test('bare：http-get:*:<mime>:*', () {
      final didl = buildDidl(
        _req(mimeType: 'application/vnd.apple.mpegurl'),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.bare,
      );
      expect(
        didl,
        contains('protocolInfo="http-get:*:application/vnd.apple.mpegurl:*"'),
      );
    });

    test('wildcard：http-get:*:*:*', () {
      final didl = buildDidl(
        _req(),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.wildcard,
      );
      expect(didl, contains('protocolInfo="http-get:*:*:*"'));
    });

    test('withPn：已知容器带 PN，live 用 OP=00', () {
      final didl = buildDidl(
        _req(mimeType: 'video/mp4'),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.withPn,
      );
      expect(
        didl,
        contains('protocolInfo="http-get:*:video/mp4:'
            'DLNA.ORG_PN=AVC_MP4_MP_HD_AAC;'
            'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
            'DLNA.ORG_FLAGS=01700000000000000000000000000000"'),
      );
      final ts = buildDidl(
        _req(mimeType: 'video/mp2t', live: true),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.withPn,
      );
      expect(ts, contains('DLNA.ORG_PN=MPEG_TS_HD_NA;DLNA.ORG_OP=00'));
    });

    test('withPn：未知容器回落 standard（自造 PN 比不带更糟）', () {
      final didl = buildDidl(
        _req(mimeType: 'video/x-matroska'),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.withPn,
      );
      expect(didl, isNot(contains('DLNA.ORG_PN')));
      expect(didl, contains('DLNA.ORG_OP=01'));
    });

    test('sinkEntry：原样复用 Sink 同容器条目第 4 段（逐字照抄）', () {
      final didl = buildDidl(
        _req(mimeType: 'video/mp4'),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.sinkEntry,
        sinkFourth: 'DLNA.ORG_PN=AVC_MP4_BL_CIF15_AAC;DLNA.ORG_OP=10;*',
      );
      expect(
        didl,
        contains('protocolInfo="http-get:*:video/mp4:'
            'DLNA.ORG_PN=AVC_MP4_BL_CIF15_AAC;DLNA.ORG_OP=10;*"'),
      );
    });

    test('sinkEntry：无 Sink 第 4 段（null）回落 standard', () {
      final didl = buildDidl(
        _req(mimeType: 'video/mp4'),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.sinkEntry,
      );
      expect(didl, contains('DLNA.ORG_OP=01;DLNA.ORG_CI=0'));
    });

    test('op11：OP=11（时间+字节 seek；仅限真答 206 的路由调用）', () {
      final didl = buildDidl(
        _req(),
        DidlVariant.full,
        template: DidlProtocolInfoTemplate.op11,
      );
      expect(didl, contains('DLNA.ORG_OP=11'));
      expect(didl, isNot(contains('DLNA.ORG_OP=01;')));
    });
  });

  group('sinkEntryFourthSegment（Sink 同容器条目解析）', () {
    const sink = <String>{
      'http-get:*:video/mp4:DLNA.ORG_PN=AVC_MP4_MP_HD_AAC;DLNA.ORG_OP=01',
      'http-get:*:video/vnd.dlna.mpeg-tts:MPEG_TS_HD_NA_T',
      'http-get:*:audio/mpeg',
      'http-get:*:*:*',
    };

    test('精确 mime 匹配 → 逐字返回第 4 段', () {
      expect(
        sinkEntryFourthSegment(sink, 'video/mp4'),
        'DLNA.ORG_PN=AVC_MP4_MP_HD_AAC;DLNA.ORG_OP=01',
      );
    });

    test('别名组匹配（mp2t ↔ vnd.dlna.mpeg-tts）照抄设备拼写条目', () {
      expect(sinkEntryFourthSegment(sink, 'video/mp2t'), 'MPEG_TS_HD_NA_T');
    });

    test('条目只有 3 段（无第 4 段）→ null（回落 standard）', () {
      expect(sinkEntryFourthSegment(sink, 'audio/mpeg'), isNull);
    });

    test('无同容器条目 → null', () {
      expect(sinkEntryFourthSegment(sink, 'image/jpeg'), isNull);
      expect(sinkEntryFourthSegment(const <String>{}, 'video/mp4'), isNull);
    });
  });

  group('CDATA 包裹（SOAP 信封不得双重转义）', () {
    test('wrapDidlCdata 原样保留已转义的 DIDL', () {
      final cdata = wrapDidlCdata('<a>&amp;</a>');
      expect(cdata, '<![CDATA[<a>&amp;</a>]]>');
      expect(cdata, isNot(contains('&amp;amp;')));
    });

    test('空串不被包成空 CDATA', () {
      expect(wrapDidlCdata(''), '');
    });

    test('意外 ]]> 被拆开，不截断 CDATA', () {
      final cdata = wrapDidlCdata('a]]>b');
      expect(cdata, '<![CDATA[a]]]]><![CDATA[>b]]>');
    });

    test('buildDidlMetadata 让 buildEnvelope 跳过二次转义', () {
      final metadata = buildDidlMetadata(_req(), DidlVariant.full);
      final envelope = buildEnvelope(
        'urn:schemas-upnp-org:service:AVTransport:1',
        'SetAVTransportURI',
        <String, String>{
          'InstanceID': '0',
          'CurrentURI': 'http://x/1.mp4',
          'CurrentURIMetaData': metadata,
        },
      );
      expect(envelope, contains('<![CDATA[<DIDL-Lite'));
      expect(envelope, isNot(contains('&lt;DIDL-Lite')));
      expect(envelope, isNot(contains('&lt;dc:title&gt;')),
          reason: 'CDATA 内不应二次转义');
      expect(XmlDocument.parse(envelope), isA<XmlDocument>());
      // 普通参数仍按旧规则转义。
      final plain = buildEnvelope('urn:x', 'Play', <String, String>{
        'CurrentURIMetaData': '<DIDL-Lite/>',
      });
      expect(plain, contains('&lt;DIDL-Lite/&gt;'));
    });
  });

  group('buildDidlLite 旧签名兼容（转发 compact + wildcard）', () {
    test('标题转义 + 恒含两段式 class；mime 无关（wildcard）', () {
      final didl = buildDidlLite(title: '剧名 · <第3集> "特别版"');
      expect(didl, contains('&lt;第3集&gt;'));
      expect(didl, contains('&quot;特别版&quot;'));
      expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(didl, contains('protocolInfo="http-get:*:*:*"'));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });

    test('compact 变体不写 duration（真实时长走 compat 链的 full 变体）', () {
      final withDuration = buildDidlLite(title: 'x', duration: '0:02:15.000');
      expect(withDuration, isNot(contains('duration=')));
    });

    test('自定义 itemClass 与字幕标签不丢', () {
      final didl = buildDidlLite(
        title: '第1集',
        itemClass: 'object.item.audioItem',
        subtitleUrl: Uri.parse('http://192.168.1.5:18280/p/sub1'),
      );
      expect(didl, contains('<upnp:class>object.item.audioItem</upnp:class>'));
      expect(didl,
          contains('<sec:CaptionInfoEx sec:type="srt">http://192.168.1.5:18280/p/sub1</sec:CaptionInfoEx>'));
      // 旧调用点没有 URI，<res> 内容保持空。
      expect(didl, contains('></res>'));
    });
  });
}
