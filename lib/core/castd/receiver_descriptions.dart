/// DLNA 接收端（Digital Media Renderer）的描述与 SCPD XML 生成。
///
/// 语义移植自蓝本 `castbay/dlna/UpnpDescriptions.kt`；设备描述刻意保持
/// **扁平单 device + 相对 controlURL** 形状（无 URLBase）——自家发送端
/// `parseDeviceDescription`（lib/core/cast/dlna_device.dart）对这种形状的
/// 解析路径最短：相对地址按 LOCATION（含 authority-only 形态）解析回
/// 绝对地址。互操作回归是硬门槛
/// （test/castd/receiver_descriptions_test.dart）。
library;

import 'dart:math';

/// 设备描述路径（SSDP LOCATION 指向它）。
const String receiverDescriptionPath = '/description.xml';

/// 三个 UPnP 服务的类型 / id / 路径（蓝本 UpnpDescriptions.Service）。
enum ReceiverService {
  avTransport(
    'urn:schemas-upnp-org:service:AVTransport:1',
    'urn:upnp-org:serviceId:AVTransport',
    'AVTransport',
  ),
  renderingControl(
    'urn:schemas-upnp-org:service:RenderingControl:1',
    'urn:upnp-org:serviceId:RenderingControl',
    'RenderingControl',
  ),
  connectionManager(
    'urn:schemas-upnp-org:service:ConnectionManager:1',
    'urn:upnp-org:serviceId:ConnectionManager',
    'ConnectionManager',
  );

  const ReceiverService(this.type, this.id, this.name);

  /// 宣告给控制点的 serviceType（SOAP 信封 xmlns:u / SOAPACTION 用它）。
  final String type;
  final String id;
  final String name;

  String get scpdPath => '/$name/scpd.xml';
  String get controlPath => '/$name/control';
  String get eventPath => '/$name/event';

  static ReceiverService? byScpdPath(String path) =>
      _byPath(path, (s) => s.scpdPath);

  static ReceiverService? byControlPath(String path) =>
      _byPath(path, (s) => s.controlPath);

  static ReceiverService? byEventPath(String path) =>
      _byPath(path, (s) => s.eventPath);

  static ReceiverService? _byPath(
    String path,
    String Function(ReceiverService) pick,
  ) {
    for (final s in ReceiverService.values) {
      if (pick(s) == path) return s;
    }
    return null;
  }
}

/// GetProtocolInfo 的 Sink 声明：本机播放引擎（media_kit/mpv 系）能吃的
/// 容器清单，口径对齐蓝本 DlnaState.sinkProtocolInfo（发送端投送的就是
/// 这批容器：mp4/flv/mkv/ts/HLS/DASH…）。桌面端无 SDK 门槛，含 FLAC。
const String receiverSinkProtocolInfo =
    'http-get:*:video/mp4:*,http-get:*:video/x-flv:*,http-get:*:video/flv:*,'
    'http-get:*:video/mpeg:*,http-get:*:video/x-matroska:*,'
    'http-get:*:video/webm:*,http-get:*:video/quicktime:*,'
    'http-get:*:video/MP2T:*,http-get:*:application/vnd.apple.mpegurl:*,'
    'http-get:*:application/x-mpegURL:*,http-get:*:application/dash+xml:*,'
    'http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,'
    'http-get:*:audio/wav:*,http-get:*:audio/ogg:*,http-get:*:audio/flac:*,'
    'http-get:*:audio/x-flac:*';

