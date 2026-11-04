import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ops_switches.dart';
import '../store/stores.dart';
import 'update_manifest.dart';
import 'update_mirror_health.dart';
import 'update_mirrors.dart';

/// 应用内更新：清单（`update.json`）优先，GitHub Releases API 兜底。
///
/// 链路：
/// 1. 清单候选 = 用户配置地址（英文逗号分隔）或内置默认 → 逐个尝试，镜像
///    仅在健康且支持 API 代理时加入；`ETag` 命中 304 时复用上次 payload。
/// 2. 清单不可达 → 退回 GitHub Releases API（老路径，保证始终有兜底）。
/// 3. 下载 = 清单给的资产地址顺序 → 镜像兜底；`.part` + `Range` 断点续传，
///    416 重下、服务端忽略 Range 时从头写；校验不过删文件换下一个源。
/// 4. 安装 = Windows 静默安装 / Android 调起系统安装器 / 其它平台跳发布页。
class UpdateService extends ChangeNotifier {
  UpdateService._();

  static final UpdateService instance = UpdateService._();

  static const _releasesUrl =
      'https://github.com/wjsqqj/aquan-duanju/releases';
  static const _apiUrl =
      'https://api.github.com/repos/wjsqqj/aquan-duanju/releases/latest';

  /// 默认清单：Release 资产优先（可被镜像代理），其次仓库内的静态文件。
  static const List<String> _defaultManifestUrls = <String>[
    'https://github.com/wjsqqj/aquan-duanju/releases/latest/download/update.json',
    'https://raw.githubusercontent.com/wjsqqj/aquan-duanju/main/update.json',
  ];

  SettingsStore? _settings;

  bool _checking = false;
  String? _latestVersion;
  String? _releaseUrl;
  String? _error;
  String? _sourceLabel;
  String? _downloadSourceLabel;
  String? _changelog;

  /// 清单里当前平台的安装包候选；API 兜底时只有一条。
  List<String> _assetUrls = const <String>[];
  String? _expectedSha;
  String? _installerShaUrl;
  String _expectedShaLabel = '';

  /// 按清单地址缓存 ETag 与解析结果（内存态；重启重新取）。
  final Map<String, _ManifestCacheEntry> _manifestCache =
      <String, _ManifestCacheEntry>{};

  final UpdateMirrorHealthStore _health = UpdateMirrorHealthStore();

  bool get checking => _checking;
  bool get hasUpdate => _latestVersion != null;

  String? get latestVersion => _latestVersion;
  String? get error => _error;
  String? get changelog => _changelog;

  /// 本次检查实际使用的源（「官方清单」/「自定义」/「镜像 gh-proxy.com」/「GitHub API」）。
  String? get sourceLabel => _sourceLabel;

  /// 本次下载实际使用的源。
  String? get downloadSourceLabel => _downloadSourceLabel;

  /// 是否有可在应用内安装的包（Windows/Android 且清单给出资产）。
  bool get canInstallInApp =>
      hasUpdate &&
      _assetUrls.isNotEmpty &&
      (Platform.isWindows || Platform.isAndroid);

  /// 兼容旧入口：Windows 安装包直链是否存在。
  String? get windowsInstallerUrl =>
      Platform.isWindows && _assetUrls.isNotEmpty ? _assetUrls.first : null;

  /// 下载进度（0-1）；不在下载中时为 null。
  final ValueNotifier<double?> downloadProgress = ValueNotifier<double?>(null);

  /// 绑定设置（更新源地址）。在应用启动完成后调用。
  void attachSettings(SettingsStore settings) {
    _settings = settings;
  }

  /// 用户改了更新源地址：丢掉 ETag 缓存，下次检查重新取。
  void resetManifestCache() {
    _manifestCache.clear();
    _error = null;
    notifyListeners();
  }

  Future<void> checkQuietly() => _check(manual: false);

  Future<void> checkManually() => _check(manual: true);

  Future<void> _check({required bool manual}) async {
    // 运维急停只拦自动检查；用户手动点仍然放行（否则没法自救）。
    if (!manual && OpsSwitches.disableAutoUpdate) return;
    if (_checking) return;
    _checking = true;
    _error = null;
    _sourceLabel = null;
    notifyListeners();
    try {
      final info = await PackageInfo.fromPlatform();
      final snapshot = await _health.load();
      final platform = UpdateManifest.currentPlatformKey();

      final manifest = await _fetchFirstManifest(snapshot);
      if (manifest != null) {
        _applyManifest(manifest, info.version, platform);
        return;
      }

      // 清单完全不可达：退回 GitHub Releases API。
      await _checkViaApi(info.version, snapshot);
    } catch (e) {
      _error = e.toString();
      if (!manual) _error = null;
      _clearUpdate();
    } finally {
      _checking = false;
      notifyListeners();
    }
  }

