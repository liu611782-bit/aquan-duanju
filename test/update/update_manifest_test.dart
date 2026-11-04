import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/update/update_manifest.dart';

void main() {
  group('UpdateManifest.parse', () {
    test('多平台 assets + sha256 映射', () {
      final manifest = UpdateManifest.parse('''
{
  "version": "1.5.0",
  "versionCode": 20,
  "changelog": "更新内容",
  "assets": {
    "windows": ["https://gh/a/setup.exe", "https://mirror/setup.exe"],
    "android-arm64-v8a": ["https://gh/a/app.apk"]
  },
  "sha256": {
    "windows": "ABCDEF",
    "android-arm64-v8a": "123456"
  }
}
''');
      expect(manifest, isNotNull);
      expect(manifest!.version, '1.5.0');
      expect(manifest.versionCode, 20);
      expect(manifest.assetUrlsFor('windows').length, 2);
      expect(manifest.assetUrlsFor('android-arm64-v8a').single,
          'https://gh/a/app.apk');
      expect(manifest.shaFor('windows'), 'ABCDEF');
      expect(manifest.shaFor('android-armeabi-v7a'), isNull);
    });

    test('兼容 TVBox 顶层 apk 数组与字符串 sha256', () {
      final manifest = UpdateManifest.parse('''
{"versionName":"1.2.3","apk":["https://x/app.apk"],"sha256":"DEADBEEF"}
''');
      expect(manifest, isNotNull);
      expect(manifest!.assetUrlsFor('android-arm64-v8a').single,
          'https://x/app.apk');
      expect(manifest.shaFor('android-x86_64'), 'DEADBEEF');
    });

    test('files 作为 assets 别名', () {
      final manifest = UpdateManifest.parse(
          '{"version":"2.0.0","files":{"windows":"https://x/setup.exe"}}');
      expect(manifest?.assetUrlsFor('windows').single, 'https://x/setup.exe');
    });

    test('缺版本或缺资产返回 null', () {
      expect(UpdateManifest.parse('{"assets":{"windows":["https://x/a"]}}'),
          isNull);
      expect(UpdateManifest.parse('{"version":"1.0.0"}'), isNull);
      expect(UpdateManifest.parse('not json'), isNull);
      // 非 http(s) 资产不算数。
      expect(UpdateManifest.parse('{"version":"1.0.0","apk":["ftp://x/a.apk"]}'),
          isNull);
    });

    test('Android 平台缺精确键时回退同平台资产', () {
      final manifest = UpdateManifest.parse(
          '{"version":"1.0.0","assets":{"android-arm64-v8a":["https://x/a.apk"]}}');
      expect(manifest!.assetUrlsFor('android-x86_64').single,
          'https://x/a.apk');
    });
  });

  group('版本比较', () {
    test('主/次/补丁逐段比较', () {
      expect(UpdateManifest.compareVersions('1.5.0', '1.4.9'), greaterThan(0));
      expect(UpdateManifest.compareVersions('1.4.0+19', '1.4.0'), 0);
      expect(UpdateManifest.compareVersions('1.4.0', '1.4.1'), lessThan(0));
      expect(UpdateManifest.compareVersions('1.10.0', '1.9.0'), greaterThan(0));
    });

    test('isNewerThan', () {
      final manifest =
          UpdateManifest.parse('{"version":"1.5.0","apk":["https://x/a"]}')!;
      expect(manifest.isNewerThan('1.4.0'), isTrue);
      expect(manifest.isNewerThan('1.5.0'), isFalse);
    });
  });
}