/// 设备描述 XML。扁平单 device（无 embedded device）+ 相对 SCPDURL/
/// controlURL/eventSubURL，省略 URLBase——解析基址由控制点用 LOCATION。
String receiverDeviceDescription({
  required String friendlyName,
  required String udn,
}) {
  final services = ReceiverService.values
      .map(
        (s) => '      <service>\n'
            '        <serviceType>${s.type}</serviceType>\n'
            '        <serviceId>${s.id}</serviceId>\n'
            '        <SCPDURL>${s.scpdPath}</SCPDURL>\n'
            '        <controlURL>${s.controlPath}</controlURL>\n'
            '        <eventSubURL>${s.eventPath}</eventSubURL>\n'
            '      </service>',
      )
      .join('\n');
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<root xmlns="urn:schemas-upnp-org:device-1-0" '
      'xmlns:dlna="urn:schemas-dlna-org:device-1-0">\n'
      '  <specVersion><major>1</major><minor>0</minor></specVersion>\n'
      '  <device>\n'
      '    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1'
      '</deviceType>\n'
      '    <friendlyName>${xmlEscape(friendlyName)}</friendlyName>\n'
      '    <manufacturer>aquan</manufacturer>\n'
      '    <modelDescription>短剧投屏接收端（DLNA 渲染器）'
      '</modelDescription>\n'
      '    <modelName>aquan-duanju</modelName>\n'
      '    <modelNumber>1</modelNumber>\n'
      '    <UDN>uuid:$udn</UDN>\n'
      '    <dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>\n'
      '    <serviceList>\n$services\n    </serviceList>\n'
      '  </device>\n'
      '</root>\n';
}

/// 服务 SCPD XML（动作表 + 状态变量表，与蓝本 UpnpDescriptions.kt 逐条对应）。
String receiverScpd(ReceiverService service) {
  final (actions, variables) = switch (service) {
    ReceiverService.avTransport => (_avtActions, _avtVariables),
    ReceiverService.renderingControl => (_rcsActions, _rcsVariables),
    ReceiverService.connectionManager => (_cmActions, _cmVariables),
  };
  final actionXml = actions
      .map(
        (a) => '    <action><name>${a.$1}</name><argumentList>\n'
            '${a.$2.map(_argumentXml).join()}'
            '    </argumentList></action>\n',
      )
      .join();
  final variableXml = variables
      .map(
        (v) => '    <stateVariable sendEvents="${v.$3 ? 'yes' : 'no'}">'
            '<name>${v.$1}</name><dataType>${v.$2}</dataType>'
            '${v.$4.isEmpty ? '' : '<allowedValueList>'
                '${v.$4.map((x) => '<allowedValue>$x</allowedValue>').join()}'
                '</allowedValueList>'}'
            '</stateVariable>\n',
      )
      .join();
  return '<?xml version="1.0" encoding="UTF-8"?>\n'
      '<scpd xmlns="urn:schemas-upnp-org:service-1-0">\n'
      '  <specVersion><major>1</major><minor>0</minor></specVersion>\n'
      '  <actionList>\n$actionXml'
      '  </actionList>\n  <serviceStateTable>\n$variableXml'
      '  </serviceStateTable>\n</scpd>\n';
}

// (参数名, 是否 out, 关联状态变量)
String _argumentXml((String, bool, String) arg) =>
    '      <argument><name>${arg.$1}</name>'
    '<direction>${arg.$2 ? 'out' : 'in'}</direction>'
    '<relatedStateVariable>${arg.$3}</relatedStateVariable></argument>\n';

