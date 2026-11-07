import '../error_log.dart';

/// 投屏失败判定（M0 五类，判据见父任务 design §3.5 表）。
enum CastVerdict {
  /// 从未发出 SetAVTransportURI（发现/描述/预检就失败）。
  notSent,

  /// 发出但被 401/402/501/714 或 fault 拒绝。
  notAccepted,

  /// 设备回了成功，但电视从未向本机媒体服务发过请求 → 优先怀疑
  /// 本机 IP / 防火墙 / 端口。
  acceptedButNotFetched,

  /// 电视请求过媒体但没有一次 2xx 成功响应。
  fetchedButNotDecoded,

  /// 取到流（2xx）但设备从未进入 PLAYING → 媒体格式/编码问题。
  playingNotConfirmed;

  /// 面板展示的中文标签（固定文案）。
  String get label => switch (this) {
        notSent => '未发出投屏命令',
        notAccepted => '投屏命令被拒绝',
        acceptedButNotFetched => '已接受，但电视没来取流',
        fetchedButNotDecoded => '电视来取流但没有取成',
        playingNotConfirmed => '取到了流，但电视没播出来',
      };

  /// 一句人话解释（固定文案；原始异常只进 ErrorLog）。
  String get hint => switch (this) {
        notSent =>
          '设备发现或能力预检阶段就失败了，投屏命令从未发出。可确认电视已开机在线，或用面板下方的「直连」手动输入电视 IP。',
        notAccepted =>
          '电视明确拒绝了投屏命令（SOAP fault）。请用「复制诊断报告」把报告反馈给我们，便于定位协议兼容问题。',
        acceptedButNotFetched =>
          '电视接受了投屏命令，但从未向本机拉取视频。优先检查本机 IP、端口与 Windows 防火墙（见下方放行命令）；也可在同一 Wi-Fi 的另一台设备浏览器里打开投屏地址验证连通性。',
        fetchedButNotDecoded =>
          '电视来拉流了但没有成功取到数据，可能是网络抖动或源站临时不可用，可重试一次。',
        playingNotConfirmed =>
          '电视成功取到了媒体流，但一直没进入播放状态，多半是媒体格式/编码不被支持。可尝试换个片源，或使用「镜像屏幕」投屏。',
      };
}

/// 一次 SOAP action 的记录（纯采集，不参与协议行为）。
class SoapTrace {
  SoapTrace({
    required this.action,
    Map<String, String>? requestHeaders,
    required this.requestBody,
    this.httpStatus = 0,
    this.responseBody = '',
    this.faultCode,
    this.faultDescription,
    this.error,
    DateTime? at,
  })  : requestHeaders = Map.of(requestHeaders ?? const {}),
        at = at ?? DateTime.now();

  final String action;
  final Map<String, String> requestHeaders;
  final String requestBody;

  /// HTTP 状态码；0 = 请求根本没到设备（超时/连接失败）。
  final int httpStatus;
  final String responseBody;
  final String? faultCode;
  final String? faultDescription;

  /// 传输层错误摘要（超时/SocketException 等）。
  final String? error;
  final DateTime at;

  bool get isFailure =>
      httpStatus >= 400 || faultCode != null || faultDescription != null;

  @override
  String toString() => 'SoapTrace($action, HTTP $httpStatus'
      '${faultCode == null ? '' : ', fault $faultCode'})';
}

/// 电视对本机媒体服务的一次取流请求记录。
class MediaRequestTrace {
  MediaRequestTrace({
    required this.url,
    required this.method,
    this.range,
    this.userAgent,
    required this.statusCode,
    this.bytesServed = 0,
    this.source = '',
    DateTime? at,
  }) : at = at ?? DateTime.now();

  final String url;
  final String method;

  /// 请求的 Range 头（原样）；无 Range 为 null。
  final String? range;
  final String? userAgent;

  /// 响应给电视的状态码。
  final int statusCode;

  /// 实际写给电视的字节数（HEAD / 失败路径为 0）。
  final int bytesServed;

  /// 来源服务：`proxy`（CastMediaProxy）/ `local`（LocalMediaServer）。
  final String source;
  final DateTime at;

