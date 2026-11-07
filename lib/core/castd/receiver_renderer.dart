/// AVT/RCS/CM 动作分发 + 状态机 + fault（蓝本 DlnaRenderer.kt / DlnaState.kt /
/// Soap.kt 语义移植）。
///
/// fault 码按 design.md §4 表（与蓝本的 701/711/714 口径不同，以设计为准）：
/// SetAVTransportURI 无 URI → 402；Play/Pause/GetMediaInfo 无 URI → 710；
/// Seek 不支持的 Unit → 401、非法 Target → 710；未知动作 → 401；
/// SetVolume 越界 → 402。引擎故障（load/play 抛异常）不是协议错误，
/// 不翻译成 fault，由 HTTP 层兜 500 + ErrorLog。
library;

import 'package:xml/xml.dart';

import 'receiver_descriptions.dart';
import 'receiver_player_adapter.dart';

/// UPnP SOAP fault（蓝本 Soap.Fault）。
class ReceiverFault implements Exception {
  const ReceiverFault(this.code, this.description);

  final int code;
  final String description;

  @override
  String toString() => 'ReceiverFault($code, $description)';
}

/// 解析出的 SOAP 动作调用（动作名 + 参数）。
class SoapActionRequest {
  const SoapActionRequest(this.name, this.args);

  final String name;
  final Map<String, String> args;
}

/// SetAVTransportURI 成功后的会话事件（控制器转上层会话显示）。
class ReceiverMediaOpened {
  const ReceiverMediaOpened({
    required this.url,
    required this.title,
    required this.senderAddress,
    required this.senderUserAgent,
  });

  final String url;
  final String title;
  final String senderAddress;
  final String senderUserAgent;
}

/// Duration → `H:MM:SS`（小时不补零，蓝本 `%d:%02d:%02d`；自家发送端
/// parseUpnpTime 可解析）。负值钳 0。
String formatUpnpClock(Duration d) {
  final total = d.inSeconds < 0 ? 0 : d.inSeconds;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${total ~/ 3600}:${two(total ~/ 60 % 60)}:${two(total % 60)}';
}

/// `H:MM:SS` / `MM:SS` / 纯秒（可带小数）→ Duration；非法返回 null
/// （蓝本 DlnaState.parseTime）。
Duration? parseUpnpClock(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return null;
  final parts = text.split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  double total = 0;
  for (final part in parts) {
    final v = double.tryParse(part);
    if (v == null || v < 0) return null;
    total = total * 60 + v;
  }
  return Duration(microseconds: (total * 1e6).round());
}

final RegExp _didlTitlePattern =
    RegExp(r'<dc:title>(.*?)</dc:title>', dotAll: true);

/// DIDL-Lite 元数据里的 dc:title，容错解析（发送端 DIDL 经常不规范，
/// 蓝本按正则取），失败/为空返回 null。
String? didlTitle(String? metadata) {
  if (metadata == null || metadata.isEmpty) return null;
  final m = _didlTitlePattern.firstMatch(metadata);
  if (m == null) return null;
  final title = m.group(1)!
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .trim();
  return title.isEmpty ? null : title;
}

/// 解析 SOAP 请求体（SOAP 1.1 与 1.2 信封同构，动作名取 Body 第一个元素
/// 的 localName；Body 不可解析时回退 SOAPACTION 头 `urn:…#Action`——
/// 部分发送端头引号/格式随意，蓝本同口径）。
SoapActionRequest? parseSoapRequest(String body, String? soapActionHeader) {
  XmlDocument? doc;
  try {
    doc = XmlDocument.parse(body.trim());
  } catch (_) {
    doc = null;
  }
  if (doc != null) {
    // rootElement 本身也可能是 Body（个别设备省略 Envelope）——
    // descendantElements 只含后代，必须把 root 一起看（见 cast-contract §7）。
    for (final e in [doc.rootElement, ...doc.rootElement.descendantElements]) {
      if (e.name.local != 'Body') continue;
      for (final child in e.childElements) {
        final name = child.name.local;
        final args = <String, String>{
          for (final arg in child.childElements) arg.name.local: arg.innerText,
        };
        return SoapActionRequest(name, args);
      }
      return null;
    }
  }
  final fromHeader = _actionFromHeader(soapActionHeader);
  if (fromHeader != null) return SoapActionRequest(fromHeader, const {});
  return null;
}

String? _actionFromHeader(String? header) {
  final text = header?.trim();
  if (text == null || text.isEmpty) return null;
  final unquoted =
      text.startsWith('"') && text.endsWith('"') && text.length >= 2
          ? text.substring(1, text.length - 1)
          : text;
  final hash = unquoted.lastIndexOf('#');
  final name = hash < 0 ? unquoted : unquoted.substring(hash + 1);
  return name.trim().isEmpty ? null : name.trim();
}

/// 成功响应（`xmlns:u` 用请求 serviceType；发送端 parseSoapResponse 可解析）。
String soapResponseXml(
  String serviceType,
  String action,
  List<(String, String)> args,
) {
  final body = StringBuffer('<u:${action}Response xmlns:u="$serviceType">');
  for (final (name, value) in args) {
    body.write('<$name>${xmlEscape(value)}</$name>');
  }
  body.write('</u:${action}Response>');
  return _soapEnvelope(body.toString());
}