// (动作名, 参数表)
const List<(String, List<(String, bool, String)>)> _avtActions = [
  (
    'SetAVTransportURI',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('CurrentURI', false, 'AVTransportURI'),
      ('CurrentURIMetaData', false, 'AVTransportURIMetaData'),
    ]
  ),
  (
    'GetMediaInfo',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('NrTracks', true, 'NumberOfTracks'),
      ('MediaDuration', true, 'CurrentMediaDuration'),
      ('CurrentURI', true, 'AVTransportURI'),
      ('CurrentURIMetaData', true, 'AVTransportURIMetaData'),
      ('NextURI', true, 'NextAVTransportURI'),
      ('NextURIMetaData', true, 'NextAVTransportURIMetaData'),
      ('PlayMedium', true, 'PlaybackStorageMedium'),
      ('RecordMedium', true, 'RecordStorageMedium'),
      ('WriteStatus', true, 'RecordMediumWriteStatus'),
    ]
  ),
  (
    'GetTransportInfo',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('CurrentTransportState', true, 'TransportState'),
      ('CurrentTransportStatus', true, 'TransportStatus'),
      ('CurrentSpeed', true, 'TransportPlaySpeed'),
    ]
  ),
  (
    'GetPositionInfo',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Track', true, 'CurrentTrack'),
      ('TrackDuration', true, 'CurrentTrackDuration'),
      ('TrackMetaData', true, 'CurrentTrackMetaData'),
      ('TrackURI', true, 'CurrentTrackURI'),
      ('RelTime', true, 'RelativeTimePosition'),
      ('AbsTime', true, 'AbsoluteTimePosition'),
      ('RelCount', true, 'RelativeCounterPosition'),
      ('AbsCount', true, 'AbsoluteCounterPosition'),
    ]
  ),
  (
    'GetDeviceCapabilities',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('PlayMedia', true, 'PossiblePlaybackStorageMedia'),
      ('RecMedia', true, 'PossibleRecordStorageMedia'),
      ('RecQualityModes', true, 'PossibleRecordQualityModes'),
    ]
  ),
  (
    'GetTransportSettings',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('PlayMode', true, 'CurrentPlayMode'),
      ('RecQualityMode', true, 'CurrentRecordQualityMode'),
    ]
  ),
  (
    'GetCurrentTransportActions',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Actions', true, 'CurrentTransportActions'),
    ]
  ),
  ('Stop', [('InstanceID', false, 'A_ARG_TYPE_InstanceID')]),
  (
    'Play',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Speed', false, 'TransportPlaySpeed'),
    ]
  ),
  ('Pause', [('InstanceID', false, 'A_ARG_TYPE_InstanceID')]),
  (
    'Seek',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Unit', false, 'A_ARG_TYPE_SeekMode'),
      ('Target', false, 'A_ARG_TYPE_SeekTarget'),
    ]
  ),
  ('Next', [('InstanceID', false, 'A_ARG_TYPE_InstanceID')]),
  ('Previous', [('InstanceID', false, 'A_ARG_TYPE_InstanceID')]),
];

const List<(String, List<(String, bool, String)>)> _rcsActions = [
  (
    'ListPresets',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('CurrentPresetNameList', true, 'PresetNameList'),
    ]
  ),
  (
    'SelectPreset',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('PresetName', false, 'A_ARG_TYPE_PresetName'),
    ]
  ),
  (
    'GetMute',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Channel', false, 'A_ARG_TYPE_Channel'),
      ('CurrentMute', true, 'Mute'),
    ]
  ),
  (
    'SetMute',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Channel', false, 'A_ARG_TYPE_Channel'),
      ('DesiredMute', false, 'Mute'),
    ]
  ),
  (
    'GetVolume',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Channel', false, 'A_ARG_TYPE_Channel'),
      ('CurrentVolume', true, 'Volume'),
    ]
  ),
  (
    'SetVolume',
    [
      ('InstanceID', false, 'A_ARG_TYPE_InstanceID'),
      ('Channel', false, 'A_ARG_TYPE_Channel'),
      ('DesiredVolume', false, 'Volume'),
    ]
  ),
];

const List<(String, List<(String, bool, String)>)> _cmActions = [
  (
    'GetProtocolInfo',
    [
      ('Source', true, 'SourceProtocolInfo'),
      ('Sink', true, 'SinkProtocolInfo'),
    ]
  ),
  (
    'GetCurrentConnectionIDs',
    [('ConnectionIDs', true, 'CurrentConnectionIDs')]
  ),
  (
    'GetCurrentConnectionInfo',
    [
      ('ConnectionID', false, 'A_ARG_TYPE_ConnectionID'),
      ('RcsID', true, 'A_ARG_TYPE_RcsID'),
      ('AVTransportID', true, 'A_ARG_TYPE_AVTransportID'),
      ('ProtocolInfo', true, 'A_ARG_TYPE_ProtocolInfo'),
      ('PeerConnectionManager', true, 'A_ARG_TYPE_ConnectionManager'),
      ('PeerConnectionID', true, 'A_ARG_TYPE_ConnectionID'),
      ('Direction', true, 'A_ARG_TYPE_Direction'),
      ('Status', true, 'A_ARG_TYPE_ConnectionStatus'),
    ]
  ),
];

