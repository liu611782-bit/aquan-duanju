import 'cast_controller.dart';

/// 中继失败回退直投（M1-6 / 父 PRD R9 / AC-21）。
///
/// resolvePlay 源（B 站等 DASH 双轨）强制走本机中继（ffmpeg 合流转 HLS）；
/// ffmpeg 起不来时旧行为是 `return null` →「该集没有可投的流」终结整次投屏。
/// 原始 URL 直投仍然值得一试（部分设备能吃视频直链），所以把「中继失败」
/// 降级为「直投 + 明确提示」，而不是终止投屏。
///
/// 返回 `(media, viaRelay)`；`viaRelay == false` 时调用方应提示
/// 「已改为直投，部分格式电视可能不支持」。彻底没有可投地址时返回 null。
///
/// mime 提示：中继产物恒为 HLS（[relayMimeHint]）；回退直投的原始 URL
/// 不携带中继的提示，交给三级判定的扩展名/嗅探证据。
///
/// 中继成功时产物带 `viaRelay: true`（M5-0）：兼容模式选路对本机中继产物
/// 恒直投，不会再套一层转码。
Future<(CastMedia, bool)?> castMediaViaRelayOrDirect({
  required String title,
  required String directUrl,
  required Future<String?> Function() startRelay,
  int episodeIndex = 1,
  int episodeCount = 0,
  Duration position = Duration.zero,
  Map<String, String> headers = const {},
  String relayMimeHint = 'application/vnd.apple.mpegurl',
  Duration? duration,
  String coverUrl = '',
  void Function(Object error, StackTrace stack)? onRelayError,
}) async {
  String? relayUrl;
  try {
    relayUrl = await startRelay();
  } on Exception catch (e, st) {
    // 原始异常只进 ErrorLog（调用方注入出口）；UI 只见固定文案。
    onRelayError?.call(e, st);
    relayUrl = null;
  }
  if (relayUrl == null && directUrl.isEmpty) return null;
  final viaRelay = relayUrl != null;
  return (
    CastMedia(
      url: relayUrl ?? directUrl,
      title: title,
      coverUrl: coverUrl,
      position: position,
      episodeIndex: episodeIndex,
      episodeCount: episodeCount,
      headers: headers,
      mimeHint: viaRelay ? relayMimeHint : '',
      duration: duration,
      viaRelay: viaRelay,
      // 恢复记录存源地址：中继产物随会话回收即死链。
      recordUrl: directUrl,
    ),
    viaRelay,
  );
}
