/// 运行形态：手机 / 桌面 / 电视。
///
/// 同一个 APK 覆盖三种形态；电视只换交互（遥控器焦点 + 大屏布局），不换业务。
enum AppFormFactor { phone, desktop, tv }

/// 设置项「电视模式」：自动 / 强制开启 / 关闭。
enum TvOverride { auto, on, off }

/// Android 系统特性探测结果。
class TvProbe {
  const TvProbe({
    this.leanback = false,
    this.television = false,
    this.touchscreen = true,
    this.largeScreen = false,
    this.isDesktop = false,
  });

  final bool leanback;
  final bool television;
  final bool touchscreen;

  /// 物理大屏（由调用方按屏幕/窗口尺寸注入）。缺省 false：没有尺寸信息时
  /// 不把「无触屏」的小屏设备误判成电视。
  final bool largeScreen;

  /// 桌面形态标记：桌面永不判 TV。
  final bool isDesktop;

  /// 放宽后的电视判定（R8）：
  /// - 有 leanback / television 系统特性即判 TV——带触屏的国产盒子、车机
  ///   不再被误判成手机；
  /// - 或「无触屏 + 大屏」——没有系统特性但确为电视大屏的设备；
  /// - 桌面一律不判 TV（大屏显示器不误入遥控器布局）。
  ///
  /// 手动覆盖仍由 [resolveFormFactor] 最优先处理，本 getter 公开签名不变。
  bool get looksLikeTv =>
      !isDesktop &&
      (leanback || television || (!touchscreen && largeScreen));

  /// 探测失败时的安全值：当作有触摸屏且非大屏，宁可少判也不让手机误入 TV 布局。
  static const unknown = TvProbe();
}

/// 解析运行形态。
///
/// 优先级：手动覆盖 → 桌面 → Android 电视 → 手机。任何异常 probe 都会落到手机。
/// 桌面在读取 [TvProbe.looksLikeTv] 之前就返回，放宽判定后仍不误判；手动覆盖
/// 依旧优先于所有自动探测。
AppFormFactor resolveFormFactor({
  required bool isAndroid,
  required bool isDesktop,
  required TvProbe probe,
  TvOverride override = TvOverride.auto,
}) {
  if (override == TvOverride.on) return AppFormFactor.tv;
  if (override == TvOverride.off) {
    return isDesktop ? AppFormFactor.desktop : AppFormFactor.phone;
  }
  if (isDesktop) return AppFormFactor.desktop;
  if (isAndroid && probe.looksLikeTv) return AppFormFactor.tv;
  return AppFormFactor.phone;
}

/// 设置项字符串 → 枚举；非法值按「自动」处理。
TvOverride parseTvOverride(String? raw) => switch (raw) {
      'on' => TvOverride.on,
      'off' => TvOverride.off,
      _ => TvOverride.auto,
    };

/// 枚举 → 持久化字符串。
String tvOverrideName(TvOverride value) => switch (value) {
      TvOverride.on => 'on',
      TvOverride.off => 'off',
      TvOverride.auto => 'auto',
    };

/// 枚举 → 设置页展示文案。
String tvOverrideLabel(TvOverride value) => switch (value) {
      TvOverride.on => '强制开启',
      TvOverride.off => '关闭',
      TvOverride.auto => '自动（检测到电视时启用）',
    };
