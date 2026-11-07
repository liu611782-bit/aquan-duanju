/// GENA 事件订阅（蓝本 DlnaEvents.kt / Gena object 语义移植）：
/// SUBSCRIBE 生成 SID、续订刷新过期；事件化状态变化（1s 检查窗）以
/// NOTIFY LastChange 单播到订阅者 callback；投递失败静默移除订阅者
/// （design.md §5，订阅者断开容忍由过期清理兜底）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../error_log.dart';
import 'receiver_descriptions.dart';
import 'receiver_renderer.dart';

/// CALLBACK 头里的 URL 列表（`<http://…>`，只认 http）。
List<String> genaCallbacks(String? header) {
  final matches =
      RegExp(r'<([^>]+)>').allMatches(header ?? '').map((m) => m.group(1)!.trim());
  return matches.where((url) => url.startsWith('http://')).toList();
}

/// TIMEOUT 头（`Second-1800` / `Second-infinite`）→ 秒；钳 60..1800，
/// 缺省/不可解析回 [defaultSec]（design §5 默认 300s；蓝本钳制口径）。
int genaTimeoutSeconds(String? header, {int defaultSec = 300}) {
  final value =
      int.tryParse((header ?? '').trim().split('Second-').last.trim());
  if (value == null) return defaultSec;
  return value < 60 ? 60 : (value > 1800 ? 1800 : value);
}

/// NOTIFY body：propertyset → LastChange（转义内嵌 XML）。
/// AVT 用 `…/metadata-1-0/AVT/` 命名空间；RCS 用 `…/RCS/` 且每项带
/// `channel="Master"`。自家发送端 `parseAvtLastChange` 可直接解析
/// （互操作断言在 test/castd/receiver_gena_test.dart）。
String genaPropertySet(
  ReceiverService service,
  List<(String, String)> values,
) {
  final isRcs = service == ReceiverService.renderingControl;
  final namespace = isRcs
      ? 'urn:schemas-upnp-org:metadata-1-0/RCS/'
      : 'urn:schemas-upnp-org:metadata-1-0/AVT/';
  final channel = isRcs ? ' channel="Master"' : '';
  final inner = StringBuffer('<Event xmlns="$namespace">')
    ..write('<InstanceID val="0">');
  for (final (name, value) in values) {
    inner.write('<$name val="${xmlEscape(value)}"$channel/>');
  }
  inner.write('</InstanceID></Event>');
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
      '<e:property><LastChange>${xmlEscape(inner.toString())}'
      '</LastChange></e:property></e:propertyset>';
}

class _GenaSubscription {
  _GenaSubscription({
    required this.service,
    required this.callbacks,
    required this.expiresAt,
  });

  final ReceiverService service;
  final List<String> callbacks;
  DateTime expiresAt;
  int seq = 0;
  List<(String, String)>? lastSent;
}

class ReceiverGena {
  ReceiverGena({
    required this.renderer,
    this.checkInterval = const Duration(seconds: 1),
    this.initialEventDelay = const Duration(milliseconds: 200),
    this.connectTimeout = const Duration(seconds: 3),
  });

  final ReceiverRenderer renderer;
  final Duration checkInterval;
  final Duration initialEventDelay;
  final Duration connectTimeout;

  final Map<String, _GenaSubscription> _subscriptions = {};
  Timer? _timer;

  /// 订阅（sid 为 null）或续订（sid 非 null）。未知续订返回 null → HTTP 412。
  (String, int)? subscribe(
    ReceiverService service,
    String? sid,
    String? callbackHeader,
    String? timeoutHeader,
  ) {
    final seconds = genaTimeoutSeconds(timeoutHeader);
    if (sid != null && sid.isNotEmpty) {
      final existing = _subscriptions[sid];
      if (existing == null) return null;
      existing.expiresAt = DateTime.now().add(Duration(seconds: seconds));
      return (sid, seconds);
    }
    final callbacks = genaCallbacks(callbackHeader);
    if (callbacks.isEmpty) return null;
    final newSid = 'uuid:${uuidV4()}';
    _subscriptions[newSid] = _GenaSubscription(
      service: service,
      callbacks: callbacks,
      expiresAt: DateTime.now().add(Duration(seconds: seconds)),
    );
    // 初始事件（全量状态）在 SUBSCRIBE 应答之后发出（蓝本 200ms 延迟）。
    Timer(initialEventDelay, () {
      final sub = _subscriptions[newSid];
      if (sub == null) return;
      unawaited(_send(newSid, sub, renderer.eventValues(sub.service)));
    });
    return (newSid, seconds);
  }

