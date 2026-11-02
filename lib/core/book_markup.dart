/// 中文站点页面字节 → 文本的**统一解码入口**。
///
/// 书源（legado / so-novel / 内置 Wenku8）与 js 宿主拿到的都是原始字节；中文站点里
/// GBK/GB2312/GB18030 仍占多数，无条件 `utf8.decode` 会整页乱码。收口在这里：
///
/// 1. BOM（UTF-8 / UTF-16LE / UTF-16BE）优先；
/// 2. 显式声明（HTTP `Content-Type` 的 charset、`<meta charset>`、
///    `<meta http-equiv=Content-Type>`、XML 声明）次之；
/// 3. 无声明时按**严格 UTF-8** 试解，失败落 GBK 系；
/// 4. 最后兜底 `utf8.decode(allowMalformed: true)`，并用 [DecodedMarkup.lossy]
///    诚实标注「可能乱码」，绝不静默当成正常文本。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

/// 一次解码的结果。
class DecodedMarkup {
  const DecodedMarkup({
    required this.text,
    required this.charset,
    required this.lossy,
  });

  /// 解码后的文本（已去 BOM）。
  final String text;

  /// 实际生效的字符集标签（`utf-8` / `gbk` / `utf-16le` / `utf-16be`）。
  final String charset;

  /// 是否发生了有损替换（出现 U+FFFD），调用方可提示「编码可能不对」。
  final bool lossy;

  @override
  String toString() => 'DecodedMarkup($charset, lossy=$lossy, ${text.length} chars)';
}

const String _utf8Label = 'utf-8';
const String _gbkLabel = 'gbk';
const String _utf16LeLabel = 'utf-16le';
const String _utf16BeLabel = 'utf-16be';

/// 解码响应体字节。
///
/// [contentType] 为 HTTP 响应头 `Content-Type`（可含 `charset=gbk`）；没有就当无声明。
DecodedMarkup decodeMarkupBytes(Uint8List bytes, {String? contentType}) {
  if (bytes.isEmpty) {
    return const DecodedMarkup(text: '', charset: _utf8Label, lossy: false);
  }

  // 1) BOM
  final bom = _bomOf(bytes);
  if (bom != null) {
    final (label, body) = bom;
    if (label == _utf8Label) {
      return _finish(utf8.decode(body, allowMalformed: true), label);
    }
    return _finish(_decodeUtf16(body, littleEndian: label == _utf16LeLabel), label);
  }

  // 2) 显式声明：HTTP 头 > 文档内 meta / XML 声明
  final declared = _charsetIn(contentType ?? '') ?? _charsetInMarkup(bytes);

  if (declared != null) {
    if (_isGbkFamily(declared)) {
      // GBK 页误标 utf-8 的情况罕见；声明了 GBK 就照 GBK 解，失败再落严格 UTF-8。
      final viaGbk = _tryGbk(bytes);
      if (viaGbk != null) return _finish(viaGbk, _gbkLabel);
      return _finish(utf8.decode(bytes, allowMalformed: true), _utf8Label);
    }
    if (_isUtf8Family(declared)) {
      try {
        return DecodedMarkup(
          text: utf8.decode(bytes),
          charset: _utf8Label,
          lossy: false,
        );
      } on FormatException {
        final viaGbk = _tryGbk(bytes);
        if (viaGbk != null) return _finish(viaGbk, _gbkLabel);
        return _finish(utf8.decode(bytes, allowMalformed: true), _utf8Label);
      }
    }
    // 其它字符集（big5/shift_jis…）本工程暂无解码器：按通用链继续，末尾如实标注有损。
  }

  // 3) 无声明：严格 UTF-8 优先（覆盖绝大多数现代站点）
  try {
    return DecodedMarkup(
      text: utf8.decode(bytes),
      charset: _utf8Label,
      lossy: false,
    );
  } on FormatException {
    // 4) GBK 系（中文老站点）
    final viaGbk = _tryGbk(bytes);
    if (viaGbk != null) return _finish(viaGbk, _gbkLabel);
  }

  // 5) 兜底：有损 UTF-8
  return _finish(utf8.decode(bytes, allowMalformed: true), _utf8Label);
}

