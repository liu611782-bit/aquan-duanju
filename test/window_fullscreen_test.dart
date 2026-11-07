import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/window_fullscreen.dart';

void main() {
  group('进入全屏步骤', () {
    test('先记录 bounds 并解除限制/标题栏，铺满显示器后再开原生全屏', () {
      int pos(FullscreenStep s) => kFullscreenEnterSteps.indexOf(s);
      expect(pos(FullscreenStep.saveBounds), greaterThanOrEqualTo(0));
      expect(pos(FullscreenStep.clearMinimumSize),
          lessThan(pos(FullscreenStep.coverDisplay)),
          reason: 'minSize 不顶住铺满显示器的 setBounds');
      expect(pos(FullscreenStep.hideTitleBar),
          lessThan(pos(FullscreenStep.coverDisplay)),
          reason: '先隐标题栏再铺满，避免闪烁');
      expect(pos(FullscreenStep.coverDisplay),
          lessThan(pos(FullscreenStep.nativeFullscreenOn)),
          reason: 'Windows setFullScreen 盖不住任务栏，先铺满再开标记');
    });

    test('进入序列不含任何退出专属步骤', () {
      expect(kFullscreenEnterSteps, isNot(contains(FullscreenStep.showTitleBar)));
      expect(kFullscreenEnterSteps,
          isNot(contains(FullscreenStep.nativeFullscreenOff)));
      expect(kFullscreenEnterSteps,
          isNot(contains(FullscreenStep.restoreMinimumSize)));
      expect(kFullscreenEnterSteps, isNot(contains(FullscreenStep.restoreBounds)));
    });
  });

  group('退出全屏步骤', () {
    test('任何退出序列都恢复标题栏（Esc 直接 setFullScreen 的回归锁）', () {
      for (final restorable in [true, false]) {
        expect(fullscreenExitSteps(restorableBounds: restorable),
            contains(FullscreenStep.showTitleBar),
            reason: 'restorableBounds=$restorable');
      }
    });

    test('先退原生全屏，再恢复标题栏，再恢复最小尺寸', () {
      final steps = fullscreenExitSteps(restorableBounds: true);
      final off = steps.indexOf(FullscreenStep.nativeFullscreenOff);
      final title = steps.indexOf(FullscreenStep.showTitleBar);
      final minSize = steps.indexOf(FullscreenStep.restoreMinimumSize);
      expect(off, lessThan(title));
      expect(title, lessThan(minSize));
    });

    test('bounds 还原在标题栏恢复之后，且只在有还原点时执行', () {
      final withBounds = fullscreenExitSteps(restorableBounds: true);
      expect(withBounds.indexOf(FullscreenStep.showTitleBar),
          lessThan(withBounds.indexOf(FullscreenStep.restoreBounds)));
      expect(withBounds, contains(FullscreenStep.restoreBounds));

      final withoutBounds = fullscreenExitSteps(restorableBounds: false);
      expect(withoutBounds, isNot(contains(FullscreenStep.restoreBounds)));
    });

    test('退出序列不含进入专属步骤', () {
      for (final restorable in [true, false]) {
        final steps = fullscreenExitSteps(restorableBounds: restorable);
        expect(steps, isNot(contains(FullscreenStep.saveBounds)));
        expect(steps, isNot(contains(FullscreenStep.hideTitleBar)));
        expect(steps, isNot(contains(FullscreenStep.coverDisplay)));
        expect(steps, isNot(contains(FullscreenStep.nativeFullscreenOn)));
      }
    });
  });
}
