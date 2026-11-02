/// 远端存储抽象 + 两个实现：WebDAV、S3 兼容（MinIO/R2/OSS 的 S3 接口）。
///
/// 只依赖 `http` + `crypto`：签名逻辑抽成纯函数 [S3Signer]，可脱离网络单测。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// 远端对象。
class RemoteObject {
  const RemoteObject({
    required this.path,
    required this.size,
    required this.modified,
  });

  final String path;
  final int size;
  final DateTime modified;
}

/// 远端失败（带可读原因，UI 直接展示）。
class RemoteStoreException implements Exception {
  const RemoteStoreException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 远端存储。
abstract class RemoteStore {
  /// 人类可读的名字（日志/UI）。
  String get label;

  /// 列目录（前缀匹配，结果为相对路径）。
  Future<List<RemoteObject>> list(String prefix);

  Future<Uint8List?> get(String path);

  Future<void> put(String path, Uint8List bytes);

  /// 连通性自检（不写入）。
  Future<void> ping();
}

// ---------------------------------------------------------------------------
// WebDAV
// ---------------------------------------------------------------------------

class WebDavStore implements RemoteStore {
  WebDavStore({
    required String baseUrl,
    this.username = '',
    this.password = '',
    http.Client? client,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        _client = client ?? http.Client();

  final String baseUrl;
  final String username;
  final String password;
  final http.Client _client;

  @override
  String get label => 'WebDAV';

  Map<String, String> get _auth => {
        if (username.isNotEmpty)
          'Authorization':
              'Basic ${base64Encode(utf8.encode('$username:$password'))}',
      };

  @override
  Future<void> ping() async {
    final response = await _send('PROPFIND', '', headers: {'Depth': '0'});
    if (response.statusCode >= 400) {
      throw RemoteStoreException(
          'WebDAV 连接失败（HTTP ${response.statusCode}）：请检查地址与账号');
    }
  }

  @override
  Future<List<RemoteObject>> list(String prefix) async {
    final response = await _send(
      'PROPFIND',
      prefix,
      headers: {'Depth': '1'},
      body: _propfindBody,
    );
    if (response.statusCode >= 400) {
      throw RemoteStoreException('列目录失败（HTTP ${response.statusCode}）');
    }
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    final objects = <RemoteObject>[];
    // 解析 <D:response> 块（namespace 前缀不固定，按 localName 抓）。
    for (final match in RegExp(r'<[^>]*response[^>]*>([\s\S]*?)</[^>]*response>')
        .allMatches(text)) {
      final block = match.group(1) ?? '';
      final href = _tagText(block, 'href');
      if (href.isEmpty) continue;
      final decoded = Uri.decodeFull(href);
      if (decoded.endsWith('/')) continue; // 目录
      final size = int.tryParse(_tagText(block, 'getcontentlength')) ?? 0;
      final modified = DateTime.tryParse(_tagText(block, 'getlastmodified')) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      objects.add(RemoteObject(
        path: _relative(decoded, prefix),
        size: size,
        modified: modified,
      ));
    }
    return objects;
  }

  @override
  Future<Uint8List?> get(String path) async {
    final response = await _send('GET', path);
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) {
      throw RemoteStoreException('下载失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    await _ensureDirs(path);
    final response = await _send('PUT', path, body: bytes);
    if (response.statusCode >= 400) {
      throw RemoteStoreException('上传失败（HTTP ${response.statusCode}）');
    }
  }

  Future<void> _ensureDirs(String path) async {
    final segments = path.split('/')..removeLast();
    var current = '';
    for (final segment in segments) {
      if (segment.isEmpty) continue;
      current = current.isEmpty ? segment : '$current/$segment';
      await _send('MKCOL', '$current/');
    }
  }

  Future<http.Response> _send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    Object? body,
  }) async {
    final uri = Uri.parse(path.isEmpty ? baseUrl : '$baseUrl/$path');
    final request = http.Request(method, uri)
      ..headers.addAll(_auth)
      ..headers.addAll(headers);
    if (body != null) {
      if (body is Uint8List || body is List<int>) {
        request.bodyBytes = body as List<int>;
      } else {
        request.body = body.toString();
      }
    }
    final streamed = await _client.send(request);
    return http.Response.fromStream(streamed);
  }

  static const String _propfindBody = '''<?xml version="1.0"?>
<d:propfind xmlns:d="DAV:"><d:prop>
  <d:getcontentlength/><d:getlastmodified/><d:resourcetype/>
</d:prop></d:propfind>''';

  static String _tagText(String block, String localName) {
    final match = RegExp('<$localName[^>]*>([\\s\\S]*?)</$localName>',
            caseSensitive: false)
        .firstMatch(block);
    if (match != null) return match.group(1)?.trim() ?? '';
    // 带前缀：<D:href>…</D:href>
    final prefixed = RegExp(':[^>]*$localName[^>]*>([\\s\\S]*?)<',
            caseSensitive: false)
        .firstMatch(block);
    return prefixed?.group(1)?.trim() ?? '';
  }

  static String _relative(String href, String prefix) {
    final index = href.indexOf(prefix);
    if (index < 0) {
      final trimmed = href.startsWith('/') ? href.substring(1) : href;
      return trimmed;
    }
    return href.substring(index);
  }
}

// ---------------------------------------------------------------------------
// S3（SigV4 签名）
// ---------------------------------------------------------------------------

/// SigV4 签名（纯函数，可单测）。
class S3Signer {
  const S3Signer({
    required this.accessKey,
    required this.secretKey,
    required this.region,
    this.service = 's3',
  });

  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  /// 返回需要附加的请求头（含 Authorization）。
  Map<String, String> sign({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required DateTime now,
    Uint8List? payload,
  }) {
    final amzDate =
        '${now.toUtc().toIso8601String().split('.').first.replaceAll(RegExp(r'[-:]'), '')}Z';
    final dateStamp = amzDate.substring(0, 8);
    final payloadHash = sha256.convert(payload ?? Uint8List(0)).toString();

    final signed = <String, String>{
      'host': uri.host,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      ...{
        for (final entry in headers.entries)
          entry.key.toLowerCase(): entry.value,
      },
    };
    // host 必须带端口（非默认端口）。
    if (uri.hasPort &&
        !((uri.scheme == 'https' && uri.port == 443) ||
            (uri.scheme == 'http' && uri.port == 80))) {
      signed['host'] = '${uri.host}:${uri.port}';
    }

    final sortedKeys = signed.keys.toList()..sort();
    final canonicalHeaders =
        sortedKeys.map((k) => '$k:${signed[k]!.trim()}\n').join();
    final signedHeaders = sortedKeys.join(';');

    final canonicalQuery = (uri.queryParameters.entries.toList()
          ..sort((a, b) => a.key.compareTo(b.key)))
        .map((e) =>
            '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');

    final canonicalRequest = [
      method,
      uri.path.isEmpty ? '/' : uri.path,
      canonicalQuery,
      canonicalHeaders,
      signedHeaders,
      payloadHash,
    ].join('\n');

    final scope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = [
      'AWS4-HMAC-SHA256',
      amzDate,
      scope,
      sha256.convert(utf8.encode(canonicalRequest)).toString(),
    ].join('\n');

    final signingKey = _signingKey(dateStamp);
    final signature = Hmac(sha256, signingKey)
        .convert(utf8.encode(stringToSign))
        .toString();

    return {
      'host': signed['host']!,
      'x-amz-content-sha256': payloadHash,
      'x-amz-date': amzDate,
      'Authorization':
          'AWS4-HMAC-SHA256 Credential=$accessKey/$scope, '
              'SignedHeaders=$signedHeaders, Signature=$signature',
    };
  }