  void _applyManifest(
    UpdateManifest manifest,
    String currentVersion,
    String platform,
  ) {
    if (!manifest.isNewerThan(currentVersion)) {
      _clearUpdate();
      return;
    }
    _latestVersion = manifest.version;
    _changelog = manifest.changelog;
    _releaseUrl =
        'https://github.com/wjsqqj/aquan-duanju/releases/tag/v${manifest.version}';
    _assetUrls = manifest.assetUrlsFor(platform);
    _expectedSha = manifest.shaFor(platform);
    _installerShaUrl = null;
    _expectedShaLabel = _expectedSha == null ? '清单未提供摘要' : '清单 SHA-256';
  }

  Future<UpdateManifest?> _fetchFirstManifest(
    MirrorHealthSnapshot snapshot,
  ) async {
    final sources = _manifestSources(snapshot);
    for (final source in sources) {
      try {
        final manifest = await _fetchManifest(source, snapshot);
        if (manifest == null) continue;
        _sourceLabel = source.label;
        if (source.mirrorId != null) {
          await _health.recordCheckSuccess(source.mirrorId!);
        }
        return manifest;
      } catch (_) {
        if (source.mirrorId != null) {
          await _health.recordCheckFailure(source.mirrorId!);
        }
      }
    }
    return null;
  }

  List<_UpdateSource> _manifestSources(MirrorHealthSnapshot snapshot) {
    final configured = _settings?.updateUrlList ?? const <String>[];
    final base = configured.isEmpty ? _defaultManifestUrls : configured;
    final out = <_UpdateSource>[];
    for (final url in base) {
      out.add(_UpdateSource(
        url: url,
        label: configured.isEmpty ? '官方清单' : '自定义',
      ));
      for (final mirror in builtInUpdateMirrors) {
        if (snapshot.isCoolingDown(mirror.id)) continue;
        final mirrored = mirror.resolveApi(url);
        if (mirrored == null) continue;
        out.add(_UpdateSource(
          url: mirrored,
          label: '镜像 ${mirror.label}',
          mirrorId: mirror.id,
        ));
      }
    }
    return out;
  }

  Future<UpdateManifest?> _fetchManifest(
    _UpdateSource source,
    MirrorHealthSnapshot snapshot,
  ) async {
    final cached = _manifestCache[source.url];
    final response = await _get(source.url, etag: cached?.etag);
    if (response.statusCode == HttpStatus.notModified && cached != null) {
      return cached.manifest;
    }
    if (response.statusCode != HttpStatus.ok) return null;
    final manifest = UpdateManifest.parse(response.body);
    if (manifest == null) return null;
    _manifestCache[source.url] = _ManifestCacheEntry(
      etag: response.etag,
      manifest: manifest,
    );
    return manifest;
  }

  /// GitHub Releases API 兜底（原路径）。
  Future<void> _checkViaApi(
    String currentVersion,
    MirrorHealthSnapshot snapshot,
  ) async {
    final candidates = <_UpdateSource>[
      const _UpdateSource(url: _apiUrl, label: 'GitHub API'),
      for (final mirror in builtInUpdateMirrors)
        if (mirror.proxiesApi && !snapshot.isCoolingDown(mirror.id))
          if (mirror.resolveApi(_apiUrl) case final mirrored?)
            _UpdateSource(
              url: mirrored,
              label: '镜像 ${mirror.label}（API）',
              mirrorId: mirror.id,
            ),
    ];

    Map<String, dynamic>? json;
    Object? lastError;
    for (final candidate in candidates) {
      try {
        final body = await _getString(candidate.url);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('响应不是 JSON 对象');
        }
        json = decoded;
        _sourceLabel = candidate.label;
        if (candidate.mirrorId != null) {
          await _health.recordCheckSuccess(candidate.mirrorId!);
        }
        break;
      } catch (e) {
        lastError = e;
        if (candidate.mirrorId != null) {
          await _health.recordCheckFailure(candidate.mirrorId!);
        }
      }
    }
    if (json == null) {
      throw Exception(lastError ?? '所有更新源均不可用');
    }

