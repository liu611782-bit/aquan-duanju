import 'dart:convert';
import 'dart:typed_data';

/// AirPlay plist 编解码（移植 dart_cast `plist_codec.dart` / `binary_plist.dart`
/// 最小子集，MIT；只覆盖 AirPlay 一期用到的类型）。
///
/// - XML plist：编码（dict/array/string/int/real/true/false）+ 解码；
/// - binary plist（`bplist00`）：仅解码（AirPlay 2 接收端对 /playback-info
///   回二进制 plist；AirPlay 1 回 XML，两者都要能吃）。
///
/// 一期 `/play` 报文用 `text/parameters` 文本体（见 airplay_transport.dart），
/// plist 编解码服务于 `/playback-info` 状态解析与后续二期 `/command`。
class PlistCodec {
  PlistCodec._();

  /// 二进制 plist 的 Content-Type 标识（AirPlay 2 口径）。
  static const String binaryPlistContentType = 'application/x-apple-binary-plist';

  /// 二进制 plist 魔数前缀 `bplist`。
  static const List<int> binaryPlistMagic = [
    0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, //
  ];

  /// [body] 是否以二进制 plist 魔数开头。
  static bool isBinaryPlist(List<int> body) {
    if (body.length < binaryPlistMagic.length) return false;
    for (var i = 0; i < binaryPlistMagic.length; i++) {
      if (body[i] != binaryPlistMagic[i]) return false;
    }
    return true;
  }

  /// 按 Content-Type / 魔数嗅探解码 plist（XML 或二进制）。
  ///
  /// 两种方式都失败时返回空 map——轮询循环绝不能被半坏报文打死
  /// （dart_cast 同口径：误标 Content-Type 的接收端降级为空结果）。
  static Map<String, dynamic> parsePlist(List<int> body,
      {String contentType = ''}) {
    if (body.isEmpty) return {};
    final looksBinary = contentType.toLowerCase().contains('binary-plist') ||
        isBinaryPlist(body);
    if (looksBinary) {
      try {
        return BinaryPlistDecoder.decode(Uint8List.fromList(body));
      } catch (_) {
        // 落回 XML：有的接收端会误标 Content-Type。
      }
    }
    try {
      return parseXmlPlist(utf8.decode(body, allowMalformed: true));
    } catch (_) {
      return {};
    }
  }

  // ---------------------------------------------------------------------------
  // XML plist 编码
  // ---------------------------------------------------------------------------