  bool get isOk => statusCode >= 200 && statusCode < 300;
}

/// 一次投屏会话的诊断采集（M0 纯增量埋点）。
///
/// 使用方式：各采集点写入 [CastDiagnostics.instance]；面板读取展示。
/// - `beginSession` 重置「会话级」数据（SOAP/取流/时间线/目标字段）；
///   SSDP 原始响应与设备摘要属于「发现阶段」证据，跨会话保留（有上限）。
/// - 面板展示走 [mediaUrl]（完整 URL 含 token，供另一台设备浏览器自测）；
///   复制/导出一律走 [toRedactedReport]（导出级脱敏，token 不出现）。
/// - 所有 record 方法自身吞异常并写 ErrorLog：**诊断采集绝不能影响投屏主链路**。
class CastDiagnostics {
  CastDiagnostics();

  /// 全局采集点（应用生命周期内一份）。
  static final CastDiagnostics instance = CastDiagnostics();

  static const int maxSsdpResponses = 16;
  static const int maxDeviceSummaries = 8;
  static const int maxSoapTraces = 48;
  static const int maxMediaRequests = 128;
  static const int maxTimelineEntries = 96;

  /// 单条原始文本（SSDP 报文等）的截断上限（4KB）。
  static const int maxRawLength = 4096;

  /// SOAP 请求体/响应体在 trace 里的截断上限。
  static const int maxSoapBodyLength = 4096;
  static const int maxSoapResponseLength = 2048;

  final List<String> _ssdpResponses = <String>[];
  final List<String> _deviceSummaries = <String>[];
  final List<String> _sinkProtocols = <String>[];
  final List<SoapTrace> _soapTraces = <SoapTrace>[];
  final List<MediaRequestTrace> _mediaRequests = <MediaRequestTrace>[];
  final List<String> _timeline = <String>[];
  final List<String> _scanSummary = <String>[];

  DateTime? _startedAt;
  String? _deviceName;
  String? _protocol;
  String? _selectedIp;
  String? _mediaUrl;
  int? _mediaPort;

  // ---------- 只读视图（面板用） ----------

  List<String> get ssdpResponses => List.unmodifiable(_ssdpResponses);
  List<String> get deviceSummaries => List.unmodifiable(_deviceSummaries);
  List<String> get sinkProtocols => List.unmodifiable(_sinkProtocols);
  List<SoapTrace> get soapTraces => List.unmodifiable(_soapTraces);
  List<MediaRequestTrace> get mediaRequests => List.unmodifiable(_mediaRequests);
  List<String> get timeline => List.unmodifiable(_timeline);

  /// 深度诊断扫描汇总行（R1.3；`CastScanResult.summaryLines` 落地于此）。
  List<String> get scanSummary => List.unmodifiable(_scanSummary);

  /// 本会话是否已发起连接（区分「空态」与「无判定」）。
  bool get hasSession => _startedAt != null;

  String? get deviceName => _deviceName;
  String? get protocol => _protocol;

  /// 本机媒体服务选中的 IP（面板级展示；未采集为 null）。
  String? get selectedIp => _selectedIp;

  /// 完整投屏 URL（**含 token，仅供面板展示自测**；导出报告不使用它）。
  String? get mediaUrl => _mediaUrl;

  /// 本机媒体服务监听端口（直投公网 URL 时为 null）。
  int? get mediaPort => _mediaPort;

  /// 会话时间线里出现过 PLAYING / RUNNING（播放已确认）。
  bool get playingConfirmed => _timeline.any(
      (l) => l.contains('transportState=PLAYING') || l.contains('transportState=RUNNING'));

  // ---------- 采集点 ----------

