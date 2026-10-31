import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'idn.dart';
import 'source_adapter.dart';
import 'source_import.dart';

/// 载荷格式（与解码链一一对应）。
enum PayloadFormat {
  json('JSON'),
  lenientJson('宽松JSON'),
  base64('Base64'),
  stego('隐写'),
  catvodAes('AES'),
  unknown('未知');

  const PayloadFormat(this.label);

  final String label;
}

/// 安全标记。
enum SecurityFlag {
  httpsSafe('HTTPS'),
  cleartextHttp('明文HTTP'),
  cleartextSpiderJar('明文jar');

  const SecurityFlag(this.label);

  final String label;
}

/// 一次探测抓取的结果（TTFB 与总耗时在同一个请求里测量）。
class FetchResult {
  const FetchResult({
    required this.ok,
    this.statusCode = 0,
    this.ttfbMs = 0,
    this.totalMs = 0,
    this.sizeKb = 0,
    this.bytes,
    this.finalUrl = '',
    this.isHttps = false,
    this.error = '',
  });

  final bool ok;
  final int statusCode;

  /// 响应头到达耗时。
  final int ttfbMs;

  /// body 读完耗时。
  final int totalMs;
  final double sizeKb;
  final Uint8List? bytes;
  final String finalUrl;
  final bool isHttps;

  /// 已中文化的失败原因。
  final String error;

  double get speedKbps {
    final transfer = totalMs - ttfbMs;
    if (sizeKb <= 0) return 0;
    if (transfer <= 0) return sizeKb * 1000;
    return sizeKb / transfer * 1000;
  }

  String get text {
    final data = bytes;
    if (data == null) return '';
    return utf8.decode(data, allowMalformed: true);
  }
}

/// TVBox 客户端常用 UA：很多配置站按 UA 白名单放行。
const String kTvBoxUserAgent = 'okhttp/3.15';

const int kMaxProbeBytes = 4 * 1024 * 1024;
const int kMaxRedirects = 5;

/// 流式抓取并同时测量 TTFB / 总耗时 / 体积。
///
/// 手动跟随重定向（`followRedirects = false`），每一跳都过一遍 SSRF 校验，
/// 避免「首跳合法、30x 跳到内网」的绕过。
Future<FetchResult> fetchProbe(
  String url, {
  Duration connectTimeout = const Duration(milliseconds: 4500),
  Duration readTimeout = const Duration(milliseconds: 5500),
  int maxBytes = kMaxProbeBytes,
  Map<String, String> headers = const <String, String>{},
  CancelToken? cancel,
  http.Client? client,
  bool enforceSsrf = true,
}) async {
  final own = client ?? http.Client();
  final stopwatch = Stopwatch()..start();
  final deadline = connectTimeout + readTimeout + const Duration(milliseconds: 1500);
  var current = url.trim();
  try {
    if (enforceSsrf) {
      try {
        SourceImporter.validateImportUrl(current);
      } on SourceException catch (e) {
        return FetchResult(
          ok: false,
          error: e.detail.isEmpty ? '地址不合法' : e.detail,
        );
      }
    }

    http.StreamedResponse? response;
    for (var hop = 0; hop <= kMaxRedirects; hop++) {
      if (cancel?.isCancelled ?? false) {
        return FetchResult(ok: false, error: '已取消');
      }
      final request = http.Request('GET', Uri.parse(current))
        ..followRedirects = false
        ..headers.addAll(<String, String>{
          'User-Agent': kTvBoxUserAgent,
          'Accept': 'application/json, text/plain, */*',
          'Accept-Encoding': 'gzip, deflate',
          ...headers,
        });
      final streamed = await own.send(request).timeout(connectTimeout);
      if (streamed.isRedirect) {
        final location = streamed.headers['location'] ?? '';
        await streamed.stream.drain<void>();
        if (location.isEmpty) {
          return FetchResult(
            ok: false,
            statusCode: streamed.statusCode,
            ttfbMs: stopwatch.elapsedMilliseconds,
            error: '重定向缺少 Location',
          );
        }
        current = uriForRequest(current).resolve(location).toString();
        if (enforceSsrf) {
          try {
            SourceImporter.validateImportUrl(current);
          } on SourceException catch (e) {
            return FetchResult(
              ok: false,
              error: '安全拦截重定向：${e.detail.isEmpty ? e.code.name : e.detail}',
            );
          }
        }
        continue;
      }
      response = streamed;
      break;
    }

    if (response == null) {
      return FetchResult(ok: false, error: '重定向次数过多');
    }

    final ttfb = stopwatch.elapsedMilliseconds;
    final code = response.statusCode;
    final isHttps = current.toLowerCase().startsWith('https://');

    if (code < 200 || code >= 300) {
      await response.stream.drain<void>();
      return FetchResult(
        ok: false,
        statusCode: code,
        ttfbMs: ttfb,
        totalMs: ttfb,
        finalUrl: current,
        isHttps: isHttps,
        error: 'HTTP $code',
      );
    }

    final declared = response.contentLength;
    if (declared != null && declared > maxBytes) {
      await response.stream.drain<void>();
      return FetchResult(
        ok: false,
        statusCode: code,
        ttfbMs: ttfb,
        totalMs: ttfb,
        finalUrl: current,
        isHttps: isHttps,
        error: '响应体积超限（${declared ~/ 1024}KB > ${maxBytes ~/ 1024}KB）',
      );
    }

    final builder = BytesBuilder(copy: false);
    await for (final chunk in response.stream.timeout(readTimeout)) {
      if (cancel?.isCancelled ?? false) {
        return FetchResult(
          ok: false,
          statusCode: code,
          ttfbMs: ttfb,
          finalUrl: current,
          isHttps: isHttps,
          error: '已取消',
        );
      }
      builder.add(chunk);
      if (builder.length > maxBytes) {
        return FetchResult(
          ok: false,
          statusCode: code,
          ttfbMs: ttfb,
          totalMs: stopwatch.elapsedMilliseconds,
          finalUrl: current,
          isHttps: isHttps,
          error: '流式下载超限（>${maxBytes ~/ 1024}KB），已阻断',
        );
      }
      if (stopwatch.elapsed > deadline) {
        return FetchResult(
          ok: false,
          statusCode: code,
          ttfbMs: ttfb,
          totalMs: stopwatch.elapsedMilliseconds,
          finalUrl: current,
          isHttps: isHttps,
          error: '连接/读取超时',
        );
      }
    }

    final bytes = builder.takeBytes();
    final total = stopwatch.elapsedMilliseconds < ttfb
        ? ttfb
        : stopwatch.elapsedMilliseconds;
    return FetchResult(
      ok: true,
      statusCode: code,
      ttfbMs: ttfb,
      totalMs: total,
      sizeKb: bytes.length / 1024,
      bytes: bytes,
      finalUrl: current,
      isHttps: isHttps,
    );
  } on TimeoutException {
    return FetchResult(
      ok: false,
      ttfbMs: stopwatch.elapsedMilliseconds,
      error: '连接/读取超时',
    );
  } catch (e) {
    return FetchResult(
      ok: false,
      ttfbMs: stopwatch.elapsedMilliseconds,
      error: friendlyFetchError(e),
    );
  } finally {
    if (client == null) own.close();
  }
}

