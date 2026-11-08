import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/store/stores.dart';

void main() {
  group('castRelayStart 通道载荷（R2 画质透传 / AC-2）', () {
    test('quality 显式档位透传到 payload', () {
      final payload = castRelayStartPayload(
        url: 'http://up/1.m3u8',
        decKey: 'ABCDEF',
        quality: 'compact',
      );
      expect(payload['quality'], 'compact');
      // 与 Go relayOptions JSON 标签对齐（拍平的 options）。
      expect(payload.containsKey('url'), isTrue);
      expect(payload.containsKey('backup_url'), isTrue);
      expect(payload.containsKey('dec_key'), isTrue);
      expect(payload.containsKey('audio_url'), isTrue);
      expect(payload.containsKey('user_agent'), isTrue);
      expect(payload.containsKey('referer'), isTrue);
      expect(payload.containsKey('format'), isTrue);
      expect(payload.containsKey('subtitle_url'), isTrue);
    });

    test('quality 缺省空串（Go 侧缺省回 balanced，旧调用方零改动）', () {
      final payload = castRelayStartPayload(url: 'http://up/1.m3u8');
      expect(payload['quality'], '');
    });

    test('payload 经 jsonEncode 往返不失真（castRelayStart 的实际编码路径）', () {
      final payload = castRelayStartPayload(
        url: 'http://up/1.m3u8',
        userAgent: 'aquan/1.0',
        format: 'ts',
        quality: 'high',
      );
      final back =
          Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map);
      expect(back['quality'], 'high');
      expect(back['format'], 'ts');
      expect(back['url'], 'http://up/1.m3u8');
    });

    test('work_dir/ca_file 默认空串（Go 侧空值回落现状，旧测试零回归）', () {
      final payload = castRelayStartPayload(url: 'http://up/1.m3u8');
      expect(payload['work_dir'], '');
      expect(payload['ca_file'], '');
    });

    test('work_dir/ca_file 显式透传（11-08 真机修复，与 Go JSON 标签对齐）', () {
      final payload = castRelayStartPayload(
        url: 'http://up/1.m3u8',
        workDir: '/data/user/0/x/cache',
        caFile: '/data/user/0/x/cache/aquan-cast-ca.pem',
      );
      expect(payload['work_dir'], '/data/user/0/x/cache');
      expect(payload['ca_file'], '/data/user/0/x/cache/aquan-cast-ca.pem');
      final back =
          Map<String, dynamic>.from(jsonDecode(jsonEncode(payload)) as Map);
      expect(back['work_dir'], '/data/user/0/x/cache');
      expect(back['ca_file'], '/data/user/0/x/cache/aquan-cast-ca.pem');
    });
  });

  group('SettingsStore 画质档位持久化（R2 / AC-2）', () {
    test('默认均衡', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      expect(s.castRelayQuality, 'balanced');
    });

    test('写入并重读（往返）', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final s = SettingsStore(prefs);
      s.castRelayQuality = 'high';
      expect(s.castRelayQuality, 'high');
      // 模拟重启：新实例从同一 prefs 读回。
      final s2 = SettingsStore(prefs);
      expect(s2.castRelayQuality, 'high');
      s.castRelayQuality = 'compact';
      expect(SettingsStore(await SharedPreferences.getInstance())
          .castRelayQuality, 'compact');
    });

    test('非法值回落均衡（写入侧与读侧同口径）', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.castRelayQuality = 'ultra';
      expect(s.castRelayQuality, 'balanced');
      // 存量脏数据读侧兜底。
      SharedPreferences.setMockInitialValues({'cast.relayQuality': '???'});
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      expect(s2.castRelayQuality, 'balanced');
    });

    test('备份白名单：导出包含 cast.relayQuality，导入恢复', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.castRelayQuality = 'compact';
      final backup = s.exportBackup();
      expect(backup['cast.relayQuality'], 'compact');

      // 恢复到另一台设备（全新实例）。
      SharedPreferences.setMockInitialValues({});
      final s2 = SettingsStore(await SharedPreferences.getInstance());
      final applied = s2.importBackup(backup);
      expect(applied, greaterThan(0));
      expect(s2.castRelayQuality, 'compact');
    });

    test('备份导入：非法档位忽略，保持当前值', () async {
      SharedPreferences.setMockInitialValues({});
      final s = SettingsStore(await SharedPreferences.getInstance());
      s.castRelayQuality = 'high';
      s.importBackup({'cast.relayQuality': 'super'});
      expect(s.castRelayQuality, 'high');
    });
  });
}
