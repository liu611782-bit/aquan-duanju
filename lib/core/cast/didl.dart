import 'dart:convert';

import 'cast_media_type.dart';

/// DIDL-Lite 元数据变体（v2，取消空 metadata）。
///
/// - [full]：完整形态（`dc:description` 防盗链头、duration、size、字幕三件套）；
/// - [compact]：去掉 `dc:description`/duration/size，保留 `dc:title` +
///   `upnp:class` + `<res>`（对扩展字段敏感的设备）；
/// - [compatEscaped]：同 full，但 `"`/`&` 不转义（go2tv soapbuilders.go
///   legacy-compat：部分 Samsung 渲染器拒绝完全转义的嵌套 DIDL）。
///
/// **没有 none 变体**：空 metadata 对 DroidDLNA（崩）与 puppy-store-cast
/// （402）是致命动作；不认扩展字段的设备降级方向是 compact（仍合法完整）。
/// 三种变体恒含 `dc:title` 与 `upnp:class`，`CurrentURIMetaData` 恒非空。
enum DidlVariant { full, compact, compatEscaped }

/// `<res protocolInfo>` 第 4 段的模板旋钮（recipe 字段，design §4.3）。
enum DidlProtocolInfoTemplate {
  /// `http-get:*:<mime>:DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=0170…`
  /// （现状默认；live 用 OP=00）。
  standard,

  /// `http-get:*:<mime>:*`（极简，部分盒子只认这个）。
  bare,

  /// `http-get:*:*:*`（最后兜底）。
  wildcard,

  /// `DLNA.ORG_PN=<PN>;…`（海思/腾讯系按 PN 匹配；未知容器回落 standard）。
  withPn,

  /// 原样复用设备 Sink 同容器条目的第 4 段（castor didl.go：照抄设备自己
  /// 的写法比自造 PN 表稳）；无同容器条目回落 standard。
  sinkEntry,

  /// `DLNA.ORG_OP=11`（时间+字节 seek）。**仅限本机服务该路由真答 206 时**
  /// 由调用方选择——谎报 byte-seek 会让部分电视一 seek 就停播（dart_cast
  /// TCL 实证）；梯度不会自动选中它。
  op11,
}

/// 字幕标签投送模式（recipe 字段 `subtitleMode`）。
enum CastSubtitleMode {
  /// 不写任何字幕标签（源无字幕或设备见 sec: 标签就出错的场景）。
  none,

  /// 只写 `<sec:CaptionInfoEx>`（Samsung 系优先识别的标签）。
  captionInfoEx,

  /// 三件套全量：`sec:CaptionInfo` + `sec:CaptionInfoEx` +
  /// 独立 `<res protocolInfo="http-get:*:text/srt:*">`（go2tv 做法）。
  both,
}

/// 生成 DIDL 所需的媒体信息。
///
/// [uri] 与 SOAP 的 `CurrentURI` 必须是同一个地址；[headers] 只用于
/// `dc:description`（凭据类键会被过滤，见 [_sensitiveHeaderKey]）。
class DidlRequest {
  const DidlRequest({
    required this.uri,
    this.title = '',
    this.mimeType = 'video/mp4',
    this.duration,
    this.sizeBytes,
    this.live = false,
    this.subtitleUri,
    this.headers = const <String, String>{},
  });

  final Uri uri;
  final String title;
  final String mimeType;
  final Duration? duration;
  final int? sizeBytes;
  final bool live;
  final Uri? subtitleUri;
  final Map<String, String> headers;
}

const String _didlFlags =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
const String _didlFlagsLive =
    'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
const String _didlFlagsOp11 =
    'DLNA.ORG_OP=11;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

/// 头部名含这些片段的一律不写进 `dc:description`：投到局域网等于把凭据
/// 明文广播给同网段所有设备。
final RegExp _sensitiveHeaderKey = RegExp(
  r'cookie|authorization|auth|token|secret|credential|password|api[_-]?key|signature|sign',
  caseSensitive: false,
);

String _didlOpen() => '''
<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/"
           xmlns:dc="http://purl.org/dc/elements/1.1/"
           xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"
           xmlns:sec="http://www.sec.co.kr/"
           xmlns:pv="http://www.pv.com/pvns/">''';

