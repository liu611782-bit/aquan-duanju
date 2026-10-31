import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/reader/reader_settings.dart';

void main() {
  group('ReaderSettings 按书覆盖（global→book 两层）', () {
    test('无覆盖时全部回退全局', () {
      const settings = ReaderSettings();
      expect(settings.themeIndexFor('book1'), settings.activeTheme);
      expect(settings.modeFor('book1'), settings.mode);
      expect(settings.fontScaleFor('book1'), 1.0);
      expect(settings.hasBookOverride('book1'), isFalse);
    });

    test('withBookOverride 写入并生效；null 清除回跟随', () {
      var settings = const ReaderSettings();
      settings = settings.withBookOverride(
          'book1', ReaderSettings.bookFieldMode, ReaderMode.paged.name);
      expect(settings.modeFor('book1'), ReaderMode.paged);
      expect(settings.modeFor('book2'), settings.mode, reason: '其他书不受影响');
      expect(settings.hasBookOverride('book1'), isTrue);

      // 字号缩放
      settings = settings.withBookOverride(
          'book1', ReaderSettings.bookFieldFontScale, 1.25);
      expect(settings.fontScaleFor('book1'), 1.25);
      // 主题索引
      settings = settings.withBookOverride('book1', ReaderSettings.bookFieldTheme, 2);
      expect(settings.themeIndexFor('book1'), 2);

      // 清除：null → 回全局；最后一项清掉后条目整个移除
      settings = settings.withBookOverride('book1', ReaderSettings.bookFieldMode, null);
      expect(settings.modeFor('book1'), settings.mode);
      expect(settings.hasBookOverride('book1'), isTrue, reason: '还有两项覆盖');
      settings = settings.withBookOverride('book1', ReaderSettings.bookFieldTheme, null);
      settings = settings.withBookOverride(
          'book1', ReaderSettings.bookFieldFontScale, null);
      expect(settings.hasBookOverride('book1'), isFalse);
      expect(settings.bookOverrides, isEmpty, reason: '空条目应整个移除');
    });

    test('字号缩放钳制到 0.8–1.5', () {
      var settings = const ReaderSettings();
      settings = settings.withBookOverride(
          'b', ReaderSettings.bookFieldFontScale, 9.9);
      expect(settings.fontScaleFor('b'), ReaderSettings.maxFontScale);
      settings = settings.withBookOverride(
          'b', ReaderSettings.bookFieldFontScale, -3);
      expect(settings.fontScaleFor('b'), ReaderSettings.minFontScale);
    });

    test('主题索引越界钳制到有效范围', () {
      final settings = const ReaderSettings()
          .withBookOverride('b', ReaderSettings.bookFieldTheme, 999);
      final count = settings.effectiveThemes.length;
      expect(settings.themeIndexFor('b'), count - 1);
    });

    test('JSON 往返：覆盖值无损（false/0/合法值），未知字段与错型丢弃', () {
      var settings = const ReaderSettings()
          .withBookOverride('b1', ReaderSettings.bookFieldTheme, 0)
          .withBookOverride('b1', ReaderSettings.bookFieldMode, ReaderMode.paged.name)
          .withBookOverride('b1', ReaderSettings.bookFieldFontScale, 1.1);
      final restored = ReaderSettings.fromJson(settings.toJson());
      expect(restored.themeIndexFor('b1'), 0, reason: '索引 0 是合法覆盖值');
      expect(restored.modeFor('b1'), ReaderMode.paged);
      expect(restored.fontScaleFor('b1'), 1.1);

      final broken = ReaderSettings.fromJson(<String, dynamic>{
        'book_overrides': <String, dynamic>{
          'b2': <String, dynamic>{
            'theme': 'not-an-int', // 错型丢弃
            'mode': 'unknown-mode', // 非法枚举丢弃
            'font_scale': 'oops', // 错型丢弃
            'hacked_field': 1, // 未知字段丢弃
          },
        },
      });
      expect(broken.hasBookOverride('b2'), isFalse);

      // book_overrides 不是 Map：整体忽略不抛。
      final notMap =
          ReaderSettings.fromJson(<String, dynamic>{'book_overrides': 'oops'});
      expect(notMap.bookOverrides, isEmpty);
      expect(broken.hasBookOverride('123'), isFalse);
    });

    test('无覆盖时不写 book_overrides 键（旧 JSON 兼容读回）', () {
      const settings = ReaderSettings();
      expect(settings.toJson().containsKey('book_overrides'), isFalse);
      // 旧版 JSON（无该键）读回默认空覆盖。
      final legacy = ReaderSettings.fromJson(<String, dynamic>{'mode': 'paged'});
      expect(legacy.bookOverrides, isEmpty);
      expect(legacy.mode, ReaderMode.paged);
    });
  });
}
