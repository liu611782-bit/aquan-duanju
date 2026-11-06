import 'dart:io';

import 'package:flutter/services.dart';

import 'tv_mode.dart';

const MethodChannel _tvChannel = MethodChannel('aquan/tv');

/// 读取 Android 系统特性。
///
/// 非 Android、通道异常、返回格式不符都返回 [TvProbe.unknown]（当作有触摸屏），
/// 调用方据此回落到手机布局——判定失败不能影响正常启动。
Future<TvProbe> probeTvPlatform() async {
  if (!Platform.isAndroid) return TvProbe.unknown;
  try {
    final raw = await _tvChannel.invokeMethod<Object?>('probe');
    if (raw is! Map) return TvProbe.unknown;
    return TvProbe(
      leanback: raw['leanback'] == true,
      television: raw['television'] == true,
      // 缺失时按「有触摸屏」处理：少判 TV 比误判安全。
      touchscreen: raw['touchscreen'] != false,
    );
  } catch (_) {
    return TvProbe.unknown;
  }
}
