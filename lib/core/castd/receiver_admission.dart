/// 接收端准入控制（任务 11-07-cast-receiver-advanced design §1）：三模式
/// 纯逻辑状态机，renderer 的 SetAVTransportURI 前置调用 [AdmissionPolicy.decide]，
/// 拒绝由 renderer 翻译成 SOAP fault 401（Action Not Authorized）。
///
/// - `anyone`（默认）：任何人可投——本类存在与否都不改变旧路径行为；
/// - `ask`：陌生设备（两个名单都没有的 IP）经 [promptHandler] 询问用户，
///   30s（[promptTimeout]）未响应 = 拒绝；「记住此设备」分别写入允许/拒绝名单；
/// - `whitelist`：只看允许名单，名单外直接拒（不询问）。
///
/// 设备标识 = 发送方 IP（SOAP 请求来源，UA 只是显示辅助）。名单持久化在
/// SettingsStore 两个 JSON 键（`cast.receiverAllowIps` / `cast.receiverDenyIps`），
/// 本类只出/进 JSON 字符串，不反向依赖 store 层。
library;

import 'dart:async';
import 'dart:convert';

/// 准入模式（SettingsStore `cast.receiverAdmissionMode` 三值同源）。
enum ReceiverAdmissionMode { anyone, ask, whitelist }

/// 模式的持久化取值（与 [ReceiverAdmissionMode] 一一对应）。
const List<String> receiverAdmissionModes = ['anyone', 'ask', 'whitelist'];

/// 模式字符串 ↔ 枚举（非法值回落 anyone，与 SettingsStore 归一口径一致）。
ReceiverAdmissionMode admissionModeFromString(String? raw) {
  switch (raw) {
    case 'ask':
      return ReceiverAdmissionMode.ask;
    case 'whitelist':
      return ReceiverAdmissionMode.whitelist;
    default:
      return ReceiverAdmissionMode.anyone;
  }
}

/// 模式的固定中文文案（设置页三选 / 弹窗共用单一来源）。
String receiverAdmissionModeLabel(String? mode) {
  switch (mode) {
    case 'ask':
      return '每次询问';
    case 'whitelist':
      return '仅允许列表';
    default:
      return '任何人可投';
  }
}

/// 名单里的一条设备记忆（R1.5 管理页展示 IP/UA/时间）。
class ReceiverAdmissionEntry {
  const ReceiverAdmissionEntry({
    required this.ip,
    this.userAgent = '',
    required this.at,
  });

  final String ip;
  final String userAgent;

  /// 记住的时间（弹窗响应时刻或名单导入时刻）。
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'ip': ip,
        if (userAgent.isNotEmpty) 'ua': userAgent,
        'at': at.toIso8601String(),
      };

  factory ReceiverAdmissionEntry.fromJson(Map<String, dynamic> json) =>
      ReceiverAdmissionEntry(
        ip: (json['ip'] as String? ?? '').trim(),
        userAgent: json['ua'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
      );
}

/// 名单 → JSON 字符串（SettingsStore 落盘值，`[{ip,ua,at}]`）。
String encodeAdmissionEntries(Iterable<ReceiverAdmissionEntry> entries) =>
    jsonEncode([for (final e in entries) e.toJson()]);

/// JSON 字符串 → 名单（坏串/垃圾值容错：能解析几条算几条，异常归空）。
List<ReceiverAdmissionEntry> decodeAdmissionEntries(String? raw) {
  final text = raw?.trim() ?? '';
  if (text.isEmpty) return const [];
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  final entries = <ReceiverAdmissionEntry>[];
  for (final item in decoded) {
    if (item is! Map<String, dynamic>) continue;
    final entry = ReceiverAdmissionEntry.fromJson(item);
    if (entry.ip.isEmpty) continue;
    entries.add(entry);
  }
  return entries;
}

/// 弹窗请求（问谁）。
class ReceiverAdmissionRequest {
  const ReceiverAdmissionRequest({required this.ip, this.userAgent = ''});

  final String ip;
  final String userAgent;
}

/// 弹窗结果：允许/拒绝 + 是否记住该设备（R1.2 拒绝也可记住 → 拒绝名单）。
class AdmissionPromptOutcome {
  const AdmissionPromptOutcome({required this.allow, this.remember = false});

  final bool allow;
  final bool remember;
}

/// 询问回调签名（service 默认接全局对话框；测试注入假 handler）。
typedef AdmissionPromptHandler = Future<AdmissionPromptOutcome> Function(
  ReceiverAdmissionRequest request,
);