/// 把底层异常翻成人话，UI 直接展示。
String friendlyFetchError(Object error) {
  final text = error.toString();
  final lower = text.toLowerCase();
  if (lower.contains('socketexception') || lower.contains('failed host lookup')) {
    return '域名解析失败';
  }
  if (lower.contains('handshake') || lower.contains('certificate')) {
    return 'TLS 握手失败';
  }
  if (lower.contains('connection refused')) return '连接被拒绝';
  if (lower.contains('connection closed') || lower.contains('reset')) {
    return '连接被重置';
  }
  if (lower.contains('timeout')) return '连接/读取超时';
  if (lower.contains('format')) return 'URL 无法解析';
  return text.length > 80 ? '${text.substring(0, 80)}…' : text;
}

/// 按原文特征判断载荷格式（用于结果徽标，不改变解码链本身）。
PayloadFormat detectPayloadFormat(String raw) {
  var text = raw.trim();
  if (text.startsWith(String.fromCharCode(0xFEFF))) {
    text = text.substring(1);
  }
  final pre = RegExp(r'<pre[^>]*>([\s\S]*?)</pre>', caseSensitive: false)
      .firstMatch(text);
  if (pre != null) {
    final inner = pre.group(1)?.trim();
    if (inner != null && inner.isNotEmpty) return detectPayloadFormat(inner);
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    return _hasRelaxedSyntax(text) ? PayloadFormat.lenientJson : PayloadFormat.json;
  }
  if (text.startsWith('2423')) return PayloadFormat.catvodAes;
  if (RegExp(r'[A-Za-z0-9]{8}\*\*').hasMatch(text)) return PayloadFormat.stego;
  final squeezed = text.replaceAll(RegExp(r'\s+'), '');
  if (squeezed.length > 16 && RegExp(r'^[A-Za-z0-9+/\-_=]+$').hasMatch(squeezed)) {
    return PayloadFormat.base64;
  }
  if (text.contains('{')) {
    return PayloadFormat.lenientJson;
  }
  return PayloadFormat.unknown;
}

bool _hasRelaxedSyntax(String text) {
  // 字符串内部出现 `//` 不算注释；这里只做粗判，够用即可。
  return RegExp(r'^\s*//|,\s*[}\]]', multiLine: true).hasMatch(text) ||
      text.contains("'");
}
