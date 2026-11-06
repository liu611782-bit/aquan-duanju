import 'package:aquan_duanju/store/stores.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('播放器高级设置默认值与范围校验', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsStore(await SharedPreferences.getInstance());
    expect(s.hwdecMode, 'auto-copy');
    expect(s.cacheSecs, 30);
    expect(s.audioDelayMs, 0);
    expect(s.scale, 'fit');
    expect(s.skipIntroOutro, isTrue);
    expect(s.historyLimit, 150);
    expect(s.downloadDir, isNull);
    expect(s.downloadSpeedKbps, 0);
    expect(s.subtitleFontSize, 48);
    expect(s.subtitleBorder, isTrue);
    expect(s.subtitleBackground, isFalse);

    s.hwdecMode = 'not-a-mode';
    expect(s.hwdecMode, 'auto-copy');
    s.hwdecMode = 'dxva2';
    expect(s.hwdecMode, 'dxva2');

    s.cacheSecs = 9999;
    expect(s.cacheSecs, SettingsStore.maxCacheSecs);
    s.cacheSecs = -5;
    expect(s.cacheSecs, SettingsStore.minCacheSecs);

    s.audioDelayMs = 99999;
    expect(s.audioDelayMs, SettingsStore.maxAudioDelayMs);
    s.audioDelayMs = -99999;
    expect(s.audioDelayMs, SettingsStore.minAudioDelayMs);

    s.scale = 'weird';
    expect(s.scale, 'fit');
    s.scale = '16:9';
    expect(s.scale, '16:9');

    s.historyLimit = 3;
    expect(s.historyLimit, 150);
    s.historyLimit = 300;
    expect(s.historyLimit, 300);

    s.downloadDir = '  D:/cache  ';
    expect(s.downloadDir, 'D:/cache');
    s.downloadDir = '   ';
    expect(s.downloadDir, isNull);

    s.downloadSpeedKbps = 999999;
    expect(s.downloadSpeedKbps, 102400);
    s.downloadSpeedKbps = -1;
    expect(s.downloadSpeedKbps, 0);
    s.downloadSpeedKbps = 1024;
    expect(s.downloadSpeedKbps, 1024);

    s.subtitleFontSize = 9999;
    expect(s.subtitleFontSize, 96);
    s.subtitleFontSize = 56;
    s.subtitleBorder = false;
    s.subtitleBackground = true;
    expect(s.subtitleFontSize, 56);
    expect(s.subtitleBorder, isFalse);
    expect(s.subtitleBackground, isTrue);
  });

  test('旧版 auto-safe 硬解回落到拷回模式（避免画面右/下绿边）', () async {
    SharedPreferences.setMockInitialValues({'player.hwdec': 'auto-safe'});
    final s = SettingsStore(await SharedPreferences.getInstance());
    expect(s.hwdecMode, 'auto-copy');
    // 再次写入已废弃档位也走同一兜底。
    s.hwdecMode = 'auto-safe';
    expect(s.hwdecMode, 'auto-copy');
  });

  test('备份导出/恢复设置：未知键忽略、非法值回落', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsStore(await SharedPreferences.getInstance());
    s
      ..themeMode = 'dark'
      ..historyLimit = 300
      ..hwdecMode = 'no'
      ..cacheSecs = 60
      ..audioDelayMs = 200
      ..scale = '4:3'
      ..skipIntroOutro = false
      ..subtitleFontSize = 56
      ..subtitleBackground = true;

    final data = s.exportBackup();
    expect(data['history.limit'], 300);
    expect(data['player.hwdec'], 'no');
    expect(data.containsKey('win.bounds'), isFalse);

    SharedPreferences.setMockInitialValues({});
    final target = SettingsStore(await SharedPreferences.getInstance());
    final applied = target.importBackup({
      ...data,
      'unknown.key': 'x',
      'player.scale': 'bad',
      'history.limit': 2,
    });
    expect(applied, greaterThan(0));
    expect(target.themeMode, 'dark');
    expect(target.hwdecMode, 'no');
    expect(target.cacheSecs, 60);
    expect(target.audioDelayMs, 200);
    expect(target.scale, 'fit'); // 非法值不写入，保留默认
    expect(target.historyLimit, 150); // 非法值归一化默认
    expect(target.skipIntroOutro, isFalse);
    expect(target.subtitleFontSize, 56);
    expect(target.subtitleBackground, isTrue);
  });

  test('影视聚合效果开关：默认值 / 范围 / 备份往返', () async {
    SharedPreferences.setMockInitialValues({});
    final s = SettingsStore(await SharedPreferences.getInstance());
    expect(s.autoDiscovery, isTrue);
    expect(s.autoSourceIntervalMinutes, 60);
    expect(s.autoMergeSources, isTrue);
    expect(s.randomHomeSource, isTrue);
    expect(s.dedupeBackendSearch, isTrue);
    expect(s.detailSourceSwitch, isTrue);
    expect(s.autoCheckUpdate, isTrue);

    s.autoSourceIntervalMinutes = 5;
    expect(s.autoSourceIntervalMinutes, 15);
    s.autoSourceIntervalMinutes = 9999;
    expect(s.autoSourceIntervalMinutes, 360);

    s
      ..autoDiscovery = false
      ..autoMergeSources = false
      ..randomHomeSource = false
      ..dedupeBackendSearch = false
      ..detailSourceSwitch = false
      ..autoCheckUpdate = false
      ..updateUrls = 'https://example.com/update.json';

    final data = s.exportBackup();
    expect(data['sources.autoDiscovery'], isFalse);
    expect(data['sources.randomHome'], isFalse);
    expect(data['update.urls'], 'https://example.com/update.json');

    SharedPreferences.setMockInitialValues({});
    final target = SettingsStore(await SharedPreferences.getInstance());
    target.importBackup(data);
    expect(target.autoDiscovery, isFalse);
    expect(target.autoMergeSources, isFalse);
    expect(target.randomHomeSource, isFalse);
    expect(target.dedupeBackendSearch, isFalse);
    expect(target.detailSourceSwitch, isFalse);
    expect(target.autoCheckUpdate, isFalse);
    expect(target.updateUrls, 'https://example.com/update.json');
  });
}