/// 生成 DIDL-Lite 文本。
///
/// [durationText] / [itemClass] 只是为 `buildDidlLite` 的旧签名保留的兼容口：
/// 旧调用点传的是原始 UPnP 时长串（如 `0:02:15.000`）与自定义 class，
/// 不能经 Duration 重格式化后丢掉精度。[itemClass] 为空时按 mime 推导
/// 两段式 class（`object.item.videoItem` / audioItem / imageItem）。
///
/// 其余参数是 recipe 旋钮（M2）：[template] 选 protocolInfo 第 4 段形状；
/// [sinkFourth] 是 [DidlProtocolInfoTemplate.sinkEntry] 用的 Sink 第 4 段
/// （null 且选中该模板时回落 standard）；[subtitleMode] 控制字幕标签；
/// [sendDcDescription] 关掉 `dc:description` 整段。
String buildDidl(
  DidlRequest req,
  DidlVariant variant, {
  String? durationText,
  String itemClass = '',
  DidlProtocolInfoTemplate template = DidlProtocolInfoTemplate.standard,
  String? sinkFourth,
  CastSubtitleMode subtitleMode = CastSubtitleMode.both,
  bool sendDcDescription = true,
}) {
  final compat = variant == DidlVariant.compatEscaped;
  final mime = req.mimeType.trim().isEmpty ? 'video/mp4' : req.mimeType.trim();
  final cls = itemClass.isEmpty ? _upnpClass(mime) : itemClass;

  final buffer = StringBuffer('${_didlOpen()}\n');
  buffer.write('  <item id="aquan-1" parentID="0" restricted="1">\n');
  buffer.write('    <dc:title>${_escapeXml(req.title, compat)}</dc:title>\n');
  buffer.write('    <upnp:class>${_escapeXml(cls, compat)}</upnp:class>\n');

  if (variant == DidlVariant.full || compat) {
    final desc = sendDcDescription ? _headerDescription(req.headers) : null;
    if (desc != null) {
      buffer.write(
          '    <dc:description>${_escapeXml(desc, compat)}</dc:description>\n');
    }
  }

  final duration = durationText ?? _formatDuration(req.duration);
  final attrs = StringBuffer(
      ' protocolInfo="${_escapeXml(_protocolInfo(req, template, sinkFourth), compat)}"');
  // duration/size 只有真实值才写（AC-27：写错比不写更糟）；compact 一律不带。
  if (variant != DidlVariant.compact && duration != null && duration.isNotEmpty) {
    attrs.write(' duration="${_escapeXml(duration, compat)}"');
  }
  if (variant != DidlVariant.compact &&
      req.sizeBytes != null &&
      req.sizeBytes! > 0) {
    attrs.write(' size="${req.sizeBytes!}"');
  }
  buffer.write('    <res$attrs>${_resBody(req.uri, compat)}</res>\n');

  final subTags = _subtitleTags(req.subtitleUri, subtitleMode, compat);
  if (subTags.isNotEmpty) buffer.write(subTags);

  buffer.write('  </item>\n</DIDL-Lite>');
  return buffer.toString();
}

/// 字幕三件套（full/compact 都按 [subtitleMode] 投送；字幕是功能字段，
/// 不是装饰扩展——compact 设备同样需要字幕，由 [CastSubtitleMode.none]
/// 显式关闭）。
String _subtitleTags(
  Uri? subtitleUri,
  CastSubtitleMode subtitleMode,
  bool compat,
) {
  final sub = subtitleUri;
  if (sub == null) return '';
  final url = _escapeXml(sub.toString(), compat);
  switch (subtitleMode) {
    case CastSubtitleMode.none:
      return '';
    case CastSubtitleMode.captionInfoEx:
      return '    <sec:CaptionInfoEx sec:type="srt">$url</sec:CaptionInfoEx>\n';
    case CastSubtitleMode.both:
      return '    <sec:CaptionInfo sec:type="srt">$url</sec:CaptionInfo>\n'
          '    <sec:CaptionInfoEx sec:type="srt">$url</sec:CaptionInfoEx>\n'
          '    <res protocolInfo="http-get:*:text/srt:*">$url</res>\n';
  }
}

/// protocolInfo 第 4 段按模板生成。
String _protocolInfo(
  DidlRequest req,
  DidlProtocolInfoTemplate template,
  String? sinkFourth,
) {
  final mime = req.mimeType.trim().isEmpty ? 'video/mp4' : req.mimeType.trim();
  final flags = req.live ? _didlFlagsLive : _didlFlags;
  switch (template) {
    case DidlProtocolInfoTemplate.standard:
      return 'http-get:*:$mime:$flags';
    case DidlProtocolInfoTemplate.bare:
      return 'http-get:*:$mime:*';
    case DidlProtocolInfoTemplate.wildcard:
      return 'http-get:*:*:*';
    case DidlProtocolInfoTemplate.withPn:
      final pn = _dlnaPnForMime(mime);
      if (pn == null) return 'http-get:*:$mime:$flags';
      final op = req.live ? _didlFlagsLive : _didlFlags;
      return 'http-get:*:$mime:DLNA.ORG_PN=$pn;$op';
    case DidlProtocolInfoTemplate.sinkEntry:
      // 原样复用设备 Sink 同容器条目第 4 段（含其 PN/OP/FLAGS 拼写）；
      // Sink 无同容器条目时回落 standard。
      final fourth = (sinkFourth != null && sinkFourth.isNotEmpty)
          ? sinkFourth
          : flags;
      return 'http-get:*:$mime:$fourth';
    case DidlProtocolInfoTemplate.op11:
      return 'http-get:*:$mime:$_didlFlagsOp11';
  }
}

