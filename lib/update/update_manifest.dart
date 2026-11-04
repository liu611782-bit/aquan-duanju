import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

/// `update.json` 清单（TVBox 同构 + 多平台扩展）。
///
/// 最小形态：
/// ```json
/// {"version":"1.5.0","changelog":"…",
///  "assets":{"windows":["https://…/setup.exe"]},
///  "sha256":{"windows":"<64 hex>"}}
/// ```
/// 兼容 TVBox 的 `apk: [url…]`（视作 Android arm64 资产）。
class UpdateManifest {
  const UpdateManifest({
    required this.version,
    this.versionCode = 0,
    this.changelog = '',
    this.assets = const <String, List<String>>{},
    this.sha256 = const <String, String>{},
  });

  final String version;
  final int versionCode;
  final String changelog;

  /// 平台键 → 候选下载地址（按顺序尝试）。
  final Map<String, List<String>> assets;

  /// 平台键 → SHA-256（十六进制，大小写不敏感）；`default` 为通用摘要。
  final Map<String, String> sha256;

  static UpdateManifest? parse(String raw) {
    Object? decoded;
    try {
      decoded = jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
    if (decoded is! Map) return null;
    final version = (decoded['version'] ??
            decoded['versionName'] ??
            decoded['version_name'] ??
            '')
        .toString()
        .trim();
    final assets = <String, List<String>>{};

    void addAsset(String key, Object? value) {
      final urls = <String>[];
      void addOne(Object? item) {
        if (item is! String) return;
        final url = item.trim();
        if (url.startsWith('http://') || url.startsWith('https://')) {
          urls.add(url);
        }
      }

      if (value is String) {
        addOne(value);
      } else if (value is List) {
        for (final item in value) {
          addOne(item);
        }
      }
      if (urls.isNotEmpty) assets[key] = urls;
    }

    final rawAssets = decoded['assets'] ?? decoded['files'];
    if (rawAssets is Map) {
      rawAssets.forEach((key, value) => addAsset('$key', value));
    }
    // TVBox 旧格式：顶层 apk 数组。
    addAsset('android-arm64-v8a', decoded['apk']);

    final sha = <String, String>{};
    final rawSha = decoded['sha256'];
    if (rawSha is String && rawSha.trim().isNotEmpty) {
      sha['default'] = rawSha.trim();
    } else if (rawSha is Map) {
      rawSha.forEach((key, value) {
        if (value is String && value.trim().isNotEmpty) {
          sha['$key'] = value.trim();
        }
      });
    }

    if (version.isEmpty || assets.isEmpty) return null;
    return UpdateManifest(
      version: version,
      versionCode: (decoded['versionCode'] as num?)?.toInt() ??
          (decoded['version_code'] as num?)?.toInt() ??
          0,
      changelog: (decoded['changelog'] ?? decoded['notes'] ?? '').toString(),
      assets: assets,
      sha256: sha,
    );
  }

  /// 当前平台键：与 `update.json` 的 `assets` 键一一对应。
  static String currentPlatformKey() {
    if (Platform.isWindows) return 'windows';
    if (Platform.isAndroid) {
      final abi = Abi.current();
      if (abi == Abi.androidArm64) return 'android-arm64-v8a';
      if (abi == Abi.androidArm) return 'android-armeabi-v7a';
      if (abi == Abi.androidX64) return 'android-x86_64';
      return 'android-arm64-v8a';
    }
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// 当前平台可安装包的候选地址；没有精确键时退到同平台任意键。
  List<String> assetUrlsFor(String platform) {
    final exact = assets[platform];
    if (exact != null && exact.isNotEmpty) return exact;
    if (platform.startsWith('android-')) {
      for (final entry in assets.entries) {
        if (entry.key.startsWith('android-') && entry.value.isNotEmpty) {
          return entry.value;
        }
      }
    }
    return const <String>[];
  }

  String? shaFor(String platform) =>
      sha256[platform] ?? sha256['default'];

  bool isNewerThan(String currentVersion) =>
      compareVersions(version, currentVersion) > 0;

  /// 语义化版本比较：返回 >0 表示 a 比 b 新。
  static int compareVersions(String a, String b) {
    final left = _triple(a);
    final right = _triple(b);
    for (var i = 0; i < 3; i++) {
      if (left[i] != right[i]) return left[i] - right[i];
    }
    return 0;
  }

  static List<int> _triple(String version) {
    final core = version.split('+').first.split('-').first;
    final parts = core.split('.');
    return [
      for (var i = 0; i < 3; i++)
        i < parts.length ? (int.tryParse(parts[i].trim()) ?? 0) : 0,
    ];
  }
}
