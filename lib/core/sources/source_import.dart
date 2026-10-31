import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'package:meta/meta.dart';

import 'config_decoder.dart';
import 'source_adapter.dart';

/// TVBox 配置里的 jx 解析接口（type=1 JSON 解析）。
class ParseApi {
  const ParseApi({required this.name, required this.url, this.ext = ''});
  final String name;
  final String url;
  final String ext;
}

/// 配置导入/扫描的公共入口：TVBox `sites`、MoonTV `api_site`、多仓
/// `urls`/`storeHouse`（递归 ≤8 层防环）、`名称|地址` 文本行。
///
/// 所有产出经 [validateImportUrl] 做 SSRF 校验；真实内容源地址一律由调用方
/// （用户）提供，本库不内置任何站点。
class SourceImporter {
  const SourceImporter._();

  /// 多仓递归层数上限与单文件大小上限。
  static const int maxDepotDepth = 8;
  static const int maxConfigBytes = 1 << 20; // 1MB

  /// SSRF 守卫开关；单测用本地 HttpServer 夹具时置 false。
  @visibleForTesting
  static bool ssrfGuardEnabled = true;

  /// 第三方源多为明文 http 站，且部分校验 UA；缺省 UA 与请求头在调用处可被源级 header 覆盖。
  static const String defaultUa =
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/120.0.0.0 Mobile Safari/537.36';

  // ---------- 入口 ----------

  /// 从任意文本导入：自动嗅探 JSON / Base64 / 加密配置 / 文本行。
  static Future<ImportReport> importFromText(
    String text, {
    String? sourceUrl,
    ImportReport? report,
    int depth = 0,
    Set<String>? visited,
    CancelToken? cancel,
  }) async {
    final rep = report ?? ImportReport();
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      rep.fail('导入内容为空');
      return rep;
    }

    // 先走解码链：命中即按配置对象解析。
    Map<String, dynamic>? cfg;
    try {
      cfg = ConfigDecoder.decode(trimmed);
    } on SourceException catch (e) {
      // 不是配置形态：回退文本行解析；decodeFailed 之外直接报告。
      if (trimmed.startsWith('{') || trimmed.startsWith('[') ||
          trimmed.startsWith('2423') || trimmed.contains('**')) {
        rep.fail(e.friendlyText);
        return rep;
      }
    }
    if (cfg != null) {
      await _importFromConfig(cfg, sourceUrl, rep, depth, visited ?? <String>{},
          cancel: cancel);
      return rep;
    }