  /// 把 [dict] 编码为 XML plist 文本（dict/array/string/int/real/true/false）。
  ///
  /// 字符串做 XML 实体转义（& < > " '）；不支持其它类型（抛 ArgumentError）。
  static String encodeXml(Map<String, dynamic> dict) {
    final buf = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
          '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">')
      ..writeln('<plist version="1.0">');
    _writeXmlValue(buf, dict, indent: '');
    buf.writeln('</plist>');
    return buf.toString();
  }

  static void _writeXmlValue(StringBuffer buf, Object? value,
      {required String indent}) {
    if (value is Map<String, dynamic>) {
      // 空 dict 也写全闭合标签（Apple 解析端与自家解码都不认自闭合 <dict/>）。
      buf.writeln('$indent<dict>');
      value.forEach((key, v) {
        buf.writeln('$indent  <key>${_escapeXml(key)}</key>');
        _writeXmlValue(buf, v, indent: '$indent  ');
      });
      buf.writeln('$indent</dict>');
      return;
    }
    if (value is List) {
      buf.writeln('$indent<array>');
      for (final item in value) {
        _writeXmlValue(buf, item, indent: '$indent  ');
      }
      buf.writeln('$indent</array>');
      return;
    }
    if (value is bool) {
      buf.writeln('$indent<${value ? 'true' : 'false'}/>');
      return;
    }
    if (value is int) {
      buf.writeln('$indent<integer>$value</integer>');
      return;
    }
    if (value is double) {
      buf.writeln('$indent<real>${_formatReal(value)}</real>');
      return;
    }
    if (value is String) {
      buf.writeln('$indent<string>${_escapeXml(value)}</string>');
      return;
    }
    throw ArgumentError('不支持的 plist 类型: ${value.runtimeType}');
  }

  /// real 输出带小数点（Apple 解析端按浮点读，整数值也要像浮点）。
  static String _formatReal(double v) {
    final s = v.toString();
    return s.contains('.') || s.contains('e') || s.contains('E') ? s : '$s.0';
  }

  static String _escapeXml(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  /// 反转 XML 实体（自家编码的往返 + 容错接收端输出）。
  static String _unescapeXml(String s) => s
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');

  // ---------------------------------------------------------------------------
  // XML plist 解码（token 化，口径同 dart_cast）
  // ---------------------------------------------------------------------------

  /// 解析 XML plist 字符串为 [Map<String, dynamic>]。
  ///
  /// 空 / 畸形 / 顶层不是 `<dict>` 时返回空 map（不抛——状态轮询容错）。
  static Map<String, dynamic> parseXmlPlist(String xml) {
    if (xml.isEmpty) return {};
    try {
      final dictMatch = RegExp(
        r'<plist[^>]*>\s*<dict>(.*)</dict>\s*</plist>',
        dotAll: true,
      ).firstMatch(xml);
      if (dictMatch == null) return {};
      return _parseDict(dictMatch.group(1)!);
    } catch (_) {
      return {};
    }
  }

  static Map<String, dynamic> _parseDict(String content) {
    final result = <String, dynamic>{};
    final tokens = _tokenize(content);
    var i = 0;
    while (i < tokens.length) {
      final token = tokens[i];
      if (token.tag == 'key' && i + 1 < tokens.length) {
        result[_unescapeXml(token.value ?? '')] = _tokenValue(tokens[i + 1]);
        i += 2;
      } else {
        i++;
      }
    }
    return result;
  }

  static dynamic _tokenValue(_Token token) {
    switch (token.tag) {
      case 'real':
        return double.tryParse(token.value ?? '') ?? 0.0;
      case 'integer':
        return int.tryParse(token.value ?? '') ?? 0;
      case 'string':
        return _unescapeXml(token.value ?? '');
      case 'true':
        return true;
      case 'false':
        return false;
      case 'dict':
        return _parseDict(token.value ?? '');
      case 'array':
        return _parseArray(token.value ?? '');
      default:
        return null;
    }
  }

  static List<dynamic> _parseArray(String content) =>
      [for (final t in _tokenize(content)) _tokenValue(t)];

  /// 把 plist XML 内容拍平成 token 流：自闭合布尔、简单值标签、块级 dict/array
  /// （按嵌套深度找匹配闭标签，口径同 dart_cast `_tokenize`）。
  static List<_Token> _tokenize(String content) {
    final tokens = <_Token>[];
    var pos = 0;
    while (pos < content.length) {
      while (pos < content.length && _isWhitespace(content[pos])) {
        pos++;
      }
      if (pos >= content.length) break;
      if (content[pos] != '<') {
        pos++;
        continue;
      }
      final boolMatch =
          RegExp(r'<(true|false)\s*/>').matchAsPrefix(content, pos);
      if (boolMatch != null) {
        tokens.add(_Token(boolMatch.group(1)!, null));
        pos = boolMatch.end;
        continue;
      }
      final simpleMatch = RegExp(
        r'<(key|real|integer|string)>(.*?)</\1>',
        dotAll: true,
      ).matchAsPrefix(content, pos);
      if (simpleMatch != null) {
        tokens.add(_Token(simpleMatch.group(1)!, simpleMatch.group(2)!));
        pos = simpleMatch.end;
        continue;
      }
      final blockOpen = RegExp(r'<(dict|array)>').matchAsPrefix(content, pos);
      if (blockOpen != null) {
        final tag = blockOpen.group(1)!;
        final closeIndex =
            _findMatchingClose(content, blockOpen.end, tag);
        if (closeIndex != -1) {
          tokens.add(_Token(tag, content.substring(blockOpen.end, closeIndex)));
          pos = closeIndex + '</$tag>'.length;
          continue;
        }
      }
      pos++;
    }
    return tokens;
  }

  static int _findMatchingClose(String content, int start, String tag) {
    final openTag = '<$tag>';
    final closeTag = '</$tag>';
    var depth = 1;
    var pos = start;
    while (pos < content.length && depth > 0) {
      final nextOpen = content.indexOf(openTag, pos);
      final nextClose = content.indexOf(closeTag, pos);
      if (nextClose == -1) return -1;
      if (nextOpen != -1 && nextOpen < nextClose) {
        depth++;
        pos = nextOpen + openTag.length;
      } else {
        depth--;
        if (depth == 0) return nextClose;
        pos = nextClose + closeTag.length;
      }
    }
    return -1;
  }

  static bool _isWhitespace(String ch) =>
      ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r';

  /// 解析 AirPlay `/playback-info` 报文（XML 或二进制）为状态视图。
  static AirPlayPlaybackInfo parsePlaybackInfo(List<int> body,
          {String contentType = ''}) =>
      AirPlayPlaybackInfo.fromMap(parsePlist(body, contentType: contentType));
}

