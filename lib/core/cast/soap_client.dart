import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 'cast_diagnostics.dart';

/// UPnP SOAP 控制客户端（AVTransport / RenderingControl）。
///
/// 兼容经验（MiracastReceiver 服务端反推 + CineFlow 客户端实践）：
/// - `SOAPACTION` 头恒为 `"urn:<serviceType>#<Action>"`（v2 起无条件带
///   双引号：cling 系接收端无条件剥首尾引号，不带引号必 401）；
/// - 响应值解析要多模式兜底：标准响应元素、任意命名空间前缀、CDATA；
/// - 时间格式统一按 `H:MM:SS(.frac)` 解析，容错空串/非数；
/// - 每个 action 4s 超时；**重试收窄（AC-26）**：确定性 fault 与 4xx 拒绝
///   绝不重试（恰 1 次请求），仅超时/传输类异常与无 fault 的 5xx 重试一次
///   （dart_cast dlna_controller：设备会静默关闭 keep-alive 连接，首写
///   落在已废弃 socket 上，换新连接重试是标准缓解）。
class SoapClient {
  SoapClient({http.Client? client, this.timeout = const Duration(seconds: 4)})
      : _client = client ?? http.Client();

  final http.Client _client;
  final Duration timeout;

  /// 执行一个 SOAP action，返回「返回值名 → 值」；失败抛 [SoapException]。
  ///
  /// [serviceType] 同时决定信封的 `xmlns:u` 与 SOAPACTION 头的 URN——两者
  /// 必须精确等于设备宣告的 serviceType（严格接收端校验两者一致）。
  ///
  /// [mPost] = true → 直接发 M-POST（记住了 405 的设备，省一次往返）。
  ///
  /// 重试语义（AC-26）：带 faultCode 的 UPnP fault（401/402/714 等）与
  /// 4xx 拒绝直接上抛（恰 1 次请求，配方链不白烧往返）；仅「无 fault 的
  /// 超时/传输类异常」与「无 fault 的 5xx」重试一次。本端发送的所有动作
  /// 都可安全重复：Set 同一 URI 两次结果不变，Play/Pause/Stop 重复是
  /// no-op，Seek 同一目标两次位置相同，Get* 纯读。
  Future<Map<String, String>> sendAction(
    String controlUrl,
    String serviceType,
    String action,
    Map<String, String> args, {
    bool mPost = false,
  }) async {
    final body = buildEnvelope(serviceType, action, args);
    Future<Map<String, String>> once() => _send(
          controlUrl,
          serviceType,
          action,
          body,
          mPost: mPost,
        );
    try {
      return await once();
    } on SoapException catch (e) {
      // 重试收窄：确定性失败不重试，避免配方链每个失败变体实花 2 次往返
      // 把 12s 预算提前烧穿。
      if (!e.transient) rethrow;
      return once();
    }
  }