    // 文本行：`名称|地址` 或裸地址，一行一源。
    var matched = 0;
    for (final rawLine in trimmed.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('//') || line.startsWith('#')) {
        continue;
      }
      final sep = line.indexOf('|');
      final name = sep > 0 ? line.substring(0, sep).trim() : '';
      final url = (sep > 0 ? line.substring(sep + 1) : line).trim();
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        rep.fail('无法识别的行：${_clip(line)}');
        continue;
      }
      try {
        validateImportUrl(url);
      } on SourceException catch (e) {
        rep.fail(e.friendlyText);
        continue;
      }
      rep.add(SourceCandidate(
        name: name.isEmpty ? Uri.parse(url).host : name,
        api: url,
        note: sourceUrl == null ? '文本导入' : '来自 ${_hostOf(sourceUrl)}',
      ));
      matched++;
    }
    if (matched == 0 && rep.isEmpty) rep.fail('未发现可导入的源');
    return rep;
  }

  /// 从 URL 导入：下载（10s 超时 / 1MB 上限）→ [importFromText]。
  static Future<ImportReport> importFromUrl(
    String url, {
    CancelToken? cancel,
    Map<String, String>? headers,
    ImportReport? report,
    int depth = 0,
    Set<String>? visited,
  }) async {
    validateImportUrl(url);
    final rep = report ?? ImportReport();
    try {
      final text = await fetchConfigText(url, cancel: cancel, headers: headers);
      return await importFromText(text,
          sourceUrl: url,
          report: rep,
          depth: depth,
          visited: visited,
          cancel: cancel);
    } on SourceException catch (e) {
      rep.fail('${_hostOf(url)}: ${e.friendlyText}');
      return rep;
    } on Exception catch (e) {
      rep.fail('${_hostOf(url)}: 下载失败（${_clip(e.toString())}）');
      return rep;
    }
  }

  /// 下载配置文本：超时 10s、1MB 截断、UA 伪装、[CancelToken] 真取消。
  /// 尊重 http_proxy/https_proxy 环境变量（桌面端走系统代理是常态）。
  static Future<String> fetchConfigText(
    String url, {
    CancelToken? cancel,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 10),
    bool enforceSsrf = true,
  }) async {
    // SSRF 守卫只针对导入期：已入库源的运行时取源（adapter/探测）按
    // 用户主动添加处理，与 probeSource 的 enforceSsrf:false 同口径。
    if (enforceSsrf) validateImportUrl(url);
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..findProxy = HttpClient.findProxyFromEnvironment;
    cancel?.whenCancelled(client.close);
    try {
      final req =
          await client.getUrl(Uri.parse(url)).timeout(timeout);
      req.headers.set(HttpHeaders.userAgentHeader, defaultUa);
      headers?.forEach(req.headers.set);
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw SourceException(SourceExceptionCode.marketFetchFailed,
            'HTTP ${res.statusCode}');
      }
      final length = res.contentLength;
      if (length > maxConfigBytes) {
        await res.drain<void>();
        throw SourceException(
            SourceExceptionCode.marketFetchFailed, '配置超过 1MB 上限');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        if (cancel?.isCancelled ?? false) throw const _Cancelled();
        builder.add(chunk);
        if (builder.length > maxConfigBytes) {
          throw SourceException(
              SourceExceptionCode.marketFetchFailed, '配置超过 1MB 上限');
        }
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } on _Cancelled {
      rethrow;
    } on SourceException {
      rethrow;
    } on Exception catch (e) {
      throw SourceException(
          SourceExceptionCode.marketFetchFailed, _clip(e.toString()));
    } finally {
      // cancel 持有 close 的场景下 close 是幂等的。
      try {
        client.close(force: true);
      } catch (_) {}
    }
  }

  // ---------- 配置对象解析 ----------

  /// 解析配置对象里的站点清单（TVBox sites / MoonTV api_site）。
  static List<SourceCandidate> extractSites(Map cfg, {String? sourceUrl}) {
    final candidates = <SourceCandidate>[];

    // TVBox：单仓优先（同时带 urls 与 sites 时按 sites 处理）。
    final sites = cfg['sites'];
    if (sites is List) {
      for (final item in sites) {
        if (item is! Map) continue;
        final c = _fromTvboxSite(item, sourceUrl);
        if (c != null) candidates.add(c);
      }
      return candidates;
    }

    // MoonTV：{key: {api, name, detail}}。
    final apiSite = cfg['api_site'];
    if (apiSite is Map) {
      apiSite.forEach((key, value) {
        if (value is! Map) return;
        final api = value['api'];
        if (api is! String || api.isEmpty) return;
        candidates.add(SourceCandidate(
          name: (value['name'] as String?)?.isNotEmpty == true
              ? value['name'] as String
              : key.toString(),
          api: _resolveMaybeRelative(api, sourceUrl),
          headers: _parseHeaders(value['header']),
          note: 'MoonTV',
        ));
      });
    }
    return candidates;
  }

  /// 解析 TVBox 顶层 `parses[]`（仅 type=1 JSON 解析接口可用）。
  static List<ParseApi> extractParses(Map cfg) {
    final out = <ParseApi>[];
    final parses = cfg['parses'];
    if (parses is List) {
      for (final item in parses) {
        if (item is! Map) continue;
        final type = item['type'];
        if (type is! num || type != 1) continue; // 0=嗅探 2=JSON扩展，均不用
        final url = item['url'];
        if (url is! String || !url.startsWith('http')) continue;
        out.add(ParseApi(
          name: (item['name'] as String?) ?? '解析',
          url: url,
          ext: item['ext']?.toString() ?? '',
        ));
      }
    }
    return out;
  }

  static SourceCandidate? _fromTvboxSite(Map site, String? sourceUrl) {
    final key = site['key']?.toString() ?? '';
    final name = (site['name'] as String?)?.isNotEmpty == true
        ? site['name'] as String
        : key;
    var api = site['api']?.toString() ?? '';
    final ext = _normalizeExt(site['ext']);

    // 缺省 type 按 1 处理（CineFlow 兼容语义）。
    final typeRaw = site['type'];
    final type = typeRaw is num ? typeRaw.toInt() : 1;

    // csp_AppYs：聚合 App 接口，ext 是站点 base（必须在 spider 族判定之前）。
    if (api == 'csp_AppYs') {
      if (ext.isEmpty) return null;
      var base = _resolveMaybeRelative(ext, sourceUrl);
      while (base.endsWith('/')) {
        base = base.substring(0, base.length - 1);
      }
      // ext 形态可能是裸 base、已带 /api.php/app、或完整 /vod 路径。
      final apiFull = base.endsWith('/api.php/app/vod')
          ? base
          : base.endsWith('/api.php/app')
              ? '$base/vod'
              : '$base/api.php/app/vod';
      return SourceCandidate(
        name: name,
        api: apiFull,
        headers: _parseHeaders(site['header']),
        note: sourceUrl == null ? '' : '来自 ${_hostOf(sourceUrl)}',
      );
    }

    // .js 爬虫族：QuickJS 运行时执行（需 http(s) 完整地址）。
    if (api.endsWith('.js')) {
      final resolvedJs = _resolveMaybeRelative(api, sourceUrl);
      if (!resolvedJs.startsWith('http://') &&
          !resolvedJs.startsWith('https://')) {
        return SourceCandidate(
          name: name,
          api: resolvedJs,
          kind: SourceKind.spiderJs,
          spiderKey: key.isEmpty ? api : key,
          ext: ext,
          unsupportedReason: 'JS 地址无法解析为绝对地址',
        );
      }
      return SourceCandidate(
        name: name,
        api: resolvedJs,
        kind: SourceKind.spiderJs,
        spiderKey: key.isEmpty ? api : key,
        ext: ext,
        note: sourceUrl == null ? '' : '来自 ${_hostOf(sourceUrl)}',
      );
    }

    // jar / csp_ 族：需要 JVM 爬虫引擎（暂不支持）。
    if (type == 3 || api.startsWith('csp_') || api.contains('jar:')) {
      if (api.endsWith('.py') || key.endsWith('.py')) {
        return SourceCandidate(
            name: name,
            api: api,
            kind: SourceKind.spider,
            unsupportedReason: '不支持 Python 源');
      }
      return SourceCandidate(
        name: name,
        api: api,
        kind: SourceKind.spider,
        spiderKey: key.isEmpty ? api : key,
        ext: ext,
        unsupportedReason: '需要爬虫引擎',
        note: sourceUrl == null ? '' : '来自 ${_hostOf(sourceUrl)}',
      );
    }

    if (api.isEmpty) return null;
    api = _resolveMaybeRelative(api, sourceUrl);
    if (!api.startsWith('http://') && !api.startsWith('https://')) {
      return null;
    }

    return SourceCandidate(
      name: name,
      api: api,
      kind: type == 0 ? SourceKind.cmsXml : SourceKind.cmsJson,
      headers: _parseHeaders(site['header']),
      ext: ext,
      note: sourceUrl == null ? '' : '来自 ${_hostOf(sourceUrl)}',
    );
  }

  static Future<void> _importFromConfig(
    Map cfg,
    String? sourceUrl,
    ImportReport rep,
    int depth,
    Set<String> visited, {
    CancelToken? cancel,
  }) async {
    final sites = extractSites(cfg, sourceUrl: sourceUrl);
    for (final c in sites) {
      rep.add(c);
    }
    // lives 直播：改入库到 LivesStore（调用方读 rep.lives），不再标注不支持。
    rep.addLives(extractLives(cfg, sourceUrl: sourceUrl));

    // 多仓：递归拉取子配置（≤8 层 + 已访问防环）。
    final depots = <(String, String)>[];
    final urls = cfg['urls'];
    if (urls is List) {
      for (final item in urls) {
        if (item is Map && item['sourceUrl'] is String) {
          depots.add((
            (item['sourceName'] as String?) ?? '仓',
            item['sourceUrl'] as String
          ));
        } else if (item is String && item.startsWith('http')) {
          depots.add(('仓', item));
        }
      }
    }
    final storeHouse = cfg['storeHouse'];
    if (storeHouse is List) {
      for (final item in storeHouse) {
        if (item is Map && item['sourceUrl'] is String) {
          depots.add((
            (item['sourceName'] as String?) ?? '仓',
            item['sourceUrl'] as String
          ));
        }
      }
    }
    if (depots.isEmpty) return;
    if (depth >= maxDepotDepth) {
      rep.fail('多仓嵌套超过 $maxDepotDepth 层，已停止');
      return;
    }
    for (final (name, url) in depots) {
      final resolved = _resolveMaybeRelative(url, sourceUrl);
      if (!visited.add(resolved)) continue; // 循环引用
      rep.add(SourceCandidate(
        name: name,
        api: resolved,
        unsupportedReason: '这是多仓入口，已展开其子配置',
      ));
      await importFromUrl(resolved,
          report: rep, depth: depth + 1, visited: visited, cancel: cancel);
    }
  }

  // ---------- 工具 ----------

  /// SSRF 校验：仅 http/https，拒绝 loopback 与链路本地地址。
  static void validateImportUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      throw SourceException(SourceExceptionCode.importSsrf, '非法地址: $url');
    }
    if (!ssrfGuardEnabled) return;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' ||
        host.endsWith('.localhost') ||
        host.endsWith('.local')) {
      throw SourceException(SourceExceptionCode.importSsrf, 'loopback: $host');
    }
    if (InternetAddress.tryParse(host) case final addr?) {
      if (addr.isLoopback || addr.isLinkLocal) {
        throw SourceException(SourceExceptionCode.importSsrf, 'loopback/linklocal: $host');
      }
    }
  }

  static String _resolveMaybeRelative(String value, String? base) {
    if (value.startsWith('http://') || value.startsWith('https://')) {
      return value;
    }
    if (base == null) return value;
    try {
      return Uri.parse(base).resolve(value).toString();
    } catch (_) {
      return value;
    }
  }

  /// ext 三形态归一：字符串原样；Map/List 转 JSON 文本；null 归空。
  static String _normalizeExt(Object? ext) {
    if (ext == null) return '';
    if (ext is String) return ext;
    try {
      return jsonEncode(ext);
    } catch (_) {
      return '';
    }
  }

  /// header 三形态：Map / JSON 文本 / `k=v;k=v` 或 `k=v&k=v`。
  static Map<String, String> _parseHeaders(Object? header) {
    if (header == null) return const {};
    if (header is Map) {
      return header.map((k, v) => MapEntry(k.toString(), v.toString()));
    }
    final text = header.toString().trim();
    if (text.isEmpty) return const {};
    if (text.startsWith('{')) {
      try {
        final decoded = jsonDecode(text);
        if (decoded is Map) {
          return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      } catch (_) {}
    }
    final out = <String, String>{};
    for (final part in text.split(RegExp(r'[;&]'))) {
      final eq = part.indexOf('=');
      if (eq <= 0) continue;
      out[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
    }
    return out;
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  static String _clip(String s) =>
      s.length <= 80 ? s : '${s.substring(0, 77)}…';
}

class _Cancelled implements Exception {
  const _Cancelled();
}