/// `/playback-info` 解析结果（dart_cast PlaybackInfo 子集）。
class AirPlayPlaybackInfo {
  const AirPlayPlaybackInfo({
    required this.duration,
    required this.position,
    required this.rate,
    required this.readyToPlay,
    required this.hasDuration,
  });

  factory AirPlayPlaybackInfo.fromMap(Map<String, dynamic> map) =>
      AirPlayPlaybackInfo(
        duration: (map['duration'] as num?)?.toDouble() ?? 0.0,
        position: (map['position'] as num?)?.toDouble() ?? 0.0,
        rate: (map['rate'] as num?)?.toDouble() ?? 0.0,
        readyToPlay: map['readyToPlay'] as bool? ?? false,
        // 接收端没在播时整个省略 duration 键（pyatv 以此判「播没播起来」）。
        hasDuration: map.containsKey('duration'),
      );

  /// 媒体总时长（秒；键缺失为 0）。
  final double duration;

  /// 当前播放位置（秒）。
  final double position;

  /// 播放速率（>0 播放中，0 暂停/未起播）。
  final double rate;

  /// 接收端是否已缓冲就绪。
  final bool readyToPlay;

  /// 报文里是否真的带了 `duration` 键。
  final bool hasDuration;

  /// 「已加载媒体」判据：readyToPlay / duration 键 / 非零位置任一成立。
  bool get loaded => readyToPlay || hasDuration || position > 0;

  @override
  String toString() =>
      'AirPlayPlaybackInfo(duration: $duration, position: $position, '
      'rate: $rate, readyToPlay: $readyToPlay, hasDuration: $hasDuration)';
}

/// XML plist 解析的内部 token。
class _Token {
  const _Token(this.tag, this.value);

  final String tag;
  final String? value;
}

/// Apple 二进制 plist（`bplist00`）解码器（移植 dart_cast `BinaryPlistDecoder`，
/// 只解码：int/real/bool/string(ASCII+UTF-16BE)/data/date/array/dict）。
class BinaryPlistDecoder {
  BinaryPlistDecoder._(this._data);

  final Uint8List _data;
  late final ByteData _byteData = ByteData.sublistView(_data);
  final Map<int, Object?> _decodedObjects = {};

  late int _offsetSize;
  late int _objectRefSize;
  late int _numObjects;
  late int _topObjectIndex;
  late int _offsetTableOffset;

  /// 解码二进制 plist；顶层必须是 dict，否则抛 ArgumentError。
  static Map<String, dynamic> decode(Uint8List data) {
    final result = BinaryPlistDecoder._(data)._decode();
    if (result is Map<String, dynamic>) return result;
    throw ArgumentError('二进制 plist 根对象不是 dict: ${result.runtimeType}');
  }

  /// 解码二进制 plist（顶层任意类型）。
  static Object? decodeAny(Uint8List data) =>
      BinaryPlistDecoder._(data)._decode();

  Object? _decode() {
    if (_data.length < 40) {
      throw ArgumentError('二进制 plist 过短: ${_data.length} bytes');
    }
    final header = ascii.decode(_data.sublist(0, 8), allowInvalid: true);
    if (header != 'bplist00') {
      throw ArgumentError('不是二进制 plist（头错误）: "$header"');
    }
    final trailerOffset = _data.length - 32;
    _offsetSize = _data[trailerOffset + 6];
    _objectRefSize = _data[trailerOffset + 7];
    _numObjects = _readUint64BE(trailerOffset + 8);
    _topObjectIndex = _readUint64BE(trailerOffset + 16);
    _offsetTableOffset = _readUint64BE(trailerOffset + 24);
    if (_numObjects == 0) {
      throw ArgumentError('二进制 plist 没有对象');
    }
    return _readObject(_topObjectIndex);
  }