  Future<Map<String, String>> _send(
    String controlUrl,
    String serviceType,
    String action,
    String body, {
    bool mPost = false,
  }) async {
    final uri = Uri.tryParse(controlUrl);
    if (uri == null || !uri.hasScheme) {
      _recordTrace(action: action, headers: const {}, body: body,
          error: '非法 controlUrl');
      throw SoapException('非法 controlUrl: $controlUrl');
    }
    // v2 起 SOAPACTION 恒带双引号、恒用大写头名（不再可配置）。
    final actionValue = '"$serviceType#$action"';
    final postHeaders = <String, String>{
      'Content-Type': 'text/xml; charset="utf-8"',
      'SOAPACTION': actionValue,
    };
    final mPostHeaders = <String, String>{
      'Content-Type': 'text/xml; charset="utf-8"',
      'MAN': '"http://schemas.xmlsoap.org/soap/envelope/"; ns=01',
      '01-SOAPACTION': actionValue,
    };
    final traceHeaders = mPost ? mPostHeaders : postHeaders;
    http.Response res;
    try {
      if (mPost) {
        // 配方记住该设备只吃 M-POST：直接发，若回 405 再退回普通 POST。
        // 逐跳头本就未设置，无需剔除。
        res = await _sendRaw('M-POST', uri, mPostHeaders, body);
        if (res.statusCode == 405) {
          res = await _client
              .post(uri, headers: postHeaders, body: body)
              .timeout(timeout);
        }
      } else {
        res = await _client
            .post(uri, headers: postHeaders, body: body)
            .timeout(timeout);
        if (res.statusCode == 405) {
          // 405 Method Not Allowed → 设备强制要求 M-POST（UPnP 1.1 规范动作，
          // go2tv 实机兼容蓝本）；SOAPACTION 改为 MAN 命名空间形式。
          res = await _sendRaw('M-POST', uri, mPostHeaders, body);
        }
      }
    } on TimeoutException {
      _recordTrace(action: action, headers: traceHeaders, body: body,
          error: '超时（${timeout.inSeconds}s）');
      throw SoapException('$action 超时', transient: true);
    } catch (e) {
      _recordTrace(action: action, headers: traceHeaders, body: body,
          error: '$e');
      // SocketException / ClientException（含「连接被设备静默关闭」）等
      // 传输类异常：标记 transient，由 sendAction 决定是否重试。
      throw SoapException('$action 请求失败: $e', transient: true);
    }
    // 部分设备对可选动作（Seek/音量）返回 401/501：调用方按 faultCode 处理。
    final fault = parseSoapFault(res.body);
    _recordTrace(
      action: action,
      headers: traceHeaders,
      body: body,
      res: res,
      fault: fault,
    );
    if (res.statusCode >= 400 || fault != null) {
      throw SoapException(
        '$action 失败 HTTP ${res.statusCode}',
        faultCode: fault?.$1,
        faultDescription: fault?.$2,
        // 无 fault 的 5xx 视为设备偶发故障（可重试）；4xx 与带 fault 的
        // 响应都是确定性拒绝（重试只会再失败一次）。
        transient: fault == null && res.statusCode >= 500,
      );
    }
    final values = parseSoapResponse(res.body, action);
    return values;
  }

  Future<http.Response> _sendRaw(String method, Uri uri,
      Map<String, String> headers, String body) async {
    final req = http.Request(method, uri)
      ..headers.addAll(headers)
      ..body = body;
    final streamed = await _client.send(req).timeout(timeout);
    return http.Response.fromStream(streamed).timeout(timeout);
  }

  /// SOAP 诊断埋点（M0 纯采集）：请求头/请求体/HTTP 码/响应体/fault。
  ///
  /// [recordSoap] 自身吞异常，这里无需再包 try/catch；埋点不改变任何协议行为。
  void _recordTrace({
    required String action,
    required Map<String, String> headers,
    required String body,
    http.Response? res,
    (String?, String?)? fault,
    String? error,
  }) {
    CastDiagnostics.instance.recordSoap(SoapTrace(
      action: action,
      requestHeaders: headers,
      requestBody: body,
      httpStatus: res?.statusCode ?? 0,
      responseBody: res?.body ?? '',
      faultCode: fault?.$1,
      faultDescription: fault?.$2,
      error: error,
    ));
  }

  void close() => _client.close();
}

class SoapException implements Exception {
  const SoapException(this.message,
      {this.faultCode, this.faultDescription, this.transient = false});
  final String message;
  final String? faultCode;
  final String? faultDescription;

  /// 是否属于「偶发性」失败（超时/传输类异常/无 fault 的 5xx）——仅这类
  /// 失败允许在 [SoapClient.sendAction] 内重试一次（AC-26 重试收窄）。
  final bool transient;

  @override
  String toString() => faultCode == null
      ? message
      : '$message ($faultCode${faultDescription == null ? '' : ': $faultDescription'})';
}

/// SOAP 信封（参数顺序按 UPnP 服务描述；部分设备校验严格）。
String buildEnvelope(
    String serviceType, String action, Map<String, String> args) {
  final buffer = StringBuffer();
  buffer.write('<?xml version="1.0" encoding="utf-8"?>\n'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
      '<s:Body><u:$action xmlns:u="$serviceType">');
  args.forEach((name, value) {
    // CurrentURIMetaData 是整段 DIDL 的 CDATA 文本节点：内部已转义过一次，
    // 这里再 _xmlEscape 会把 `<![CDATA[` 变成字面量 `&lt;![CDATA[`，
    // 接收端拿到的是标签文本而不是 XML（双重转义）。
    final encoded = _isCdataWrapped(value) ? value : _xmlEscape(value);
    buffer.write('<$name>$encoded</$name>');
  });
  buffer.write('</u:$action></s:Body></s:Envelope>');
  return buffer.toString();
}

bool _isCdataWrapped(String s) =>
    s.startsWith('<![CDATA[') && s.endsWith(']]>');

