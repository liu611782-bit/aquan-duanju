import 'dart:convert';

/// DIDL-Lite 元数据变体。
///
/// 严格校验的接收端（WMP / QQLiveTV / Hisilicon / HappyCast）要完整 DIDL；
/// 宽松设备（AirPin / WaxRainPlayer）吃最小 DIDL；部分国产盒子只接受空
/// metadata。三种形态按梯度降级，成功形态由 `CastRecipe` 记住。
enum DidlVariant { full, minimal, none }

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

  /// 预检拿到设备 Sink 的 mime 段后覆盖它（配方字段 `protocolMime`）。
  DidlRequest copyWith({String? mimeType}) => DidlRequest(
        uri: uri,
        title: title,
        mimeType: mimeType ?? this.mimeType,
        duration: duration,
        sizeBytes: sizeBytes,
        live: live,
        subtitleUri: subtitleUri,
        headers: headers,
      );
}

const String _didlFlags =
    'DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';
const String _didlFlagsLive =
    'DLNA.ORG_OP=00;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000';

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
/// 不能经 Duration 重格式化后丢掉精度。新调用点只传 [req] 与 [variant]。
String buildDidl(
  DidlRequest req,
  DidlVariant variant, {
  String? durationText,
  String itemClass = 'object.item.videoItem',
}) {
  switch (variant) {
    case DidlVariant.none:
      return '';
    case DidlVariant.minimal:
      return _buildMinimal(req, durationText, itemClass);
    case DidlVariant.full:
      return _buildFull(req, durationText ?? _formatDuration(req.duration));
  }
}

/// `CurrentURIMetaData` 直接可用的文本：`none` 返回空串，其余用 CDATA 包裹。
///
/// CDATA 内是**已经转义过一次**的完整 DIDL；`buildEnvelope` 会识别 CDATA
/// 并跳过二次转义，否则接收端拿到的是 `&lt;DIDL-Lite…` 字面量。
String buildDidlMetadata(DidlRequest req, DidlVariant variant) =>
    wrapDidlCdata(buildDidl(req, variant));

/// 把 DIDL 包成 CDATA 文本节点；空串保持空（空 metadata 变体）。
String wrapDidlCdata(String didl) {
  if (didl.isEmpty) return '';
  // DIDL 内部已把 `>` 转义成 `&gt;`，理论上不会出现 `]]>`；仍按 XML 规范
  // 拆开，防止 headers JSON 里带进来的意外序列截断 CDATA。
  return '<![CDATA[${didl.replaceAll(']]>', ']]]]><![CDATA[>')}]]>';
}

String _buildMinimal(DidlRequest req, String? durationText, String itemClass) {
  final dur = durationText ?? _formatDuration(req.duration);
  final resAttrs = dur != null && dur.isNotEmpty
      ? ' duration="${_escapeXml(dur)}"'
      : '';
  final resBody = _resBody(req.uri);
  final subtitle = req.subtitleUri == null
      ? ''
      : '\n    <sec:SubtitleUri>${_escapeXml(req.subtitleUri.toString())}</sec:SubtitleUri>';
  return '''${_didlOpen()}
  <item id="aquan-1" parentID="0" restricted="1">
    <dc:title>${_escapeXml(req.title)}</dc:title>
    <upnp:class>${_escapeXml(itemClass)}</upnp:class>
    <res protocolInfo="http-get:*:*/*:*"$resAttrs>$resBody</res>$subtitle
  </item>
</DIDL-Lite>''';
}

String _buildFull(DidlRequest req, String? durationText) {
  final mime = req.mimeType.trim().isEmpty ? 'video/mp4' : req.mimeType.trim();
  final flags = req.live ? _didlFlagsLive : _didlFlags;
  final attrs = StringBuffer(
      ' protocolInfo="${_escapeXml('http-get:*:$mime:$flags')}"');
  if (durationText != null && durationText.isNotEmpty) {
    attrs.write(' duration="${_escapeXml(durationText)}"');
  }
  if (req.sizeBytes != null && req.sizeBytes! > 0) {
    attrs.write(' size="${req.sizeBytes!}"');
  }
  final desc = _headerDescription(req.headers);
  final description = desc == null
      ? ''
      : '\n    <dc:description>${_escapeXml(desc)}</dc:description>';
  final sub = req.subtitleUri;
  final subtitleTags = sub == null
      ? ''
      : '\n    <sec:SubtitleUri>${_escapeXml(sub.toString())}</sec:SubtitleUri>'
          '\n    <sec:CaptionInfoEx sec:type="srt">${_escapeXml(sub.toString())}</sec:CaptionInfoEx>'
          '\n    <res protocolInfo="http-get:*:text/srt:*">${_escapeXml(sub.toString())}</res>';
  return '''${_didlOpen()}
  <item id="aquan-1" parentID="0" restricted="1">
    <dc:title>${_escapeXml(req.title)}</dc:title>
    <upnp:class>${_escapeXml(_upnpClass(mime))}</upnp:class>$description
    <res$attrs>${_escapeXml(req.uri.toString())}</res>$subtitleTags
  </item>
</DIDL-Lite>''';
}

String _resBody(Uri uri) {
  final text = uri.toString();
  return text.isEmpty ? '' : _escapeXml(text);
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

String _upnpClass(String mime) {
  final m = mime.toLowerCase();
  if (m.startsWith('audio/')) return 'object.item.audioItem.musicTrack';
  if (m.startsWith('image/')) return 'object.item.imageItem.photo';
  return 'object.item.videoItem.movie';
}

String? _formatDuration(Duration? d) {
  if (d == null || d <= Duration.zero) return null;
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

/// 全部文本统一转义一次（CDATA 由 SOAP 信封侧避免二次转义）。
String _escapeXml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');