  Uint8List _signingKey(String dateStamp) {
    Uint8List hmac(List<int> key, String data) =>
        Uint8List.fromList(Hmac(sha256, key).convert(utf8.encode(data)).bytes);
    final kDate = hmac(utf8.encode('AWS4$secretKey'), dateStamp);
    final kRegion = hmac(kDate, region);
    final kService = hmac(kRegion, service);
    return hmac(kService, 'aws4_request');
  }
}

class S3Store implements RemoteStore {
  S3Store({
    required String endpoint,
    required this.bucket,
    required this.accessKey,
    required this.secretKey,
    this.region = 'us-east-1',
    this.prefix = '',
    http.Client? client,
  })  : endpoint = endpoint.endsWith('/')
            ? endpoint.substring(0, endpoint.length - 1)
            : endpoint,
        _client = client ?? http.Client();

  /// `https://s3.amazonaws.com` 或自建 MinIO 地址。
  final String endpoint;
  final String bucket;
  final String accessKey;
  final String secretKey;
  final String region;

  /// 对象前缀（如 `aquan/`）。
  final String prefix;

  final http.Client _client;

  @override
  String get label => 'S3';

  S3Signer get _signer => S3Signer(
        accessKey: accessKey,
        secretKey: secretKey,
        region: region,
      );

