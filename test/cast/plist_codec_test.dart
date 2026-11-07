import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/airplay/plist_codec.dart';

/// hex 字符串 → 字节（python plistlib 产出的固定样例装载用）。
Uint8List _hexBytes(String hex) => Uint8List.fromList([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);

void main() {
  group('XML plist 编码 → 解码往返', () {
    test('标量类型（string/int/real/bool）+ 嵌套 dict/array', () {
      const value = <String, dynamic>{
        'Content-Location': 'http://192.168.1.5:18280/v/1.m3u8',
        'Start-Position': 0.0,
        'count': 3,
        'ready': true,
        'muted': false,
        'nested': <String, dynamic>{
          'name': '客厅',
          'items': <dynamic>['a', 2, 3.5, true],
        },
      };
      final xml = PlistCodec.encodeXml(value);
      expect(xml, contains('<plist version="1.0">'));
      expect(PlistCodec.parseXmlPlist(xml), equals(value));
    });

    test('URL 里的 & 转义往返（query 直链不丢参数）', () {
      const value = <String, dynamic>{
        'Content-Location': 'http://x/v/1.mp4?a=1&b=2',
      };
      final xml = PlistCodec.encodeXml(value);
      expect(xml, contains('&amp;'));
      final decoded = PlistCodec.parseXmlPlist(xml);
      expect(decoded['Content-Location'], 'http://x/v/1.mp4?a=1&b=2');
    });

    test('空 dict / 空 array', () {
      const value = <String, dynamic>{'e': <String, dynamic>{}, 'a': <dynamic>[]};
      final xml = PlistCodec.encodeXml(value);
      expect(xml, contains('<dict>'));
      expect(xml, contains('<array>'));
      expect(PlistCodec.parseXmlPlist(xml), equals(value));
    });

    test('不支持的类型抛 ArgumentError', () {
      expect(() => PlistCodec.encodeXml({'x': DateTime.now()}),
          throwsArgumentError);
    });
  });

  group('XML plist 解码（接收端报文容错）', () {
    // AirPlay 1 /playback-info 实报形状（含嵌套 array/dict 与布尔自闭合标签）。
    const playbackInfoXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>duration</key>
  <real>600.0</real>
  <key>loadedTimeRanges</key>
  <array>
    <dict>
      <key>duration</key>
      <real>600.0</real>
      <key>start</key>
      <real>0.0</real>
    </dict>
  </array>
  <key>playbackBufferEmpty</key>
  <true/>
  <key>position</key>
  <real>30.5</real>
  <key>rate</key>
  <real>1.0</real>
  <key>readyToPlay</key>
  <true/>
</dict>
</plist>
''';

    test('/playback-info 样例：标量与嵌套结构', () {
      final map = PlistCodec.parseXmlPlist(playbackInfoXml);
      expect(map['duration'], 600.0);
      expect(map['position'], 30.5);
      expect(map['rate'], 1.0);
      expect(map['readyToPlay'], isTrue);
      expect(map['playbackBufferEmpty'], isTrue);
      final ranges = map['loadedTimeRanges'] as List;
      expect(ranges, hasLength(1));
      expect((ranges.first as Map)['duration'], 600.0);
    });

    test('parsePlaybackInfo：duration/position/rate/readyToPlay 视图字段', () {
      final info = PlistCodec.parsePlaybackInfo(
        utf8.encode(playbackInfoXml),
        contentType: 'text/xml',
      );
      expect(info.duration, 600.0);
      expect(info.position, 30.5);
      expect(info.rate, 1.0);
      expect(info.readyToPlay, isTrue);
      expect(info.hasDuration, isTrue);
      expect(info.loaded, isTrue);
    });

    test('无 duration 键（未起播）→ hasDuration=false、loaded=false', () {
      const xml = '<plist version="1.0"><dict>'
          '<key>readyToPlay</key><false/>'
          '</dict></plist>';
      final info = PlistCodec.parsePlaybackInfo(utf8.encode(xml));
      expect(info.hasDuration, isFalse);
      expect(info.readyToPlay, isFalse);
      expect(info.loaded, isFalse);
    });

    test('空 body / 畸形 XML / 非 dict 顶层 → 空 map 不抛', () {
      expect(PlistCodec.parsePlist(const <int>[]), isEmpty);
      expect(PlistCodec.parseXmlPlist('not xml at all'), isEmpty);
      expect(PlistCodec.parseXmlPlist('<plist version="1.0"><string>x</string></plist>'),
          isEmpty);
    });

    test('integer 负数与纯数字 real', () {
      const xml = '<plist version="1.0"><dict>'
          '<key>n</key><integer>-7</integer>'
          '<key>r</key><real>0.25</real>'
          '</dict></plist>';
      final map = PlistCodec.parseXmlPlist(xml);
      expect(map['n'], -7);
      expect(map['r'], 0.25);
    });

    test('XML 实体解码（接收端转义输出）', () {
      const xml = '<plist version="1.0"><dict>'
          '<key>u</key><string>http://x/a?v=1&amp;w=2</string>'
          '</dict></plist>';
      expect(PlistCodec.parseXmlPlist(xml)['u'], 'http://x/a?v=1&w=2');
    });
  });

  group('binary plist（bplist00）解码', () {
    // python3 plistlib.dumps({'duration': 180.0, 'position': 12.5,
    //   'rate': 1.0, 'readyToPlay': True}, fmt=FMT_BINARY) 的字节。
    const playbackInfoBplist = '62706c6973743030d40102030405060708586475726174696f6e'
        '58706f736974696f6e54726174655b7265616479546f506c6179234066800000000000'
        '234029000000000000233ff00000000000000908111a2328343d464f00000000000001'
        '01000000000000000900000000000000000000000000000050';

    // python3 plistlib.dumps({'名称': '客厅', 'n': 3}) —— UTF-16BE 字符串分支。
    const unicodeBplist = '62706c6973743030d201020304516e62540d79f01003625ba2538508'
        '0d0f1416000000000000010100000000000000050000000000000000000000000000001b';

    test('/playback-info 二进制样例（AirPlay 2 接收端口径）', () {
      final map = PlistCodec.parsePlist(_hexBytes(playbackInfoBplist),
          contentType: PlistCodec.binaryPlistContentType);
      expect(map['duration'], 180.0);
      expect(map['position'], 12.5);
      expect(map['rate'], 1.0);
      expect(map['readyToPlay'], isTrue);
    });

    test('无 Content-Type 时按魔数嗅探', () {
      final bytes = _hexBytes(playbackInfoBplist);
      expect(PlistCodec.parsePlist(bytes), containsPair('rate', 1.0));
      expect(PlistCodec.isBinaryPlist(bytes), isTrue);
    });

    test('UTF-16BE 字符串（中文键值）', () {
      final map = BinaryPlistDecoder.decodeAny(_hexBytes(unicodeBplist))
          as Map<String, dynamic>;
      expect(map['名称'], '客厅');
      expect(map['n'], 3);
    });

    test('过短 / 错头 / 根非 dict 抛 ArgumentError', () {
      expect(() => BinaryPlistDecoder.decode(Uint8List.fromList(List.filled(16, 0))),
          throwsArgumentError);
      final badHeader = utf8.encode('notplist00000000000000000000000000000000000');
      expect(() => BinaryPlistDecoder.decode(Uint8List.fromList(badHeader)),
          throwsArgumentError);
    });

    test('二进制解不了降级空 map（误标 Content-Type 容错）', () {
      expect(PlistCodec.parsePlist(utf8.encode('garbage garbage'),
          contentType: PlistCodec.binaryPlistContentType), isEmpty);
    });
  });
}
