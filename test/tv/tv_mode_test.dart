import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';

void main() {
  group('R8：放宽 TV 形态判定', () {
    test('带触屏的 leanback / television 盒子判为 TV', () {
      expect(const TvProbe(leanback: true, touchscreen: true).looksLikeTv, isTrue);
      expect(
          const TvProbe(television: true, touchscreen: true).looksLikeTv, isTrue);
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(leanback: true, touchscreen: true),
        ),
        AppFormFactor.tv,
        reason: '国产盒子 / 车机带触屏也应进遥控器布局',
      );
    });

    test('无触屏 + 大屏判为 TV；无触屏但非大屏不误判', () {
      expect(
        const TvProbe(touchscreen: false, largeScreen: true).looksLikeTv,
        isTrue,
      );
      expect(
        const TvProbe(touchscreen: false, largeScreen: false).looksLikeTv,
        isFalse,
      );
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(touchscreen: false, largeScreen: true),
        ),
        AppFormFactor.tv,
      );
    });

    test('桌面不误判：桌面优先返回 desktop，isDesktop 的 probe 也不判 TV', () {
      expect(
        resolveFormFactor(
          isAndroid: true, // 即便误带 Android 标记
          isDesktop: true,
          probe: const TvProbe(touchscreen: false, largeScreen: true),
        ),
        AppFormFactor.desktop,
      );
      expect(
        const TvProbe(
          isDesktop: true,
          touchscreen: false,
          largeScreen: true,
          leanback: true,
        ).looksLikeTv,
        isFalse,
      );
      expect(
        resolveFormFactor(
            isAndroid: false, isDesktop: true, probe: TvProbe.unknown),
        AppFormFactor.desktop,
      );
    });

    test('手动覆盖仍优先于自动探测', () {
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: TvProbe.unknown,
          override: TvOverride.on,
        ),
        AppFormFactor.tv,
      );
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(leanback: true, touchscreen: true),
          override: TvOverride.off,
        ),
        AppFormFactor.phone,
      );
    });

    test('公开签名向后兼容：旧构造与 unknown 安全值', () {
      expect(TvProbe.unknown.looksLikeTv, isFalse);
      expect(const TvProbe(touchscreen: true).looksLikeTv, isFalse);
      expect(const TvProbe(leanback: true, touchscreen: false).looksLikeTv,
          isTrue);
      expect(parseTvOverride('on'), TvOverride.on);
      expect(tvOverrideName(TvOverride.auto), 'auto');
    });
  });
}
