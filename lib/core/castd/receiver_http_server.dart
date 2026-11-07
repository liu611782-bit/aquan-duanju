/// 接收端 HTTP 服务（蓝本 DlnaHttpServer.kt 语义移植，改用 dart:io
/// HttpServer）：描述 / SCPD / SOAP control / GENA eventSub 四类路由。
///
/// 安全边界：只伺服描述与 SCPD（不回显任意文件路径）；请求体上限
/// 256KB；日志不落 URL/投送内容（异常才进 ErrorLog）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import '../error_log.dart';
import 'receiver_descriptions.dart';
import 'receiver_gena.dart';
import 'receiver_renderer.dart';
import 'receiver_ssdp.dart';

/// 请求体上限（蓝本 MAX_BODY_BYTES）。
const int receiverMaxBodyBytes = 256 * 1024;

class ReceiverHttpServer {
  ReceiverHttpServer({
    required this.renderer,
    required this.gena,
    required this.describe,
    this.preferredPort = 18099,
    this.portAttempts = 20,
  });

  final ReceiverRenderer renderer;
  final ReceiverGena gena;
  final String Function() describe;

  /// 偏好端口，占用顺延（PRD R2.1：18099 起）。
  final int preferredPort;
  final int portAttempts;

  HttpServer? _server;

  /// 实际监听端口；未启动为 null。
  int? get port => _server?.port;

  bool get running => _server != null;

  /// 绑定 anyIPv4；[preferredPort] 起连续 [portAttempts] 个端口都占用则抛。
  Future<void> start() async {
    if (_server != null) return;
    Object? lastError;
    StackTrace? lastStack;
    for (var i = 0; i < portAttempts; i++) {
      try {
        _server = await HttpServer.bind(
          InternetAddress.anyIPv4,
          preferredPort + i,
        );
        break;
      } on SocketException catch (e, st) {
        lastError = e;
        lastStack = st;
      }
    }
    if (_server == null) {
      ErrorLog.instance.record(
        'DLNA 接收·HTTP 绑定',
        lastError ?? StateError('端口被占满'),
        lastStack,
      );
      throw StateError(
        '接收端 HTTP 端口 $preferredPort 起 $portAttempts 个均被占用',
      );
    }
    _server!.listen(
      (req) async {
        try {
          await _serve(req);
        } catch (e, st) {
          ErrorLog.instance.record('DLNA 接收·HTTP', e, st);
          try {
            req.response.statusCode = 500;
            await req.response.close();
          } catch (_) {}
        }
      },
      onError: (Object e, StackTrace st) {
        ErrorLog.instance.record('DLNA 接收·HTTP 监听', e, st);
      },
      cancelOnError: false,
    );
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _serve(HttpRequest req) async {
    final method = req.method.toUpperCase();
    final path = req.uri.path;

    // 设备描述：GET/HEAD。
    if (path == receiverDescriptionPath) {
      if (method != 'GET' && method != 'HEAD') {
        await _respond(req, 405, 'Method Not Allowed');
        return;
      }
      await _respondXml(req, 200, describe());
      return;
    }

    // SCPD：GET/HEAD。
    final scpd = ReceiverService.byScpdPath(path);
    if (scpd != null) {
      if (method != 'GET' && method != 'HEAD') {
        await _respond(req, 405, 'Method Not Allowed');
        return;
      }
      await _respondXml(req, 200, receiverScpd(scpd));
      return;
    }

    // SOAP control：POST（SOAP 1.1 SOAPACTION 头 / 1.2 Content-Type 均兼容）。
    final control = ReceiverService.byControlPath(path);
    if (control != null) {
      if (method != 'POST') {
        await _respond(req, 405, 'Method Not Allowed');
        return;
      }
      await _control(req, control);
      return;
    }

    // GENA eventSub：SUBSCRIBE / UNSUBSCRIBE。
    final event = ReceiverService.byEventPath(path);
    if (event != null) {
      if (method == 'SUBSCRIBE') {
        await _subscribe(req, event);
        return;
      }
      if (method == 'UNSUBSCRIBE') {
        gena.unsubscribe(req.headers.value('sid'));
        await _respond(req, 200, 'OK');
        return;
      }
      await _respond(req, 405, 'Method Not Allowed');
      return;
    }

    await _respond(req, 404, 'Not Found');
  }

  Future<void> _control(HttpRequest req, ReceiverService service) async {
    final body = await _readBody(req);
    // SOAPACTION 头解析含引号；SOAP 1.2 的 action 参数不单独解析——
    // 动作名以请求体首个 Body 子元素为准，头只是回退。
    final action =
        parseSoapRequest(body, req.headers.value('soapaction'));
    if (action == null) {
      await _respond(req, 400, 'Bad Request');
      return;
    }
    final senderAddress = req.connectionInfo?.remoteAddress.address ?? '';
    final senderUserAgent = req.headers.value('user-agent') ?? '';
    try {
      final out = await renderer.handle(
        service: service,
        action: action,
        senderAddress: senderAddress,
        senderUserAgent: senderUserAgent,
      );
      await _respondXml(
        req,
        200,
        soapResponseXml(service.type, action.name, out),
      );
    } on ReceiverFault catch (fault) {
      await _respondXml(req, 500, soapFaultXml(fault));
    }
  }

  Future<void> _subscribe(HttpRequest req, ReceiverService service) async {
    final result = gena.subscribe(
      service,
      req.headers.value('sid'),
      req.headers.value('callback'),
      req.headers.value('timeout'),
    );
    if (result == null) {
      // 未知续订 / 缺 CALLBACK：412 Precondition Failed（UPnP GENA 规范）。
      await _respond(req, 412, 'Precondition Failed');
      return;
    }
    final (sid, seconds) = result;
    req.response.statusCode = 200;
    req.response.headers.set('SID', sid);
    req.response.headers.set('TIMEOUT', 'Second-$seconds');
    req.response.headers.set('Server', ReceiverSsdp.serverProduct);
    await req.response.close();
  }

  Future<void> _respond(HttpRequest req, int status, String reason) async {
    req.response.statusCode = status;
    req.response.reasonPhrase = reason;
    req.response.headers.set('Server', ReceiverSsdp.serverProduct);
    await req.response.close();
  }

  Future<void> _respondXml(HttpRequest req, int status, String body) async {
    req.response.statusCode = status;
    req.response.headers.contentType =
        ContentType('text', 'xml', charset: 'utf-8');
    req.response.headers.set('Server', ReceiverSsdp.serverProduct);
    req.response.write(body);
    await req.response.close();
  }

  Future<String> _readBody(HttpRequest req) async {
    // 超限时也要把请求体读完再拒绝：提前断开会让发送端拿到
    // 「连接关闭」而不是 4xx/5xx（Windows 端客户端实测会抛
    // Connection closed before full header was received）。
    final builder = BytesBuilder(copy: false);
    var overflown = false;
    await for (final chunk in req) {
      if (!overflown) {
        builder.add(chunk);
        if (builder.length > receiverMaxBodyBytes) {
          overflown = true;
          builder.clear();
        }
      }
    }
    if (overflown) {
      throw const _BodyTooLarge();
    }
    return utf8.decode(builder.toBytes(), allowMalformed: true);
  }
}

class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}