  Uri _uri(String path, {Map<String, String>? query}) {
    final base = Uri.parse(endpoint);
    final fullPath = [
      if (base.path.isNotEmpty) base.path.replaceAll(RegExp(r'/$'), ''),
      bucket,
      if (path.isNotEmpty) path,
    ].join('/');
    return base.replace(
      path: fullPath.startsWith('/') ? fullPath : '/$fullPath',
      queryParameters: query,
    );
  }

  @override
  Future<void> ping() async {
    final uri = _uri('', query: {'list-type': '2', 'max-keys': '1'});
    final headers = _signer.sign(
      method: 'GET',
      uri: uri,
      headers: const {},
      now: DateTime.now(),
    );
    final response = await _client.get(uri, headers: headers);
    if (response.statusCode >= 400) {
      throw RemoteStoreException(
          'S3 连接失败（HTTP ${response.statusCode}）：${_errorText(response.body)}');
    }
  }

  @override
  Future<List<RemoteObject>> list(String prefixPath) async {
    final uri = _uri('', query: {
      'list-type': '2',
      'prefix': _key(prefixPath),
    });
    final headers = _signer.sign(
      method: 'GET',
      uri: uri,
      headers: const {},
      now: DateTime.now(),
    );
    final response = await _client.get(uri, headers: headers);
    if (response.statusCode >= 400) {
      throw RemoteStoreException('列对象失败（HTTP ${response.statusCode}）');
    }
    final xml = response.body;
    final objects = <RemoteObject>[];
    for (final block in RegExp(r'<Contents>([\s\S]*?)</Contents>')
        .allMatches(xml)) {
      final text = block.group(1) ?? '';
      final key = RegExp(r'<Key>([\s\S]*?)</Key>').firstMatch(text)?.group(1) ?? '';
      if (key.isEmpty) continue;
      final size =
          int.tryParse(RegExp(r'<Size>(\d+)</Size>').firstMatch(text)?.group(1) ?? '') ??
              0;
      final modified = DateTime.tryParse(
              RegExp(r'<LastModified>([\s\S]*?)</LastModified>')
                      .firstMatch(text)
                      ?.group(1) ??
                  '') ??
          DateTime.fromMillisecondsSinceEpoch(0);
      objects.add(RemoteObject(
        path: _stripPrefix(key),
        size: size,
        modified: modified,
      ));
    }
    return objects;
  }

  @override
  Future<Uint8List?> get(String path) async {
    final uri = _uri(_key(path));
    final headers = _signer.sign(
      method: 'GET',
      uri: uri,
      headers: const {},
      now: DateTime.now(),
    );
    final response = await _client.get(uri, headers: headers);
    if (response.statusCode == 404) return null;
    if (response.statusCode >= 400) {
      throw RemoteStoreException('下载失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  @override
  Future<void> put(String path, Uint8List bytes) async {
    final uri = _uri(_key(path));
    final headers = _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: {'content-type': 'application/octet-stream'},
      now: DateTime.now(),
      payload: bytes,
    );
    final response = await _client.put(
      uri,
      headers: {...headers, 'content-type': 'application/octet-stream'},
      body: bytes,
    );
    if (response.statusCode >= 400) {
      throw RemoteStoreException(
          '上传失败（HTTP ${response.statusCode}）：${_errorText(response.body)}');
    }
  }

  String _key(String path) =>
      prefix.isEmpty ? path : '$prefix${path.startsWith('/') ? path.substring(1) : path}';

  String _stripPrefix(String key) =>
      prefix.isEmpty ? key : key.replaceFirst(prefix, '');

  static String _errorText(String body) {
    final code = RegExp(r'<Code>([\s\S]*?)</Code>').firstMatch(body)?.group(1);
    final message =
        RegExp(r'<Message>([\s\S]*?)</Message>').firstMatch(body)?.group(1);
    if (code == null && message == null) return body.length > 120 ? '' : body;
    return [code, message].whereType<String>().join(' / ');
  }
}