  Object? _readObject(int objectIndex) {
    final cached = _decodedObjects[objectIndex];
    if (cached != null || _decodedObjects.containsKey(objectIndex)) {
      return cached;
    }
    final offset = _readOffsetTableEntry(objectIndex);
    final result = _readObjectAtOffset(offset);
    _decodedObjects[objectIndex] = result;
    return result;
  }

  int _readOffsetTableEntry(int objectIndex) =>
      _readUnsignedInt(_offsetTableOffset + objectIndex * _offsetSize, _offsetSize);

  Object? _readObjectAtOffset(int offset) {
    final marker = _data[offset];
    final objectType = (marker >> 4) & 0x0F;
    final objectInfo = marker & 0x0F;
    switch (objectType) {
      case 0x0: // null / bool / fill
        return switch (objectInfo) {
          0x8 => false,
          0x9 => true,
          _ => null,
        };
      case 0x1: // int
        return _readUnsignedInt(offset + 1, 1 << objectInfo);
      case 0x2: // real
        return _readReal(offset, objectInfo);
      case 0x3: // date（按 float64 读，AirPlay 不用但容错）
        return _byteData.getFloat64(offset + 1, Endian.big);
      case 0x4: // data
        final (count, dataStart) = _readSizeAndDataStart(offset, objectInfo);
        return Uint8List.fromList(
            _data.sublist(dataStart, dataStart + count));
      case 0x5: // ASCII string
        final (count, dataStart) = _readSizeAndDataStart(offset, objectInfo);
        return ascii.decode(_data.sublist(dataStart, dataStart + count),
            allowInvalid: true);
      case 0x6: // UTF-16 BE string
        final (count, dataStart) = _readSizeAndDataStart(offset, objectInfo);
        final codeUnits = <int>[
          for (var i = 0; i < count; i++)
            _byteData.getUint16(dataStart + i * 2, Endian.big),
        ];
        return String.fromCharCodes(codeUnits);
      case 0xA: // array
        final (count, refsStart) = _readSizeAndDataStart(offset, objectInfo);
        return [
          for (var i = 0; i < count; i++)
            _readObject(_readUnsignedInt(
                refsStart + i * _objectRefSize, _objectRefSize)),
        ];
      case 0xD: // dict
        final (count, refsStart) = _readSizeAndDataStart(offset, objectInfo);
        final valueRefsStart = refsStart + count * _objectRefSize;
        final result = <String, dynamic>{};
        for (var i = 0; i < count; i++) {
          final key = _readObject(_readUnsignedInt(
              refsStart + i * _objectRefSize, _objectRefSize));
          final value = _readObject(_readUnsignedInt(
              valueRefsStart + i * _objectRefSize, _objectRefSize));
          result[key.toString()] = value;
        }
        return result;
      default:
        throw ArgumentError(
            '不支持的二进制 plist 对象类型: 0x${objectType.toRadixString(16)}');
    }
  }

  double _readReal(int offset, int sizeExponent) {
    final byteCount = 1 << sizeExponent;
    if (byteCount == 4) {
      return _byteData.getFloat32(offset + 1, Endian.big);
    }
    if (byteCount == 8) {
      return _byteData.getFloat64(offset + 1, Endian.big);
    }
    throw ArgumentError('不支持的 real 长度: $byteCount bytes');
  }

  /// 读 marker 里的 size（0xF 时后跟一个 int 标记编码真实长度）。
  (int count, int dataStart) _readSizeAndDataStart(int offset, int sizeInfo) {
    if (sizeInfo < 0x0F) return (sizeInfo, offset + 1);
    final intMarker = _data[offset + 1];
    final intByteCount = 1 << (intMarker & 0x0F);
    final count = _readUnsignedInt(offset + 2, intByteCount);
    return (count, offset + 2 + intByteCount);
  }

  int _readUnsignedInt(int offset, int byteCount) {
    var value = 0;
    for (var i = 0; i < byteCount; i++) {
      value = (value << 8) | _data[offset + i];
    }
    return value;
  }

  int _readUint64BE(int offset) {
    final high = _byteData.getUint32(offset, Endian.big);
    final low = _byteData.getUint32(offset + 4, Endian.big);
    return (high << 32) | low;
  }
}
