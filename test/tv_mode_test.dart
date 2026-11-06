import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/tv/tv_mode.dart';

void main() {
  group('resolveFormFactor', () {
    test('桌面永远 desktop', () {
      expect(
        resolveFormFactor(
            isAndroid: false, isDesktop: true, probe: TvProbe.unknown),
        AppFormFactor.desktop,
      );
    });

    test('Android 电视特征且无触屏判为 tv', () {
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(leanback: true, touchscreen: false),
        ),
        AppFormFactor.tv,
      );
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(television: true, touchscreen: false),
        ),
        AppFormFactor.tv,
      );
    });

    test('带触屏的电视盒子仍判 TV（R8 放宽判定）', () {
      for (final probe in const <TvProbe>[
        TvProbe(leanback: true, touchscreen: true),
        TvProbe(television: true, touchscreen: true),
      ]) {
        expect(
          resolveFormFactor(
            isAndroid: true,
            isDesktop: false,
            probe: probe,
          ),
          AppFormFactor.tv,
          reason: 'leanback / television 单独即可判 TV，不再被触屏一票否决',
        );
      }
    });

    test('无触屏 + 大屏判 TV，桌面大屏不误判', () {
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(touchscreen: false, largeScreen: true),
        ),
        AppFormFactor.tv,
      );
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: true,
          probe: const TvProbe(touchscreen: false, largeScreen: true),
        ),
        AppFormFactor.desktop,
      );
    });

    test('探测失败回落手机', () {
      expect(
        resolveFormFactor(
            isAndroid: true, isDesktop: false, probe: TvProbe.unknown),
        AppFormFactor.phone,
      );
    });

    test('手动强制开启覆盖一切', () {
      expect(
        resolveFormFactor(
          isAndroid: false,
          isDesktop: true,
          probe: TvProbe.unknown,
          override: TvOverride.on,
        ),
        AppFormFactor.tv,
      );
    });

    test('手动关闭按平台回落', () {
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(leanback: true, touchscreen: false),
          override: TvOverride.off,
        ),
        AppFormFactor.phone,
      );
      expect(
        resolveFormFactor(
          isAndroid: false,
          isDesktop: true,
          probe: TvProbe.unknown,
          override: TvOverride.off,
        ),
        AppFormFactor.desktop,
      );
    });

    test('Android 手机（有触屏、无电视特性）保持 phone', () {
      expect(
        resolveFormFactor(
          isAndroid: true,
          isDesktop: false,
          probe: const TvProbe(touchscreen: true),
        ),
        AppFormFactor.phone,
      );
    });
  });

  group('电视模式持久化字符串', () {
    test('非法值回落自动', () {
      expect(parseTvOverride(null), TvOverride.auto);
      expect(parseTvOverride(''), TvOverride.auto);
      expect(parseTvOverride('乱写'), TvOverride.auto);
      expect(parseTvOverride('on'), TvOverride.on);
      expect(parseTvOverride('off'), TvOverride.off);
    });

    test('往返一致', () {
      for (final value in TvOverride.values) {
        expect(parseTvOverride(tvOverrideName(value)), value);
      }
    });
  });
}