/// 常见容器的 DLNA.ORG_PN 候选（海思/腾讯系实测；设计 §4.3）。
/// 未知容器返回 null（调用方回落 standard——自造 PN 比不带更糟）。
String? _dlnaPnForMime(String mime) {
  switch (mime.toLowerCase()) {
    case 'video/mp4':
      return 'AVC_MP4_MP_HD_AAC';
    case 'video/mp2t':
    case 'video/vnd.dlna.mpeg-tts':
      return 'MPEG_TS_HD_NA';
    case 'audio/mpeg':
      return 'MP3';
    case 'image/jpeg':
      return 'JPEG_SM';
    default:
      return null;
  }
}

/// Sink 里同容器条目的 protocolInfo 第 4 段（[DidlProtocolInfoTemplate.sinkEntry]
/// 用；castor didl.go 思路）。
///
/// 先精确 mime 匹配，再按别名组匹配（M1 拼写选择：我们的 `video/mp2t` 可
/// 对上设备的 `video/vnd.dlna.mpeg-tts`）；无同容器条目返回 null（回落
/// standard）。条目第 4 段**逐字**复用，含设备自己的 PN/OP/FLAGS 拼写。
String? sinkEntryFourthSegment(Iterable<String> sink, String mime) {
  final spelled = preferSinkSpelling(mime, sink).toLowerCase();
  String? fourth;
  for (final entry in sink) {
    final parts = entry.split(':');
    if (parts.length < 3) continue;
    if (parts[2].trim().toLowerCase() != spelled) continue;
    if (parts.length >= 4) {
      fourth = parts.sublist(3).join(':');
      break;
    }
  }
  return fourth;
}

/// `CurrentURIMetaData` 直接可用的文本：CDATA 包裹（恒非空——没有空
/// metadata 变体）。
///
/// CDATA 内是**已经转义过一次**的完整 DIDL；`buildEnvelope` 会识别 CDATA
/// 并跳过二次转义，否则接收端拿到的是 `&lt;DIDL-Lite…` 字面量。
String buildDidlMetadata(
  DidlRequest req,
  DidlVariant variant, {
  DidlProtocolInfoTemplate template = DidlProtocolInfoTemplate.standard,
  String? sinkFourth,
  CastSubtitleMode subtitleMode = CastSubtitleMode.both,
  bool sendDcDescription = true,
}) =>
    wrapDidlCdata(buildDidl(
      req,
      variant,
      template: template,
      sinkFourth: sinkFourth,
      subtitleMode: subtitleMode,
      sendDcDescription: sendDcDescription,
    ));

/// 把 DIDL 包成 CDATA 文本节点。
String wrapDidlCdata(String didl) {
  if (didl.isEmpty) return '';
  // DIDL 内部已把 `>` 转义成 `&gt;`，理论上不会出现 `]]>`；仍按 XML 规范
  // 拆开，防止 headers JSON 里带进来的意外序列截断 CDATA。
  return '<![CDATA[${didl.replaceAll(']]>', ']]]]><![CDATA[>')}]]>';
}

String _resBody(Uri uri, bool compat) {
  final text = uri.toString();
  return text.isEmpty ? '' : _escapeXml(text, compat);
}

/// 只保留防盗链所需的非凭据头，序列化成 JSON 塞进 `dc:description`
/// （webhtv / DuoTV 思路：让接收端自带 Referer/UA 拉流）。
String? _headerDescription(Map<String, String> headers) {
  if (headers.isEmpty) return null;
  final safe = <String, String>{};
  headers.forEach((k, v) {
    if (_sensitiveHeaderKey.hasMatch(k)) return;
    safe[k] = v;
  });
  if (safe.isEmpty) return null;
  return jsonEncode(safe);
}

/// 两段式 `upnp:class`（dms / dlna-dart 实践：三段式 `.movie` 等细分
/// 反而让部分接收端不识别）。
String _upnpClass(String mime) {
  final m = mime.toLowerCase();
  if (m.startsWith('audio/')) return 'object.item.audioItem';
  if (m.startsWith('image/')) return 'object.item.imageItem';
  return 'object.item.videoItem';
}

String? _formatDuration(Duration? d) {
  if (d == null || d <= Duration.zero) return null;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// 文本转义。[compat] = true 时 `&`/`"`/`'` 保持原样、只转义 `<`/`>`
/// （go2tv soapbuilders.go applyLegacyDIDLCompatToCurrentURI：部分 Samsung
/// 渲染器拒绝 `&quot;`/`&amp;` 双转义形态；经 CDATA 包裹传输，信封本身
/// 仍合法）。
String _escapeXml(String s, bool compat) {
  if (compat) {
    return s.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
  }
  return s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
}