/// 便捷入口：只要文本。
String decodeMarkupText(Uint8List bytes, {String? contentType}) =>
    decodeMarkupBytes(bytes, contentType: contentType).text;

/// 只在有需要时做 charset 嗅探（不触发解码）。
String? sniffMarkupCharset(Uint8List bytes, {String? contentType}) {
  if (bytes.isEmpty) return null;
  final bom = _bomOf(bytes);
  if (bom != null) return bom.$1;
  return _charsetIn(contentType ?? '') ?? _charsetInMarkup(bytes);
}

// ---------------------------------------------------------------------------
// 内部实现
// ---------------------------------------------------------------------------

DecodedMarkup _finish(String text, String charset) {
  final clean = _stripBomChar(text);
  return DecodedMarkup(
    text: clean,
    charset: charset,
    lossy: clean.contains('\uFFFD'),
  );
}

(String, Uint8List)? _bomOf(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return (_utf8Label, Uint8List.sublistView(bytes, 3));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return (_utf16LeLabel, Uint8List.sublistView(bytes, 2));
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return (_utf16BeLabel, Uint8List.sublistView(bytes, 2));
  }
  return null;
}

String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
  final units = <int>[];
  for (var i = 0; i + 1 < bytes.length; i += 2) {
    units.add(littleEndian
        ? bytes[i] | (bytes[i + 1] << 8)
        : (bytes[i] << 8) | bytes[i + 1]);
  }
  return String.fromCharCodes(units);
}

String _stripBomChar(String text) =>
    text.startsWith('\uFEFF') ? text.substring(1) : text;

String? _tryGbk(Uint8List bytes) {
  try {
    return gbk.decode(bytes, allowMalformed: true);
  } catch (_) {
    return null;
  }
}

/// 从 `text/html; charset=gbk` 一类字符串里取 charset。
String? _charsetIn(String raw) {
  if (raw.isEmpty) return null;
  final m = RegExp(r'charset\s*=\s*["\x27]?\s*([a-zA-Z0-9_\-]+)',
          caseSensitive: false)
      .firstMatch(raw);
  final v = m?.group(1)?.toLowerCase();
  if (v == null || v.isEmpty) return null;
  return v;
}

/// 在文档前 8KB 里找 charset 声明（meta / XML）。
///
/// 用 latin1 把字节映成单字符再匹配：声明本身是 ASCII，不受正文编码影响。
String? _charsetInMarkup(Uint8List bytes) {
  final head = latin1.decode(
    Uint8List.sublistView(bytes, 0, bytes.length < 8192 ? bytes.length : 8192),
    allowInvalid: true,
  );
  // <meta charset="gbk"> / <meta charset='gbk'>
  final direct = RegExp(r'<meta[^>]+charset\s*=\s*["\x27]?\s*([a-zA-Z0-9_\-]+)',
          caseSensitive: false)
      .firstMatch(head);
  final fromMeta = direct?.group(1);
  if (fromMeta != null && fromMeta.isNotEmpty) return fromMeta.toLowerCase();
  // <?xml version="1.0" encoding="gbk"?>
  final xml = RegExp(r'<\?xml[^>]+encoding\s*=\s*["\x27]([a-zA-Z0-9_\-]+)',
          caseSensitive: false)
      .firstMatch(head);
  final fromXml = xml?.group(1);
  if (fromXml != null && fromXml.isNotEmpty) return fromXml.toLowerCase();
  // http-equiv 形态没有 charset= 之外的信息，_charsetIn 已能覆盖，这里再兜一次
  return null;
}

bool _isGbkFamily(String cs) =>
    cs == 'gbk' ||
    cs == 'gb2312' ||
    cs == 'gb18030' ||
    cs == 'x-gbk' ||
    cs == 'cp936' ||
    cs == 'gb_2312-80';

bool _isUtf8Family(String cs) => cs == 'utf-8' || cs == 'utf8';
