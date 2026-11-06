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
      headers: headers,
    );

void main() {
  group('buildDidl / full', () {
    test('protocolInfo 用动态 mime + DLNA flags，res 内是实际 URI', () {
      final didl = buildDidl(
        _req(mimeType: 'video/x-matroska', sizeBytes: 12345),
        DidlVariant.full,
      );
      expect(
        didl,
        contains('protocolInfo="http-get:*:video/x-matroska:'
            'DLNA.ORG_OP=01;DLNA.ORG_CI=0;'
            'DLNA.ORG_FLAGS=01700000000000000000000000000000"'),
      );
      expect(didl, contains('size="12345"'));
      // URI 的 & 只转义一次，且真的写在 <res> 里。
      expect(didl, contains('>http://192.168.1.5:8080/movie.mp4?a=1&amp;b=2</res>'));
      expect(didl, contains('<upnp:class>object.item.videoItem.movie</upnp:class>'));
    });

    test('live 用 OP=00', () {
      final didl = buildDidl(_req(live: true), DidlVariant.full);
      expect(didl, contains('DLNA.ORG_OP=00'));
      expect(didl, isNot(contains('DLNA.ORG_OP=01')));
    });

    test('duration 按 H:MM:SS 输出', () {
      final didl = buildDidl(
        _req(duration: const Duration(hours: 1, minutes: 2, seconds: 3)),
        DidlVariant.full,
      );
      expect(didl, contains('duration="1:02:03"'));
    });

    test('按 mime 选细分 upnp:class', () {
      expect(buildDidl(_req(), DidlVariant.full),
          contains('object.item.videoItem.movie'));
      expect(buildDidl(_req(mimeType: 'audio/mpeg'), DidlVariant.full),
          contains('object.item.audioItem.musicTrack'));
      expect(buildDidl(_req(mimeType: 'image/jpeg'), DidlVariant.full),
          contains('object.item.imageItem.photo'));
      // HLS 走视频细分，不落到 image/audio。
      expect(buildDidl(_req(mimeType: 'video/mp2t'), DidlVariant.full),
          contains('object.item.videoItem.movie'));
    });

    test('dc:description 只带安全 headers（过滤凭据类键）', () {
      final didl = buildDidl(
        _req(headers: <String, String>{
          'Referer': 'http://origin/?a=1&b=2',
          'User-Agent': 'UA<1>',
          'Cookie': 'sid=SECRET',
          'Authorization': 'Bearer SECRET',
          'X-Token': 'SECRET',
          'X-Api-Key': 'SECRET',
          'X-Signature': 'SECRET',
        }),
        DidlVariant.full,
      );
      expect(didl, contains('<dc:description>'));
      expect(didl, contains('Referer'));
      expect(didl, contains('User-Agent'));
      for (final secret in <String>[
        'Cookie',
        'Authorization',
        'X-Token',
        'X-Api-Key',
        'X-Signature',
        'SECRET',
      ]) {
        expect(didl, isNot(contains(secret)), reason: '$secret 不得写进 DIDL');
      }
      // 转义后仍是合法 XML，且解析回来的 JSON 可还原。
      final doc = XmlDocument.parse(didl);
      final desc = doc.descendants
          .whereType<XmlElement>()
          .firstWhere((e) => e.name.local == 'description')
          .innerText;
      expect(desc, contains('"Referer"'));
      expect(desc, contains('http://origin/?a=1&b=2'));
    });

    test('只有凭据头时不产生 description', () {
      final didl = buildDidl(
        _req(headers: const <String, String>{'Cookie': 'x'}),
        DidlVariant.full,
      );
      expect(didl, isNot(contains('<dc:description>')));
    });

    test('字幕三标签齐全', () {
      final didl = buildDidl(
        _req(subtitleUri: Uri.parse('http://192.168.1.5:18280/p/sub.vtt')),
        DidlVariant.full,
      );
      expect(didl, contains('xmlns:sec="http://www.sec.co.kr/"'));
      expect(
        didl,
        contains('<sec:SubtitleUri>http://192.168.1.5:18280/p/sub.vtt</sec:SubtitleUri>'),
      );
      expect(
        didl,
        contains('<sec:CaptionInfoEx sec:type="srt">'
            'http://192.168.1.5:18280/p/sub.vtt</sec:CaptionInfoEx>'),
      );
      expect(
        didl,
        contains('<res protocolInfo="http-get:*:text/srt:*">'
            'http://192.168.1.5:18280/p/sub.vtt</res>'),
      );
    });

    test('全部文本 XML 转义且生成的是合法 XML', () {
      final didl = buildDidl(
        DidlRequest(
          uri: Uri.parse('http://x/a?b=1&c=2'),
          title: 'A & <B> "C" \'D\'',
          subtitleUri: Uri.parse('http://x/s.srt?a=1&b=2'),
        ),
        DidlVariant.full,
      );
      expect(didl, contains('A &amp; &lt;B&gt; &quot;C&quot; &apos;D&apos;'));
      expect(didl, contains('http://x/a?b=1&amp;c=2'));
      expect(didl, isNot(contains('<B>')));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });
  });

  group('minimal / none', () {
    test('minimal 保留旧语义并补通配 protocolInfo', () {
      final didl = buildDidl(_req(), DidlVariant.minimal);
      expect(didl, contains('protocolInfo="http-get:*:*/*:*"'));
      expect(didl, contains('<upnp:class>object.item.videoItem</upnp:class>'));
      expect(didl, contains('<dc:title>第1集</dc:title>'));
      expect(didl, contains('xmlns:sec="http://www.sec.co.kr/"'));
      expect(XmlDocument.parse(didl), isA<XmlDocument>());
    });

    test('none = 空 metadata', () {
      expect(buildDidl(_req(), DidlVariant.none), '');
      expect(buildDidlMetadata(_req(), DidlVariant.none), '');
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
      // 信封本身仍是合法 XML。
      expect(XmlDocument.parse(envelope), isA<XmlDocument>());
      // 普通参数仍按旧规则转义。
      final plain = buildEnvelope('urn:x', 'Play', <String, String>{
        'CurrentURIMetaData': '<DIDL-Lite/>',
      });
      expect(plain, contains('&lt;DIDL-Lite/&gt;'));
    });
  });

  group('buildDidlLite 旧签名兼容（转发 minimal）', () {
    test('标题转义 + 可选时长保持原样', () {
      final didl = buildDidlLite(title: '剧名 · <第3集> "特别版"');
      expect(didl, contains('&lt;第3集&gt;'));
      expect(didl, contains('&quot;特别版&quot;'));
      expect(didl, isNot(contains('duration=')));

      final withDuration =
          buildDidlLite(title: 'x', duration: '0:02:15.000');
      expect(withDuration, contains('duration="0:02:15.000"'));
      expect(withDuration, contains('object.item.videoItem'));
    });

    test('自定义 itemClass 与 sec:SubtitleUri 不丢', () {
      final didl = buildDidlLite(
        title: '第1集',
        itemClass: 'object.item.audioItem.musicTrack',
        subtitleUrl: Uri.parse('http://192.168.1.5:18280/p/sub1'),
      );
      expect(didl, contains('<upnp:class>object.item.audioItem.musicTrack</upnp:class>'));
      expect(didl,
          contains('<sec:SubtitleUri>http://192.168.1.5:18280/p/sub1</sec:SubtitleUri>'));
      expect(didl, contains('protocolInfo="http-get:*:*/*:*"'));
      // 旧调用点没有 URI，<res> 内容保持空。
      expect(didl, contains('></res>'));
    });
  });
}
