/// 恢复投屏「跨天可用」的重新解析执行体（11-08-resume-reparse）。
///
/// 播放页发起投屏时会当场解析（加密分集另起本机中继），会话恢复记录只存
/// 源 URL——红果直链带时效签名，跨天/跨会话必失效。本执行体在面板一键恢复
/// 时按记录的 sourceId 重新走「listEpisodes 翻页定位集 → resolvePlayback →
/// （加密分集）castRelayStart 解密中继」（与播放页 resolveCastEpisode /
/// _openCastSheet 的加密中继同款入参），产出新鲜媒体；任何一步失败抛异常
/// 由控制器（CastController._replayLastSessionRecord）归一为「回退记录 URL」
/// 现状分支，原始异常只进 ErrorLog。
///
/// 中继会话回收语义与 defaultRelayResolver（defaultTranscodeResolver 兜底
/// 先例）一致：恢复场景无播放页可托管会话引用（播放页的 castRelayStop 停旧
/// 起新以页面持有 `_relaySession` 为前提），Dart 侧只起会话不留引用，探针
/// （CastRelayProbe）在会话被回收时自停（M0-5），Go 侧空闲 sweep（5min）兜底
/// 回收。bootstrap 注入 [CastController.defaultResumeProvider]。
library;

import '../aqua_api.dart';
import '../../models/models.dart' show Episode, VideoStream;
import 'cast_controller.dart';
import 'cast_relay_probe.dart';

/// listEpisodes 单页条数：红果剧集普遍 80-150 集，50 两页内覆盖绝大多数
/// 定位场景（翻到覆盖集号或 hasMore=false 为止）。
const int kResumeListEpisodesPageSize = 50;

/// 构造兜底恢复 provider。[quality] 取中继画质档位（R2 三档，随设置实读）。
CastResumeProvider defaultResumeProvider(
  AquaApi api, {
  String Function()? quality,
}) {
  return (record) async {
    final episode =
        await _findEpisode(api, record.sourceId, record.episodeIndex);
    if (episode == null) return null;
    final pb = await api.resolvePlayback(episode.id);
    final stream = _selectBestStream(pb.playback.streams);
    if (stream == null) return null;
    if (pb.contentKey != null) {
      // 加密分集：本机解密中继（播放页 _openCastSheet 同款入参；红果源
      // 无防盗链头，UA/Referer 不传）。
      final relay = await api.castRelayStart(
        url: stream.url,
        backupUrl: stream.backupUrl,
        decKey: pb.contentKey!.key,
        audioUrl: pb.playback.audioUrl,
        quality: quality?.call() ?? '',
      );
      final session = relay['session'] as String?;
      if (session != null) {
        // 探针在会话回收时自停（M0-5）；会话本体由 Go 空闲 sweep 兜底回收
        // （见库文档的回收语义说明）。
        CastRelayProbe.instance.watch(api.castRelayStatus, session);
      }
      final relayUrl = relay['url'] as String?;
      if (relayUrl == null || relayUrl.isEmpty) return null;
      return CastMedia(
        url: relayUrl,
        title: record.title,
        episodeIndex: record.episodeIndex,
        // 产物已是解密 HLS → 选路恒直投（M5-0）。
        viaRelay: true,
        // 恢复记录存源地址（产物随会话回收即死链，见 CastMedia.recordUrl）。
        recordUrl: stream.url,
        codecHint: stream.codec,
      );
    }
    return CastMedia(
      url: stream.url,
      title: record.title,
      episodeIndex: record.episodeIndex,
      // 非加密直链也回填 recordUrl：重写记录时 mediaUrl 与 url 同源（源地址）。
      recordUrl: stream.url,
      codecHint: stream.codec,
    );
  };
}

/// listEpisodes 翻页定位集号（1-based）：直到覆盖 [episodeIndex] 或翻尽
/// （hasMore=false / 游标耗尽）。找不到返回 null → 控制器回退记录 URL。
Future<Episode?> _findEpisode(
  AquaApi api,
  String seriesId,
  int episodeIndex,
) async {
  if (seriesId.isEmpty || episodeIndex <= 0) return null;
  var cursor = '';
  while (true) {
    final page = await api.listEpisodes(
      seriesId,
      cursor: cursor,
      pageSize: kResumeListEpisodesPageSize,
    );
    for (final e in page.items) {
      if (e.number == episodeIndex) return e;
    }
    if (!page.hasMore || page.cursor.isEmpty) return null;
    cursor = page.cursor;
  }
}

/// 与播放页 `_selectStream(pb, 'best')` 同语义的选流：按高度（缺位按
/// definition 前缀数字）与码率升序取末位；无可用品（url 非空）返回 null。
VideoStream? _selectBestStream(List<VideoStream> streams) {
  final usable = streams.where((s) => s.url.isNotEmpty).toList();
  if (usable.isEmpty) return null;
  int rank(VideoStream s) {
    if (s.height > 0) return s.height;
    final digits = RegExp(r'^(\d+)').firstMatch(s.definition)?.group(1);
    return digits == null ? 0 : int.parse(digits);
  }

  usable.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    return a.bitrate.compareTo(b.bitrate);
  });
  return usable.last;
}