  void unsubscribe(String? sid) {
    if (sid == null || sid.isEmpty) return;
    _subscriptions.remove(sid);
  }

  /// 启动状态变化检查循环。
  void start() {
    if (_timer != null) return;
    _timer = Timer.periodic(checkInterval, (_) {
      try {
        checkNow();
      } catch (e, st) {
        ErrorLog.instance.record('DLNA 接收·GENA 检查', e, st);
      }
    });
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _subscriptions.clear();
  }

  /// 立即执行一轮过期清理 + 变化检查（测试钩子；定时器到期同样走这里）。
  void checkNow() {
    final now = DateTime.now();
    _subscriptions.removeWhere((_, sub) => sub.expiresAt.isBefore(now));
    for (final entry in _subscriptions.entries) {
      final sub = entry.value;
      if (sub.lastSent == null) continue; // 初始事件尚未发出
      final current = renderer.eventValues(sub.service);
      if (!_listEquals(current, sub.lastSent!)) {
        unawaited(_send(entry.key, sub, current));
      }
    }
  }

  Future<void> _send(
    String sid,
    _GenaSubscription sub,
    List<(String, String)> values,
  ) async {
    sub.lastSent = values;
    if (values.isEmpty) return;
    final body = genaPropertySet(sub.service, values);
    final seq = sub.seq++;
    for (final callback in sub.callbacks) {
      // UPnP 要求按序尝试 callback 直到有一个接受。
      if (await _post(callback, sid, seq, body)) return;
    }
    // 所有 callback 投递失败：静默移除（design.md §5；订阅者断开容忍——
    // 死订阅者不再重试打扰，重投由发送端重新 SUBSCRIBE）。
    _subscriptions.remove(sid);
  }

  /// NOTIFY 用 raw Socket 发送（dart:io HttpClient 不支持 NOTIFY 方法）。
  Future<bool> _post(String callback, String sid, int seq, String body) async {
    final uri = Uri.tryParse(callback);
    if (uri == null || uri.host.isEmpty) return false;
    final port = uri.port > 0 ? uri.port : 80;
    final path = (uri.path.isEmpty ? '/' : uri.path) +
        (uri.query.isEmpty ? '' : '?${uri.query}');
    final bytes = utf8.encode(body);
    final head = 'NOTIFY $path HTTP/1.1\r\n'
        'HOST: ${uri.host}:$port\r\n'
        'CONTENT-TYPE: text/xml; charset="utf-8"\r\n'
        'NT: upnp:event\r\n'
        'NTS: upnp:propchange\r\n'
        'SID: $sid\r\n'
        'SEQ: $seq\r\n'
        'CONTENT-LENGTH: ${bytes.length}\r\n'
        'CONNECTION: close\r\n\r\n';
    Socket? socket;
    try {
      socket = await Socket.connect(uri.host, port, timeout: connectTimeout);
      // 头与体一次性写入：分两次 add 时，订阅端可能先看到头结束符而把空
      // 体交给解析器（事件丢失）。
      final packet = <int>[...utf8.encode(head), ...bytes];
      socket.add(packet);
      await socket.flush();
      // 读状态行判定送达（订阅者的 200 OK）。
      final line = await utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .first
          .timeout(connectTimeout);
      final parts = line.split(' ');
      return parts.length > 1 && parts[1].startsWith('2');
    } catch (_) {
      return false;
    } finally {
      try {
        socket?.destroy();
      } catch (_) {}
    }
  }
}

bool _listEquals(List<(String, String)> a, List<(String, String)> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