  /// 开始一次投屏会话：清空会话级数据，保留发现阶段证据（SSDP/设备摘要）。
  void beginSession({String? deviceName, String? protocol}) {
    try {
      _soapTraces.clear();
      _mediaRequests.clear();
      _timeline.clear();
      _scanSummary.clear();
      _sinkProtocols.clear();
      _selectedIp = null;
      _mediaUrl = null;
      _mediaPort = null;
      _startedAt = DateTime.now();
      _deviceName = deviceName;
      _protocol = protocol;
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 记录一条原始 SSDP 报文（截断 + 去重 + 上限）。
  void recordSsdpResponse(String raw) {
    try {
      if (raw.isEmpty) return;
      final text = _clip(raw, maxRawLength);
      if (_ssdpResponses.contains(text)) return;
      _pushCapped(_ssdpResponses, text, maxSsdpResponses);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 记录一台设备的描述摘要（一行一台，不含完整 XML）。
  void recordDeviceSummary(String line) {
    try {
      if (line.isEmpty) return;
      if (_deviceSummaries.contains(line)) return;
      _pushCapped(_deviceSummaries, line, maxDeviceSummaries);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 记录预检拿到的设备 Sink 条目。
  void recordSinks(Iterable<String> sinks) {
    try {
      _sinkProtocols.clear();
      for (final s in sinks) {
        final v = s.trim();
        if (v.isNotEmpty) _sinkProtocols.add(v);
      }
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  void recordSoap(SoapTrace trace) {
    try {
      _pushCapped(_soapTraces, trace, maxSoapTraces);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  void recordMediaRequest(MediaRequestTrace trace) {
    try {
      _pushCapped(_mediaRequests, trace, maxMediaRequests);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 记录一条状态时间线（状态机/配方尝试/电视状态变化）。
  void recordTimeline(String entry) {
    try {
      if (entry.isEmpty) return;
      _pushCapped(_timeline, '${_stamp()} $entry', maxTimelineEntries);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 记录深度诊断扫描汇总（R1.3；覆盖式写入——一次会话至多一次扫描，
  /// `beginSession` 时清空）。导出报告据此输出「深度诊断扫描汇总」段。
  void recordScanSummary(Iterable<String> lines) {
    try {
      _scanSummary
        ..clear()
        ..addAll(lines);
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  /// 更新本次会话的目标字段；只覆盖非 null 项（连播换集只换 URL）。
  void setTarget({String? selectedIp, String? mediaUrl, int? mediaPort}) {
    try {
      if (selectedIp != null) _selectedIp = selectedIp;
      if (mediaUrl != null) _mediaUrl = mediaUrl;
      if (mediaPort != null) _mediaPort = mediaPort;
    } catch (e, stack) {
      _logCollectError(e, stack);
    }
  }

  // ---------- 失败判定 ----------

  /// 五类失败判定；返回 null = 无失败判定（未发起会话 / 非 DLNA 会话 /
  /// 播放已确认）。
  CastVerdict? computeVerdict() {
    try {
      if (_startedAt == null) return null;
      if (_protocol != null && _protocol != 'dlna') return null;
      if (playingConfirmed) return null;
      final setUri = _soapTraces
          .where((t) => t.action == 'SetAVTransportURI')
          .toList(growable: false);
      if (setUri.isEmpty) return CastVerdict.notSent;
      final lastSet = setUri.last;
      final setAccepted = !lastSet.isFailure &&
          lastSet.httpStatus >= 200 &&
          lastSet.httpStatus < 300;
      if (!setAccepted) return CastVerdict.notAccepted;
      final plays = _soapTraces.where((t) => t.action == 'Play').toList();
      if (plays.isNotEmpty && plays.last.isFailure) {
        return CastVerdict.notAccepted;
      }
      if (_mediaRequests.isEmpty) return CastVerdict.acceptedButNotFetched;
      if (!_mediaRequests.any((m) => m.isOk)) {
        return CastVerdict.fetchedButNotDecoded;
      }
      return CastVerdict.playingNotConfirmed;
    } catch (e, stack) {
      _logCollectError(e, stack);
      return null;
    }
  }

  // ---------- 导出（二级脱敏） ----------

  /// 导出级脱敏后的可回传报告。
  ///
  /// 两级脱敏（review §8.4）：token 段 → `<token>`、签名 query 值 →
  /// `<redacted>`、凭据头整键删除、`dc:description` → `<headers-redacted>`。
  /// 面板展示用的完整投屏 URL（含 token）**不会**出现在这里。
  String toRedactedReport() {
    try {
      return _buildReport();
    } catch (e, stack) {
      _logCollectError(e, stack);
      return '诊断报告生成失败';
    }
  }

  String _buildReport() {
    final b = StringBuffer();
    final now = DateTime.now();
    b.writeln('== 投屏诊断报告 ==');
    b.writeln('生成时间：${_fmtDateTime(now)}');
    if (_startedAt != null) {
      b.writeln('会话开始：${_fmtDateTime(_startedAt!)}');
    }
    if (_deviceName != null) {
      b.writeln('目标设备：$_deviceName'
          '${(_protocol == null || _protocol!.isEmpty) ? '' : '（$_protocol）'}');
    }
    final verdict = computeVerdict();
    b.writeln('失败判定：${verdict?.label ?? (playingConfirmed ? '无（已确认电视进入播放）' : '暂无判定')}');
    if (verdict != null) b.writeln('判定说明：${verdict.hint}');
    b.writeln('本机 IP：${_selectedIp ?? '未采集'}');
    b.writeln('监听端口：${_mediaPort?.toString() ?? '未采集'}');
    b.writeln('投屏 URL：'
        '${_mediaUrl == null ? '未采集' : redactReportText(_mediaUrl!)}');

    if (_sinkProtocols.isNotEmpty) {
      b.writeln();
      b.writeln('-- 设备 Sink 清单（${_sinkProtocols.length} 条） --');
      for (final s in _sinkProtocols) {
        b.writeln('  - ${redactReportText(s)}');
      }
    }

    if (_soapTraces.isNotEmpty) {
      b.writeln();
      b.writeln('-- SOAP 记录（最近 ${_soapTraces.length} 条） --');
      for (final t in _soapTraces) {
        b.writeln('[${_stampOf(t.at)}] ${t.action} → '
            '${t.httpStatus == 0 ? '未到达设备' : 'HTTP ${t.httpStatus}'}'
            '${t.error == null ? '' : '（${t.error}）'}');
        if (t.faultCode != null || t.faultDescription != null) {
          b.writeln('  fault: ${t.faultCode ?? '-'} ${t.faultDescription ?? ''}');
        }
        final headers = redactedHeaders(t.requestHeaders);
        if (headers.isNotEmpty) {
          b.writeln('  请求头: ${headers.entries.map((e) => '${e.key}=${e.value}').join('; ')}');
        }
        if (t.requestBody.isNotEmpty) {
          b.writeln('  请求体: ${redactReportText(_clip(t.requestBody, maxSoapBodyLength))}');
        }
        if (t.responseBody.isNotEmpty) {
          b.writeln('  响应体: ${redactReportText(_clip(t.responseBody, maxSoapResponseLength))}');
        }
      }
    }

    if (_mediaRequests.isNotEmpty) {
      b.writeln();
      b.writeln('-- 电视取流记录（最近 ${_mediaRequests.length} 条） --');
      for (final m in _mediaRequests) {
        b.writeln('[${_stampOf(m.at)}] ${m.method} '
            '${redactReportText(m.url)}'
            '${m.range == null ? '' : ' Range=${m.range}'}'
            '${m.userAgent == null ? '' : ' UA="${m.userAgent}"'}'
            ' → ${m.statusCode}'
            '${m.source.isEmpty ? '' : ' ($m.source)'}'
            ' ${m.bytesServed}B');
      }
    }

    if (_timeline.isNotEmpty) {
      b.writeln();
      b.writeln('-- 状态时间线 --');
      // 逐行过导出级脱敏（R2.1 防御纵深）：时间线可能内嵌异常消息里的
      // 投屏 URL/签名 query，不能只因「面板拼接文本」就绕过脱敏。
      for (final l in _timeline) {
        b.writeln('  ${redactReportText(l)}');
      }
    }

    if (_scanSummary.isNotEmpty) {
      b.writeln();
      b.writeln('-- 深度诊断扫描汇总 --');
      for (final l in _scanSummary) {
        b.writeln('  $l');
      }
    }

    if (_deviceSummaries.isNotEmpty) {
      b.writeln();
      b.writeln('-- 设备描述摘要 --');
      for (final l in _deviceSummaries) {
        b.writeln('  $l');
      }
    }

    if (_ssdpResponses.isNotEmpty) {
      b.writeln();
      b.writeln('-- SSDP 原始响应（最近 ${_ssdpResponses.length} 条，已截断） --');
      for (final r in _ssdpResponses) {
        b.writeln('  ${redactReportText(r.replaceAll('\r\n', ' | '))}');
      }
    }
    return b.toString().trimRight();
  }

  // ---------- 脱敏工具（导出级；可独立单测） ----------

  /// 本机服务 URL 的 token 路径段：`/p/<token>`、`/m/<token>`、
  /// `/cast/<token>/…`、`/w/<token>`。
  static final RegExp _tokenPathPattern =
      RegExp(r'/(p|m|cast|w)/([A-Za-z0-9_-]{12,})');

  /// URL query 的敏感键：短键（`t`/`v`）精确匹配；其余按凭据词根包含匹配
  ///（覆盖 `wsSecret`/`auth_key`/`access_token`/`X-Amz-Signature` 等变体拼写；
  /// 宁多抹不漏抹——导出报告只留扩展名与路径形状用于定位）。
  static const List<String> _sensitiveQueryRoots = [
    'sign', 'sig', 'token', 'key', 'auth', 'secret', 'ticket',
    'expire', 'deadline', 'credential', 'password',
  ];

  static bool _isSensitiveQueryKey(String key) {
    if (key == 't' || key == 'v') return true;
    return _sensitiveQueryRoots.any(key.contains);
  }

  static final RegExp _queryParamPattern =
      RegExp(r'([?&])([A-Za-z0-9_\-]+)=([^&\s"\x27<>]*)');

  /// DIDL 的 `dc:description`（内含防盗链头 JSON）整体替换。
  static final RegExp _dcDescriptionPattern =
      RegExp(r'<dc:description>[\s\S]*?</dc:description>');

  /// 凭据类请求头键（与 didl.dart 的过滤口径一致）。
  static final RegExp _credentialHeaderKey = RegExp(
    r'cookie|authorization|auth|token|secret|credential|password|api[_-]?key|signature|sign',
    caseSensitive: false,
  );

  /// 导出级脱敏：token 段 / 签名 query 值 / `dc:description`。
  /// 非敏感 query 值保留（保住扩展名与路径形状，便于定位）。
  ///
  /// 顺序：先抹 `dc:description`（最具体的整段替换），再抹 token 段，最后抹
  /// query 值——防止 query 值一路吃到后面的标签导致漏抹。
  static String redactReportText(String text) => text
      .replaceAllMapped(_dcDescriptionPattern,
          (m) => '<dc:description><headers-redacted></dc:description>')
      .replaceAllMapped(_tokenPathPattern, (m) => '/${m[1]}/<token>')
      .replaceAllMapped(_queryParamPattern, (m) {
        final key = (m[2] ?? '').toLowerCase();
        if (!_isSensitiveQueryKey(key)) return m.group(0)!;
        return '${m[1]}${m[2]}=<redacted>';
      });

  /// 凭据类请求头整键删除，其余原样。
  static Map<String, String> redactedHeaders(Map<String, String> headers) => {
        for (final e in headers.entries)
          if (!_credentialHeaderKey.hasMatch(e.key)) e.key: e.value,
      };

  /// Windows 防火墙 program 级放行命令（File2TV winutil 同款，program 级
  /// 比端口级少触发安全软件）。
  static String buildWindowsFirewallCommand({required String programPath}) =>
      'netsh advfirewall firewall add rule name="aquan-duanju" dir=in '
      'action=allow program="$programPath" profile=private,domain '
      'remoteip=localsubnet';

  // ---------- 内部 ----------

  static void _pushCapped<T>(List<T> list, T item, int cap) {
    list.add(item);
    while (list.length > cap) {
      list.removeAt(0);
    }
  }

  static String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…（已截断）';

  static void _logCollectError(Object e, StackTrace stack) {
    try {
      ErrorLog.instance.record('投屏诊断采集', e, stack);
    } catch (_) {
      // 日志都失败时只能静默：诊断绝不拖垮投屏。
    }
  }

  static String _stamp() => _stampOf(DateTime.now());

  static String _stampOf(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _fmtDateTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