    final tag = json['tag_name'] as String? ?? '';
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (UpdateManifest.compareVersions(latest, currentVersion) <= 0) {
      _clearUpdate();
      return;
    }
    final asset = _findInstaller(json['assets']);
    _latestVersion = latest;
    _changelog = (json['body'] as String? ?? '').trim();
    _releaseUrl = json['html_url'] as String? ?? _releasesUrl;
    _assetUrls = asset?.urls ?? const <String>[];
    _expectedSha = null;
    _installerShaUrl = asset?.shaUrl;
    _expectedShaLabel = asset?.shaUrl == null ? '未校验' : 'Release SHA-256';
  }

  /// 从 Release assets 里找当前平台的安装包。
  static _ReleaseAsset? _findInstaller(dynamic assets) {
    if (assets is! List) return null;
    final patterns = Platform.isWindows
        ? <bool Function(String)>[
            (name) =>
                name.startsWith('aquan-windows-x64-') &&
                name.endsWith('-setup.exe'),
          ]
        : <bool Function(String)>[
            (name) => name == _androidAssetName(),
            (name) => name.startsWith('aquan-') && name.endsWith('.apk'),
          ];
    for (final pattern in patterns) {
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String?;
        if (!pattern(name) || url == null) continue;
        String? shaUrl;
        for (final other in assets) {
          if (other is! Map<String, dynamic>) continue;
          if (other['name'] == '$name.sha256') {
            shaUrl = other['browser_download_url'] as String?;
            break;
          }
        }
        return _ReleaseAsset(urls: <String>[url],shaUrl: shaUrl);
      }
    }
    return null;
  }

  static String _androidAssetName() {
    final abi = UpdateManifest.currentPlatformKey();
    return switch (abi) {
      'android-armeabi-v7a' => 'aquan-armeabi-v7a.apk',
      'android-x86_64' => 'aquan-x86_64.apk',
      _ => 'aquan-arm64-v8a.apk',
    };
  }

  void _clearUpdate() {
    _latestVersion = null;
    _releaseUrl = null;
    _assetUrls = const <String>[];
    _expectedSha = null;
    _installerShaUrl = null;
    _changelog = null;
  }

  /// 下载并安装（Windows 静默安装 / Android 调起系统安装器）。
  Future<void> downloadAndInstall() async {
    final version = _latestVersion;
    if (version == null) throw StateError('没有可用的更新包');
    if (!canInstallInApp) throw StateError('当前平台没有可安装的更新包');

    final dir = await getTemporaryDirectory();
    await _cleanupOldPackages(dir);
    final extension = Platform.isAndroid ? 'apk' : 'exe';
    final target = File(
        '${dir.path}${Platform.pathSeparator}aquan-update-$version.$extension');

    final snapshot = await _health.load();
    final sources = _downloadSources(snapshot);
    final expected = _expectedSha ?? await _fetchExpectedSha(_installerShaUrl);

    downloadProgress.value = 0;
    Object? lastError;
    var installed = false;
    for (final source in sources) {
      try {
        final ok = await _downloadTo(source.url, target);
        if (!ok) continue;
        if (expected != null) {
          final actual = await _sha256OfFile(target);
          if (actual.toLowerCase() != expected.toLowerCase()) {
            await _safeDelete(target);
            lastError = '校验失败（SHA-256 不匹配）';
            continue;
          }
        }
        _downloadSourceLabel = source.label;
        if (source.mirrorId != null) {
          await _health.recordDownloadSuccess(source.mirrorId!);
        }
        downloadProgress.value = null;
        await _install(target);
        installed = true;
        break;
      } catch (e) {
        lastError = e;
        if (source.mirrorId != null) {
          await _health.recordDownloadFailure(source.mirrorId!);
        }
        await _safeDelete(target);
        await _safeDelete(File('${target.path}.part'));
      }
    }

    if (!installed) {
      downloadProgress.value = null;
      throw Exception('更新包下载失败：${lastError ?? '所有地址均不可用'}');
    }
  }

  List<_UpdateSource> _downloadSources(MirrorHealthSnapshot snapshot) {
    final out = <_UpdateSource>[];
    for (final url in _assetUrls) {
      out.add(_UpdateSource(url: url, label: '官方'));
      for (final mirror in builtInUpdateMirrors) {
        if (snapshot.isCoolingDown(mirror.id)) continue;
        final mirrored = mirror.resolve(url);
        if (mirrored == null) continue;
        out.add(_UpdateSource(
          url: mirrored,
          label: '镜像 ${mirror.label}',
          mirrorId: mirror.id,
        ));
      }
    }
    return out;
  }

  Future<void> _install(File file) async {
    if (Platform.isWindows) {
      await Process.start(
        file.path,
        const ['/SILENT', '/FORCECLOSEAPPLICATIONS'],
        mode: ProcessStartMode.detached,
      );
      // 给安装器一点启动时间，然后退出让它接管（安装完需重新打开应用）。
      await Future<void>.delayed(const Duration(milliseconds: 800));
      exit(0);
    }
    if (Platform.isAndroid) {
      try {
        await const MethodChannel('aquan/update').invokeMethod<void>(
          'installApk',
          <String, dynamic>{'path': file.path},
        );
      } on PlatformException catch (e) {
        throw Exception('无法调起系统安装器：${e.message ?? e.code}');
      } on MissingPluginException {
        throw Exception('当前版本不支持应用内安装，请到发布页手动下载');
      }
      return;
    }
    await openReleasePage();
  }

  /// 打开发布页让用户手动下载。
  Future<void> openReleasePage() async {
    final url = Uri.parse(_releaseUrl ?? _releasesUrl);
    try {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    } catch (_) {
      // 没有浏览器等极端环境：忽略，用户可手动访问。
    }
  }

  // ---------------- HTTP ----------------

  Future<_HttpText> _get(String url, {String? etag}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 12);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      if (etag != null && etag.isNotEmpty) {
        request.headers.set(HttpHeaders.ifNoneMatchHeader, etag);
      }
      final response =
          await request.close().timeout(const Duration(seconds: 15));
      if (response.statusCode == HttpStatus.notModified) {
        await response.drain<void>();
        return _HttpText(response.statusCode, '', etag);
      }
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        return _HttpText(response.statusCode, '', null);
      }
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(const Duration(seconds: 20));
      final newEtag = response.headers.value(HttpHeaders.etagHeader);
      return _HttpText(response.statusCode, body, newEtag);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> _getString(String url) async {
    final response = await _get(url);
    if (response.statusCode != HttpStatus.ok) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return response.body;
  }

  /// 断点续传下载：`.part` + Range；416 从头重来一次。
  Future<bool> _downloadTo(String url, File target) async {
    final part = File('${target.path}.part');
    var start = 0;
    try {
      if (await part.exists()) start = await part.length();
    } catch (_) {
      start = 0;
    }

    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.userAgentHeader, 'aquan-duanju');
      if (start > 0) {
        request.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      }
      final response =
          await request.close().timeout(const Duration(seconds: 30));

      if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
        await response.drain<void>();
        await _safeDelete(part);
        // 服务端认为续传起点越界：从头再下最后一段。
        return await _downloadTo(url, target);
      }
      final append = response.statusCode == HttpStatus.partialContent && start > 0;
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        await response.drain<void>();
        return false;
      }
      if (!append) start = 0;

      final total = response.contentLength > 0
          ? response.contentLength + (append ? start : 0)
          : 0;
      final sink = part.openWrite(
        mode: append ? FileMode.append : FileMode.write,
      );
      var received = 0;
      try {
        await for (final chunk in response) {
          received += chunk.length;
          if (total > 0) {
            downloadProgress.value = (start + received) / total;
          }
          sink.add(chunk);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      await _safeDelete(target);
      await part.rename(target.path);
      return true;
    } catch (_) {
      // 保留 .part 供下次续传。
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 读取 `.sha256` 资产（官方优先，镜像兜底）；拿不到返回 null。
  Future<String?> _fetchExpectedSha(String? shaUrl) async {
    if (shaUrl == null || shaUrl.isEmpty) return null;
    final snapshot = await _health.load();
    final candidates = <String>[
      shaUrl,
      for (final mirror in builtInUpdateMirrors)
        if (!snapshot.isCoolingDown(mirror.id)) ?mirror.resolve(shaUrl),
    ];
    for (final url in candidates) {
      try {
        final body = await _getString(url);
        final match = RegExp(r'\b([0-9a-fA-F]{64})\b').firstMatch(body);
        if (match != null) return match.group(1);
      } catch (_) {
        // 换下一个源。
      }
    }
    return null;
  }

  Future<String> _sha256OfFile(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 清 7 天前的旧安装包（xiugou-tv 同策略：只删自己认识的文件）。
  Future<void> _cleanupOldPackages(Directory dir) async {
    try {
      final now = DateTime.now();
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last.toLowerCase();
        if (!name.startsWith('aquan-update-')) continue;
        try {
          final stat = await entity.stat();
          if (now.difference(stat.modified) < const Duration(days: 7)) {
            continue;
          }
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  static Future<void> _safeDelete(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 语义化版本比较：latest 的主/次/补丁任一大于 current 即认为有更新。
  static bool isVersionNewer(String latest, String current) =>
      UpdateManifest.compareVersions(latest, current) > 0;

  /// 摘要来源说明（UI 展示「是否校验」）。
  String get integrityLabel => _expectedShaLabel;
}

class _UpdateSource {
  const _UpdateSource({
    required this.url,
    required this.label,
    this.mirrorId,
  });

  final String url;
  final String label;
  final String? mirrorId;
}

class _ManifestCacheEntry {
  const _ManifestCacheEntry({required this.etag, required this.manifest});

  final String? etag;
  final UpdateManifest manifest;
}

class _HttpText {
  const _HttpText(this.statusCode, this.body, this.etag);

  final int statusCode;
  final String body;
  final String? etag;
}

class _ReleaseAsset {
  const _ReleaseAsset({required this.urls, this.shaUrl});

  final List<String> urls;
  final String? shaUrl;
}