/// fault 报文：UPnP `<UPnPError>` 带 errorCode（自家 parseSoapFault 与
/// 通用控制点都能识别）。
String soapFaultXml(ReceiverFault fault) {
  final detail = '<s:Fault><faultcode>s:Client</faultcode>'
      '<faultstring>UPnPError</faultstring><detail>'
      '<UPnPError xmlns="urn:schemas-upnp-org:control-1-0">'
      '<errorCode>${fault.code}</errorCode>'
      '<errorDescription>${xmlEscape(fault.description)}</errorDescription>'
      '</UPnPError></detail></s:Fault>';
  return _soapEnvelope(detail);
}

String _soapEnvelope(String body) =>
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body>$body</s:Body></s:Envelope>';

/// GetTransportInfo / GetPositionInfo 等纯查询：不打日志不打扰（蓝本
/// QUIET_ACTIONS 口径，由 HTTP 层引用）。
const Set<String> receiverQuietActions = {
  'GetPositionInfo',
  'GetTransportInfo',
  'GetVolume',
  'GetMute',
  'GetMediaInfo',
};

/// DLNA 渲染器控制逻辑（线程模型：Dart 单线程；handle 串行排队，
/// 语义等价蓝本 @Synchronized——前一个动作完成（含引擎 await）后才执行
/// 下一个，避免 Play 插进 SetAVTransportURI 的加载窗口）。
class ReceiverRenderer {
  ReceiverRenderer({required this.player, this.onOpened});

  final ReceiverPlayer player;

  /// 新投会话（SetAVTransportURI 成功）回调；控制器转 onIncomingSession。
  final void Function(ReceiverMediaOpened event)? onOpened;

  String _uri = '';
  String _metadata = '';

  String get currentUri => _uri;

  Future<void> _queue = Future<void>.value();