// (变量名, 类型, 是否事件化, allowedValues)
const List<(String, String, bool, List<String>)> _avtVariables = [
  (
    'TransportState',
    'string',
    false,
    ['STOPPED', 'PLAYING', 'PAUSED_PLAYBACK', 'TRANSITIONING', 'NO_MEDIA_PRESENT']
  ),
  ('TransportStatus', 'string', false, ['OK', 'ERROR_OCCURRED']),
  ('TransportPlaySpeed', 'string', false, ['1']),
  ('NumberOfTracks', 'ui4', false, []),
  ('CurrentTrack', 'ui4', false, []),
  ('CurrentMediaDuration', 'string', false, []),
  ('CurrentTrackDuration', 'string', false, []),
  ('CurrentTrackMetaData', 'string', false, []),
  ('CurrentTrackURI', 'string', false, []),
  ('AVTransportURI', 'string', false, []),
  ('AVTransportURIMetaData', 'string', false, []),
  ('NextAVTransportURI', 'string', false, []),
  ('NextAVTransportURIMetaData', 'string', false, []),
  ('RelativeTimePosition', 'string', false, []),
  ('AbsoluteTimePosition', 'string', false, []),
  ('RelativeCounterPosition', 'i4', false, []),
  ('AbsoluteCounterPosition', 'i4', false, []),
  ('PlaybackStorageMedium', 'string', false, []),
  ('RecordStorageMedium', 'string', false, []),
  ('RecordMediumWriteStatus', 'string', false, []),
  ('PossiblePlaybackStorageMedia', 'string', false, []),
  ('PossibleRecordStorageMedia', 'string', false, []),
  ('PossibleRecordQualityModes', 'string', false, []),
  ('CurrentPlayMode', 'string', false, ['NORMAL']),
  ('CurrentRecordQualityMode', 'string', false, []),
  ('CurrentTransportActions', 'string', false, []),
  ('LastChange', 'string', true, []),
  ('A_ARG_TYPE_InstanceID', 'ui4', false, []),
  (
    'A_ARG_TYPE_SeekMode',
    'string',
    false,
    ['REL_TIME', 'ABS_TIME', 'TRACK_NR']
  ),
  ('A_ARG_TYPE_SeekTarget', 'string', false, []),
];

const List<(String, String, bool, List<String>)> _rcsVariables = [
  ('PresetNameList', 'string', false, []),
  ('Mute', 'boolean', false, []),
  ('Volume', 'ui2', false, []),
  ('LastChange', 'string', true, []),
  ('A_ARG_TYPE_InstanceID', 'ui4', false, []),
  ('A_ARG_TYPE_Channel', 'string', false, ['Master']),
  ('A_ARG_TYPE_PresetName', 'string', false, ['FactoryDefaults']),
];

const List<(String, String, bool, List<String>)> _cmVariables = [
  ('SourceProtocolInfo', 'string', true, []),
  ('SinkProtocolInfo', 'string', true, []),
  ('CurrentConnectionIDs', 'string', true, []),
  (
    'A_ARG_TYPE_ConnectionStatus',
    'string',
    false,
    ['OK', 'ContentFormatMismatch', 'InsufficientBandwidth', 'UnreliableChannel', 'Unknown']
  ),
  ('A_ARG_TYPE_ConnectionManager', 'string', false, []),
  ('A_ARG_TYPE_Direction', 'string', false, ['Input', 'Output']),
  ('A_ARG_TYPE_ProtocolInfo', 'string', false, []),
  ('A_ARG_TYPE_ConnectionID', 'i4', false, []),
  ('A_ARG_TYPE_AVTransportID', 'i4', false, []),
  ('A_ARG_TYPE_RcsID', 'i4', false, []),
];

/// XML 文本转义（元素文本 / 属性值两用）。
String xmlEscape(String text) => text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&apos;');

/// RFC 4122 uuid v4（接收端 UDN 用；随机源 [Random.secure]）。
String uuidV4([Random? rng]) {
  final r = rng ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
