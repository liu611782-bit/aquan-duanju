import 'cast_media_type.dart';
import 'cast_recipe.dart';

/// 兼容模式选路结果（M5-0/M5-3）。
///
/// - [direct]：URL 原样投给设备（直投）；
/// - [proxy]：经 [CastMediaProxy] 本机代理中转（防盗链头/清单改写）；
/// - [relay]：走 Go `castRelayStart` 本机转码（ffmpeg 管道，产物 HLS）——
///   执行体是现有中继，不新增转码器；改的只是「什么情况选它」。
enum CastRoute { direct, proxy, relay }

/// 兼容模式（本机转码后投屏）选路判定表（design §4.10 M10）。
///
/// 判定优先级（从上到下首个命中生效）：
/// 1. `viaRelay` → direct：URL 已是本机中继/镜像产物，不能再套一层转码
///    （加密分集与 resolvePlay 源的现状路径在调用方完成中继后置位）；
/// 2. `encrypted` → relay：加密分集强制中继（现状不变，解密只有 ffmpeg 能做）；
/// 3. `mode == always` → relay：用户显式要求转码（投不出去时的第一动作）；
/// 4. `mode == never` → 现状逻辑：防盗链头走代理，否则直投（用户显式关闭转码）；
/// 5. `auto`（能力感知）：
///    - MKV/FLV/WEBM → relay（国产电视多不支持这三类容器）；
///    - HEVC/AV1 编码提示 → relay（castrelay 已统一转 H.264）；
///    - HLS 且 Sink **非空且不含** HLS mime → relay（产物已是 .m3u8）；
///    - 其余 → 防盗链头走代理，否则直投（MP4/TS/HLS+支持 Sink/未知类型
///      全部维持现状，保证「现在能投的设备不回归」）。
///
/// Sink 判定用 [sinkHasHls]：**Sink 为空（预检失败/无条目）视为「能力未知」**，
/// 不触发转码——绝不因为预检拿不到就把所有 HLS 都送进 ffmpeg。
CastRoute resolveCastRoute({
  required CastTranscodeMode mode,
  CastMediaType? mediaType,
  Iterable<String> sinkMimes = const <String>[],
  bool encrypted = false,
  bool viaRelay = false,
  bool needsProxy = false,
  String codecHint = '',
}) {
  if (viaRelay) return CastRoute.direct;
  if (encrypted) return CastRoute.relay;
  switch (mode) {
    case CastTranscodeMode.always:
      return CastRoute.relay;
    case CastTranscodeMode.never:
      return needsProxy ? CastRoute.proxy : CastRoute.direct;
    case CastTranscodeMode.auto:
      break;
  }
  // ---- auto：能力感知选路 ----
  final mime = mediaType?.mime.toLowerCase() ?? '';
  if (_isRelayContainer(mime)) return CastRoute.relay;
  if (_isHighCodec(codecHint)) return CastRoute.relay;
  final isHls = mediaType?.isHls ?? false;
  if (isHls) {
    final sink = sinkMimes.toList();
    if (sink.isNotEmpty && !sinkHasHls(sink)) return CastRoute.relay;
  }
  return needsProxy ? CastRoute.proxy : CastRoute.direct;
}

/// Sink 清单是否宣告了 HLS mime（HLS 别名组两条拼写任一即可）。
bool sinkHasHls(Iterable<String> sinkMimes) {
  for (final entry in sinkMimes) {
    final mime = _mimeOfSinkEntry(entry);
    if (mime == null) continue;
    if (_hlsMimes.contains(mime)) return true;
  }
  return false;
}

const Set<String> _hlsMimes = <String>{
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
};

/// 中继容器组：MKV / FLV / WEBM（含别名拼写）。
bool _isRelayContainer(String mime) =>
    mime == 'video/x-matroska' ||
    mime == 'video/x-mkv' ||
    mime == 'video/x-flv' ||
    mime == 'video/webm';

/// HEVC / AV1 编码提示（红果 VideoStream.codec 等来源；大小写不敏感，
/// h265/hevc 常混用）。H.264/空串不命中。
bool _isHighCodec(String codecHint) {
  final c = codecHint.trim().toLowerCase();
  return c == 'hevc' || c == 'h265' || c == 'h.265' || c == 'av1';
}

/// Sink 条目（`http-get:*:<mime>:<fourth>`）的 mime 段；与
/// cast_media_type.dart 的口径一致（`*/*` 与残缺条目不算证据）。
String? _mimeOfSinkEntry(String entry) {
  final parts = entry.split(':');
  if (parts.length < 3) return null;
  final mime = parts[2].trim().toLowerCase();
  if (mime.isEmpty || mime == '*/*') return null;
  return mime;
}