  /// 执行一个动作，返回出参表；非法请求抛 [ReceiverFault]。
  Future<List<(String, String)>> handle({
    required ReceiverService service,
    required SoapActionRequest action,
    String senderAddress = '',
    String senderUserAgent = '',
  }) {
    // 显式类型实参：FutureOr<R> 推导在 void 参数回调上会退化成 dynamic。
    final Future<List<(String, String)>> result = _queue.then(
      (_) => _handleChecked(
        service: service,
        action: action,
        senderAddress: senderAddress,
        senderUserAgent: senderUserAgent,
      ),
    );
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<(String, String)>> _handleChecked({
    required ReceiverService service,
    required SoapActionRequest action,
    required String senderAddress,
    required String senderUserAgent,
  }) async {
    switch (service) {
      case ReceiverService.avTransport:
        return _avTransport(action, senderAddress, senderUserAgent);
      case ReceiverService.renderingControl:
        return _renderingControl(action);
      case ReceiverService.connectionManager:
        return Future.value(_connectionManager(action));
    }
  }

  Future<List<(String, String)>> _avTransport(
    SoapActionRequest action,
    String senderAddress,
    String senderUserAgent,
  ) async {
    final status = player.status();
    switch (action.name) {
      case 'SetAVTransportURI':
        final url = (action.args['CurrentURI'] ?? '').trim();
        if (url.isEmpty) {
          throw const ReceiverFault(402, 'Invalid Args');
        }
        final metadata = action.args['CurrentURIMetaData'] ?? '';
        await player.load(Uri.parse(url), title: didlTitle(metadata));
        _uri = url;
        _metadata = metadata;
        onOpened?.call(ReceiverMediaOpened(
          url: url,
          title: didlTitle(metadata) ?? '',
          senderAddress: senderAddress,
          senderUserAgent: senderUserAgent,
        ));
        return const [];
      case 'Play':
        if (_uri.isEmpty) {
          throw const ReceiverFault(710, 'Transition not available');
        }
        await player.play();
        return const [];
      case 'Pause':
        if (_uri.isEmpty) {
          throw const ReceiverFault(710, 'Transition not available');
        }
        await player.pause();
        return const [];
      case 'Stop':
        // 幂等成功（蓝本口径）。
        await player.stop();
        return const [];
      case 'Seek':
        if (_uri.isEmpty) {
          throw const ReceiverFault(710, 'Transition not available');
        }
        final unit = (action.args['Unit'] ?? '').trim();
        // REL_TIME / ABS_TIME 接受；REL_BYTE 等其它 unit → 401（design §4）。
        if (unit != 'REL_TIME' && unit != 'ABS_TIME') {
          throw const ReceiverFault(401, 'Seek mode not supported');
        }
        final target = parseUpnpClock(action.args['Target']);
        if (target == null) {
          throw const ReceiverFault(710, 'Illegal seek target');
        }
        await player.seek(target);
        return const [];
      case 'Next':
      case 'Previous':
        throw const ReceiverFault(701, 'Transition not available');
      case 'GetTransportInfo':
        return [
          ('CurrentTransportState', _transportState(status)),
          ('CurrentTransportStatus', 'OK'),
          ('CurrentSpeed', '1'),
        ];
      case 'GetPositionInfo':
        final position = formatUpnpClock(status.position);
        return [
          ('Track', _uri.isEmpty ? '0' : '1'),
          ('TrackDuration', formatUpnpClock(status.duration)),
          ('TrackMetaData', _metadata),
          ('TrackURI', _uri),
          ('RelTime', position),
          ('AbsTime', position),
          ('RelCount', '2147483647'),
          ('AbsCount', '2147483647'),
        ];
      case 'GetMediaInfo':
        if (_uri.isEmpty) {
          throw const ReceiverFault(710, 'No content');
        }
        return [
          ('NrTracks', '1'),
          ('MediaDuration', formatUpnpClock(status.duration)),
          ('CurrentURI', _uri),
          ('CurrentURIMetaData', _metadata),
          ('NextURI', ''),
          ('NextURIMetaData', ''),
          ('PlayMedium', 'NETWORK'),
          ('RecordMedium', 'NOT_IMPLEMENTED'),
          ('WriteStatus', 'NOT_IMPLEMENTED'),
        ];
      case 'GetDeviceCapabilities':
        return [
          ('PlayMedia', 'NETWORK'),
          ('RecMedia', 'NOT_IMPLEMENTED'),
          ('RecQualityModes', 'NOT_IMPLEMENTED'),
        ];
      case 'GetTransportSettings':
        return [('PlayMode', 'NORMAL'), ('RecQualityMode', 'NOT_IMPLEMENTED')];
      case 'GetCurrentTransportActions':
        return [('Actions', _transportActions(status))];
      default:
        throw const ReceiverFault(401, 'Invalid Action');
    }
  }

  Future<List<(String, String)>> _renderingControl(
    SoapActionRequest action,
  ) async {
    final status = player.status();
    switch (action.name) {
      case 'GetVolume':
        return [('CurrentVolume', '${status.volume}')];
      case 'SetVolume':
        final volume =
            int.tryParse((action.args['DesiredVolume'] ?? '').trim());
        if (volume == null || volume < 0 || volume > 100) {
          throw const ReceiverFault(402, 'Invalid Args');
        }
        await player.setVolume(volume);
        return const [];
      case 'GetMute':
        return [('CurrentMute', status.muted ? '1' : '0')];
      case 'SetMute':
        final raw = (action.args['DesiredMute'] ?? '').trim();
        final muted = raw == '1' || raw.toLowerCase() == 'true';
        await player.setMuted(muted);
        return const [];
      case 'ListPresets':
        return [('CurrentPresetNameList', 'FactoryDefaults')];
      case 'SelectPreset':
        return const [];
      default:
        throw const ReceiverFault(401, 'Invalid Action');
    }
  }

  List<(String, String)> _connectionManager(SoapActionRequest action) {
    switch (action.name) {
      case 'GetProtocolInfo':
        return [('Source', ''), ('Sink', receiverSinkProtocolInfo)];
      case 'GetCurrentConnectionIDs':
        return [('ConnectionIDs', '0')];
      case 'GetCurrentConnectionInfo':
        return [
          ('RcsID', '0'),
          ('AVTransportID', '0'),
          ('ProtocolInfo', ''),
          ('PeerConnectionManager', ''),
          ('PeerConnectionID', '-1'),
          ('Direction', 'Input'),
          ('Status', 'OK'),
        ];
      default:
        throw const ReceiverFault(401, 'Invalid Action');
    }
  }

  /// 有 URI 时引擎实况原样上报；无 URI 归一 NO_MEDIA_PRESENT
  /// （蓝本 transportState(status)）。
  String _transportState(ReceiverPlayerStatus status) =>
      _uri.isEmpty ? kTransportNoMedia : status.transportState;

  String _transportActions(ReceiverPlayerStatus status) {
    switch (status.transportState) {
      case kTransportPlaying:
        return 'Pause,Stop,Seek';
      case kTransportPaused:
        return 'Play,Stop,Seek';
      default:
        return _uri.isEmpty ? '' : 'Play';
    }
  }

  /// GENA 事件值（蓝本 eventValues；位置不入事件，控制点轮询 GetPositionInfo）。
  List<(String, String)> eventValues(ReceiverService service) {
    final status = player.status();
    switch (service) {
      case ReceiverService.avTransport:
        return [
          ('TransportState', _transportState(status)),
          ('TransportStatus', 'OK'),
          ('CurrentTransportActions', _transportActions(status)),
          ('AVTransportURI', _uri),
          ('CurrentTrackURI', _uri),
          ('CurrentMediaDuration', formatUpnpClock(status.duration)),
          ('CurrentTrackDuration', formatUpnpClock(status.duration)),
        ];
      case ReceiverService.renderingControl:
        return [
          ('Volume', '${status.volume}'),
          ('Mute', status.muted ? '1' : '0'),
        ];
      case ReceiverService.connectionManager:
        return const [];
    }
  }
}
