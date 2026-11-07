import 'dart:async';

import '../aqua_error.dart';
import '../error_log.dart';
import 'cast_diagnostics.dart';

/// 状态读取器（注入 `AquaApi.castRelayStatus` 同形状的函数，避免本目录
/// 反向依赖 API 层）。
typedef CastRelayStatusReader = Future<Map<String, dynamic>> Function(
    String session);

/// Go 中继（castrelay）取流日志探针（M0-5）。
///
/// 电视对 Go 中继（`/cast/<token>/`）的取流记录在 Go 侧环形保存，
/// 经 `castRelayStatus` 的 `recent` 字段返回。这里周期拉取，把新增记录
/// 转写进 [CastDiagnostics.mediaRequests]（source=relay），诊断报告据此
/// 能区分「中继起了但电视没来拉」与「电视拉了但 404/失败」。
///
/// 使用方式：中继启动成功后 [watch]，会话停止/回收后 [unwatch]（探针在
/// 状态查询报「会话不存在」时也会自停，漏调 unwatch 不会泄漏轮询）。
class CastRelayProbe {
  /// [diagnostics] 为转写目标（默认全局采集点；测试注入独立实例）。
  CastRelayProbe({CastDiagnostics? diagnostics})
      : _diagnostics = diagnostics ?? CastDiagnostics.instance;

  /// 全局单例：同一时刻只有一个中继会话在跑（起新会话前会停旧的）。
  static final CastRelayProbe instance = CastRelayProbe();

  final CastDiagnostics _diagnostics;

  static const Duration interval = Duration(seconds: 3);

  CastRelayStatusReader? _reader;
  String? _session;
  Timer? _timer;
  int _lastSeq = 0;

  bool get watching => _timer != null;

  /// 开始跟随一个中继会话（重复调用 = 换会话）。
  void watch(CastRelayStatusReader reader, String session) {
    _reader = reader;
    _session = session;
    _lastSeq = 0;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => unawaited(pollOnce()));
    unawaited(pollOnce());
  }

  /// 停止跟随（会话已停/已断开时调用；探针自停后调用无害）。
  void unwatch() {
    _timer?.cancel();
    _timer = null;
    _reader = null;
    _session = null;
  }

  /// 拉一次状态并转写新增记录（公开供测试驱动）。
  Future<void> pollOnce() async {
    final reader = _reader;
    final session = _session;
    if (reader == null || session == null) return;
    try {
      final status = await reader(session);
      // R3：转写中继会话的监听 IP/端口/URL 进诊断目标字段（会话激活期间）。
      // 面板防火墙指引消费 selectedIp/mediaPort——中继投屏时同样可见；
      // setTarget 只覆盖非 null 项，旧版核心缺字段时不误清已有值。
      final lan = status['lanIp']?.toString() ?? '';
      final port = (status['port'] as num?)?.toInt();
      final url = status['url']?.toString() ?? '';
      if (lan.isNotEmpty || port != null || url.isNotEmpty) {
        _diagnostics.setTarget(
          selectedIp: lan.isEmpty ? null : lan,
          mediaPort: port,
          mediaUrl: url.isEmpty ? null : url,
        );
      }
      final recent = status['recent'];
      if (recent is! List) return;
      for (final raw in recent) {
        if (raw is! Map) continue;
        final seq = (raw['seq'] as num?)?.toInt() ?? 0;
        if (seq <= _lastSeq) continue;
        _lastSeq = seq;
        final range = raw['range']?.toString() ?? '';
        final ua = raw['ua']?.toString() ?? '';
        _diagnostics.recordMediaRequest(MediaRequestTrace(
          url: raw['path']?.toString() ?? '',
          method: 'GET',
          range: range.isEmpty ? null : range,
          userAgent: ua.isEmpty ? null : ua,
          statusCode: (raw['status'] as num?)?.toInt() ?? 0,
          bytesServed: (raw['bytes'] as num?)?.toInt() ?? 0,
          source: 'relay',
        ));
      }
    } on AquaException catch (e, stack) {
      // 会话已被回收（castRelayStop/空闲超时）：探针自停。
      if (e.code == AquaCode.castRelayNoSession) {
        unwatch();
        return;
      }
      try {
        ErrorLog.instance.record('中继取流日志查询', e, stack);
      } catch (_) {}
    } on Exception catch (e, stack) {
      // 单次查询失败容忍（网络抖动），下一轮再拉。
      try {
        ErrorLog.instance.record('中继取流日志查询', e, stack);
      } catch (_) {}
    } catch (_) {
      // 诊断采集绝不能影响投屏主链路。
    }
  }
}
