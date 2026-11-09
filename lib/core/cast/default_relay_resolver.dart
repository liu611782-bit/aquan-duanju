/// 恢复投屏等「无播放页」场景的兜底转码执行体。
///
/// 播放页发起投屏时注入的 [CastTranscodeResolver] 带会话级管理（停旧起新、
/// 探针跟随、随 `_finishSession` 清空）——恢复投屏发生在面板上，播放页可能
/// 根本没开，此时 resolver 为 null：加密分集选路 relay → 「转码不可用」→
/// 回退直投加密源 → 接收端秒停（UI 冒烟实证：恢复会话 1s 即死）。
///
/// 本默认实现只做纯转码（无会话级旧中继管理，探针自停），由 bootstrap 注入
/// [CastController.defaultTranscodeResolver]；播放页注入的会话级 resolver
/// 收尾后恢复回本值。
library;

import 'cast_controller.dart';
import 'cast_relay_probe.dart';
import '../aqua_api.dart';
import '../sources/resolved_playback.dart' show headerOf;

CastTranscodeResolver defaultRelayResolver(
  AquaApi api, {
  String Function()? quality,
}) {
  return (m, {relayFormat, relaySubtitleUrl}) async {
    final relay = await api.castRelayStart(
      url: m.url,
      userAgent: headerOf(m.headers, 'user-agent') ?? '',
      referer: headerOf(m.headers, 'referer') ?? '',
      decKey: m.decKey,
      format: relayFormat ?? '',
      subtitleUrl: relaySubtitleUrl?.toString() ?? '',
      quality: quality?.call() ?? '',
    );
    final session = relay['session'] as String?;
    if (session != null) {
      // 探针在会话回收时自停（M0-5）。
      CastRelayProbe.instance.watch(api.castRelayStatus, session);
    }
    return relay['url'] as String?;
  };
}