/// 解析 `<u:ActionResponse>` 返回值；多模式兜底：
/// 1) 标准响应元素子元素；2) 任意命名空间前缀下的同 localName 元素；
/// 3) 兜底正则 `<TagName>value</TagName>`（CDATA 自动被 xml 包展开）。
Map<String, String> parseSoapResponse(String body, String action) {
  final out = <String, String>{};
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    doc = null;
  }
  if (doc != null) {
    XmlElement? response;
    for (final e in doc.rootElement.descendantElements) {
      if (e.name.local == '${action}Response') {
        response = e;
        break;
      }
    }
    if (response != null) {
      for (final child in response.childElements) {
        out[child.name.local] = child.innerText.trim();
      }
      if (out.isNotEmpty) return out;
    }
    // 没有响应元素（有的设备直接把返回值散在 Body 里）：抓常见返回字段。
    for (final e in doc.rootElement.descendantElements) {
      final local = e.name.local;
      if (_knownResultFields.contains(local) && !out.containsKey(local)) {
        out[local] = e.innerText.trim();
      }
    }
    if (out.isNotEmpty) return out;
  }
  // 正则兜底（响应可能是非法 XML）。
  for (final field in _knownResultFields) {
    final m = RegExp('<(?:[A-Za-z0-9]+:)?$field>(.*?)</(?:[A-Za-z0-9]+:)?$field>',
            dotAll: true)
        .firstMatch(body);
    if (m != null) out[field] = m.group(1)!.trim();
  }
  return out;
}

const Set<String> _knownResultFields = {
  'CurrentTransportState',
  'CurrentTransportStatus',
  'CurrentSpeed',
  'Track',
  'TrackDuration',
  'TrackMetaData',
  'TrackURI',
  // GetMediaInfo.CurrentURI：Play 门控超时后的归属校验（防止把电视上
  // 残留的旧播放误判成本次投屏成功，castor session.go 思路）。
  'CurrentURI',
  'RelTime',
  'AbsTime',
  'CurrentVolume',
  'CurrentMute',
  'rcs:CurrentVolume',
};

/// (errorCode, errorDescription) 或 null。
(String?, String?)? parseSoapFault(String body) {
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(body);
  } catch (_) {
    final code = RegExp('<faultcode>(.*?)</faultcode>', dotAll: true)
        .firstMatch(body)
        ?.group(1);
    final desc = RegExp('<faultstring>(.*?)</faultstring>', dotAll: true)
        .firstMatch(body)
        ?.group(1);
    return code == null && desc == null ? null : (code, desc);
  }
  for (final e in [doc.rootElement, ...doc.rootElement.descendantElements]) {
    if (e.name.local == 'Fault' || e.name.local == 'fault') {
      String? code;
      String? desc;
      for (final c in e.descendantElements) {
        // SOAP 1.1 用 faultcode/faultstring，1.2 用 code/value 与 string；
        // UPnP 设备两者都有，取到即用。
        if (c.name.local == 'faultcode' || c.name.local == 'code') {
          code ??= c.innerText.trim();
        }
        if (c.name.local == 'faultstring' || c.name.local == 'string') {
          desc ??= c.innerText.trim();
        }
        // UPnP errorCode 数字也带上，方便识别 401/501/710。
        if (c.name.local == 'errorCode') {
          desc ??= 'errorCode ${c.innerText.trim()}';
        }
      }
      return (code, desc);
    }
  }
  return null;
}

/// `H:MM:SS(.frac)` / `MM:SS` → Duration；解析失败返回 null。
Duration? parseUpnpTime(String raw) {
  final text = raw.trim();
  if (text.isEmpty || text == 'NOT_IMPLEMENTED') return null;
  final parts = text.split(':');
  if (parts.length < 2 || parts.length > 3) return null;
  final h = parts.length == 3 ? int.tryParse(parts[0]) ?? 0 : 0;
  final m = int.tryParse(parts[parts.length - 2]);
  final secParts = parts.last.split('.');
  final s = int.tryParse(secParts.first);
  if (m == null || s == null) return null;
  var ms = 0;
  if (secParts.length == 2) {
    final frac = secParts[1].padRight(3, '0').substring(0, 3);
    ms = int.tryParse(frac) ?? 0;
  }
  return Duration(hours: h, minutes: m, seconds: s, milliseconds: ms);
}

/// Duration → `H:MM:SS`。
String formatUpnpTime(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$h:$m:$s';
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');