/// 准入状态机（纯逻辑：可注入 prompt 回调 / 超时 / 时钟，测试友好）。
///
/// 两个名单以 IP 为键；同一 IP 同时出现在两表时按 design 口径
/// 「先查允许、再查拒绝」（ask 模式），whitelist 模式只看允许表。
class AdmissionPolicy {
  AdmissionPolicy({
    this.mode = ReceiverAdmissionMode.anyone,
    this.promptHandler,
    this.promptTimeout = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  ReceiverAdmissionMode mode;

  /// 询问回调（null 时 ask 模式对陌生设备直接拒——不能静默放行）。
  AdmissionPromptHandler? promptHandler;

  /// 询问超时（默认 30s，超时 = 拒绝；测试注入短时长）。
  final Duration promptTimeout;

  /// 名单条目的时间戳来源（测试注入固定时钟）。
  final DateTime Function() clock;

  /// 记住的允许/拒绝设备（ip → 条目）。
  final Map<String, ReceiverAdmissionEntry> allowed = {};
  final Map<String, ReceiverAdmissionEntry> denied = {};

  /// 展示顺序：最近记住的在前。
  List<ReceiverAdmissionEntry> get allowEntries => _sorted(allowed);
  List<ReceiverAdmissionEntry> get denyEntries => _sorted(denied);

  List<ReceiverAdmissionEntry> _sorted(Map<String, ReceiverAdmissionEntry> m) {
    final list = m.values.toList()..sort((a, b) => b.at.compareTo(a.at));
    return List.unmodifiable(list);
  }

  void allowDevice(String ip, {String userAgent = ''}) {
    final key = ip.trim();
    if (key.isEmpty) return;
    allowed[key] = ReceiverAdmissionEntry(
      ip: key,
      userAgent: userAgent,
      at: clock(),
    );
    denied.remove(key);
  }

  void denyDevice(String ip, {String userAgent = ''}) {
    final key = ip.trim();
    if (key.isEmpty) return;
    denied[key] = ReceiverAdmissionEntry(
      ip: key,
      userAgent: userAgent,
      at: clock(),
    );
    allowed.remove(key);
  }

  bool removeAllowed(String ip) => allowed.remove(ip.trim()) != null;

  bool removeDenied(String ip) => denied.remove(ip.trim()) != null;

  int clearAllowed() {
    final n = allowed.length;
    allowed.clear();
    return n;
  }

  int clearDenied() {
    final n = denied.length;
    denied.clear();
    return n;
  }

  /// SetAVTransportURI 前置检查：true = 放行（走原加载路径），false = 拒绝
  /// （renderer 回 fault 401）。绝不抛异常路径以外的副作用。
  Future<bool> decide({
    required String senderIp,
    String senderUa = '',
  }) async {
    switch (mode) {
      case ReceiverAdmissionMode.anyone:
        return true;
      case ReceiverAdmissionMode.whitelist:
        // 白名单模式只看允许表（拒绝名单无关）。
        return allowed.containsKey(senderIp.trim());
      case ReceiverAdmissionMode.ask:
        final ip = senderIp.trim();
        if (allowed.containsKey(ip)) return true;
        if (denied.containsKey(ip)) return false;
        return _askViaPrompt(ip, senderUa);
    }
  }

  Future<bool> _askViaPrompt(String ip, String senderUa) async {
    final handler = promptHandler;
    if (handler == null) return false;
    // 询问 = handler 结果与 [promptTimeout] 赛跑（Timer + Completer 实现，
    // 不用 Future.timeout——实测「handler future 已带错 + timeout 链」会把
    // 错误漏成 uncaught，赛跑式在这里对同步抛/异步错/永不完成全都确定）。
    final outcome = await _racePrompt(
      () => handler(ReceiverAdmissionRequest(ip: ip, userAgent: senderUa)),
    );
    if (outcome == null) {
      // 30s 未响应 = 拒绝（R1.4），且不记住。
      return false;
    }
    if (outcome.remember) {
      outcome.allow
          ? allowDevice(ip, userAgent: senderUa)
          : denyDevice(ip, userAgent: senderUa);
    }
    return outcome.allow;
  }

  /// handler 结果与超时赛跑；handler 异常/同步抛出按 null（拒绝）处理。
  Future<AdmissionPromptOutcome?> _racePrompt(
    Future<AdmissionPromptOutcome> Function() invoke,
  ) {
    final completer = Completer<AdmissionPromptOutcome?>();
    final timer = Timer(promptTimeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    void done(AdmissionPromptOutcome? value) {
      if (completer.isCompleted) return;
      timer.cancel();
      completer.complete(value);
    }

    try {
      invoke().then(
        (v) => done(v),
        onError: (Object e, StackTrace s) {
          // handler 异常按拒绝处理（协议面不能被 UI 层炸掉）。
          done(null);
        },
      );
    } catch (_) {
      done(null);
    }
    return completer.future;
  }

  // ---------- 持久化（SettingsStore JSON 键值，字符串进出） ----------

  String encodeAllowJson() => encodeAdmissionEntries(allowed.values);

  String encodeDenyJson() => encodeAdmissionEntries(denied.values);

  void loadAllowJson(String? raw) {
    allowed
      ..clear()
      ..addEntries([
        for (final e in decodeAdmissionEntries(raw)) MapEntry(e.ip, e),
      ]);
  }

  void loadDenyJson(String? raw) {
    denied
      ..clear()
      ..addEntries([
        for (final e in decodeAdmissionEntries(raw)) MapEntry(e.ip, e),
      ]);
  }
}
