import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'cast_target.dart';

/// 投屏媒体的大类（DIDL `upnp:class` 与代理路由分派共用）。
enum CastMediaKind { video, audio, image, unknown }

/// 投屏媒体的规范类型描述。
///
/// [mime] 是投给设备的规范 mime（同时用于 DIDL protocolInfo 与 HTTP
/// Content-Type，两者必须一致）；[fileName] 是媒体服务 URL 的文件名部分，
/// 必须让接收端靠「URL 扩展名」就能判断容器（HLS → index.m3u8）——
/// 国产接收端（leancast / KBTVCaster 等）只看 URL 子串选播放器。
class CastMediaType {
  const CastMediaType({
    required this.mime,
    required this.fileName,
    required this.kind,
    this.live = false,
  });

  final String mime;
  final String fileName;
  final CastMediaKind kind;

  /// 直播流（HLS 事件流 / 镜像 TS）。只影响 DIDL 侧语义（M3 起使用），
  /// 不改变 mime 与文件名判定。
  final bool live;

  /// mime 是否属于 HLS 别名组（`application/vnd.apple.mpegurl` /
  /// `application/x-mpegurl`）。
  bool get isHls => _hlsAliasGroup.contains(mime.toLowerCase());

  /// 无任何证据时的兜底：**绝不伪装成 video/mp4**。mime 用 octet-stream、
  /// 文件名不带扩展名（骗扩展名比不带给电视的伤害更大）。
  static const CastMediaType unknown = CastMediaType(
    mime: 'application/octet-stream',
    fileName: 'media',
    kind: CastMediaKind.unknown,
  );

  /// unknown 类型（可带 live 标记）。
  static CastMediaType unknownOf({bool live = false}) => live
      ? const CastMediaType(
          mime: 'application/octet-stream',
          fileName: 'media',
          kind: CastMediaKind.unknown,
          live: true,
        )
      : unknown;

  @override
  String toString() => 'CastMediaType($mime, $fileName, ${kind.name})';
}

/// mime 别名组（review §8.7/§8.9）：同一容器的多种设备拼写。
///
/// 部分电视只认 `video/vnd.dlna.mpeg-tts`（TS）、Samsung 只认
/// `video/x-mkv`（Matroska）、puppy-store-cast 接收端同时宣告两种 HLS 拼写。
const List<List<String>> _mimeAliasGroups = <List<String>>[
  <String>['video/mp2t', 'video/vnd.dlna.mpeg-tts'],
  <String>['application/vnd.apple.mpegurl', 'application/x-mpegurl'],
  <String>['video/x-matroska', 'video/x-mkv'],
];

const List<String> _hlsAliasGroup = <String>[
  'application/vnd.apple.mpegurl',
  'application/x-mpegurl',
];

const List<String> _tsAliasGroup = <String>[
  'video/mp2t',
  'video/vnd.dlna.mpeg-tts',
];

/// 解析投屏媒体的规范类型（三级判定，判据表见父任务 design §4.1）。
///
/// 优先级：显式 hint → URL 扩展名 → 内容嗅探（[sniffHead] 取前 8KB）。
/// **绝不以 `video/mp4` 兜底**——无法判定时返回 [CastMediaType.unknown]。
///
/// 特殊规则：
/// - hint 是 `video/mp4` 而 URL 无扩展名时视为「解析层的兜底猜测」而非证据，
///   交给嗅探（`mimeTypeForMedia` 对无扩展名地址恒回 video/mp4，直接采信
///   会复活旧 `_mimeForCast` 的 bug）；
/// - 上游伪装 `image/*`（dart_cast media_proxy 实证：.ts 上游谎报 image/png）
///   时，URL 扩展名与嗅探证据优先于 image 提示；
/// - [sinkMimes] 提供设备 Sink 条目时做「拼写选择」（不过滤）：本判定结果
///   的 mime 落在某个别名组内、而 Sink 里有同组条目 → 照抄设备写法；
/// - 嗅探到 HTML/JSON → 抛 [CastException]：把代理层「错误页不喂电视」的
///   防黑屏行为前移到类型判定层（投屏前就报「这个地址不是视频」）。
Future<CastMediaType> resolveCastMediaType({
  required Uri url,
  String? hintMime,
  bool live = false,
  Iterable<String> sinkMimes = const <String>[],
  Future<List<int>?> Function(Uri url)? sniffHead,
}) async {
  final fromExt = _typeFromUrlPath(url);
  var hint = _typeFromHint(hintMime);

  // 上游伪装 image/*：URL 已给出非 image 的容器证据 → 不信 image 提示。
  if (hint != null &&
      hint.kind == CastMediaKind.image &&
      fromExt != null &&
      fromExt.kind != CastMediaKind.image) {
    hint = null;
  }
  // video/mp4 兜底提示 + 无扩展名：不是证据，交给嗅探。
  if (hint != null && hint.mime == 'video/mp4' && fromExt == null) {
    hint = null;
  }

  var type = hint ?? fromExt;

  // 需要嗅探：完全无证据，或 image 提示未被 URL 佐证（伪装检测）。
  final needSniff =
      type == null || (type.kind == CastMediaKind.image && fromExt == null);
  if (needSniff && sniffHead != null) {
    final head = await sniffHead(url);
    final sniffed = _typeFromSniff(head);
    if (sniffed != null) {
      type = sniffed;
    } else if (_looksLikeHtmlOrJson(head)) {
      throw CastException('该地址不是可投屏的视频（网页或数据接口），请换一个播放地址');
    }
  }

  if (type == null) return CastMediaType.unknownOf(live: live);

  // Sink 拼写选择：照抄设备自己的写法（仅换拼写，绝不过滤）。
  if (sinkMimes.isNotEmpty && type.kind != CastMediaKind.unknown) {
    final spelled = preferSinkSpelling(type.mime, sinkMimes);
    if (spelled != type.mime) {
      type = CastMediaType(
        mime: spelled,
        fileName: type.fileName,
        kind: type.kind,
        live: live,
      );
    }
  }

  if (type.live == live) return type;
  return CastMediaType(
    mime: type.mime,
    fileName: type.fileName,
    kind: type.kind,
    live: live,
  );
}

/// Sink 拼写选择（review §8.7）：Sink 里有同别名组条目时照抄设备写法；
/// 没有则用规范拼写。**只换拼写，不过滤**——Sink 缺 mime 不拒投（go2tv 原则）。
String preferSinkSpelling(String canonical, Iterable<String> sinkMimes) {
  final wanted = canonical.toLowerCase();
  List<String>? group;
  for (final g in _mimeAliasGroups) {
    if (g.contains(wanted)) {
      group = g;
      break;
    }
  }
  if (group == null) return canonical;
  for (final entry in sinkMimes) {
    final mime = _mimeOfSinkEntry(entry);
    if (mime == null) continue;
    if (mime == wanted) return canonical;
    if (group.contains(mime)) return mime;
  }
  return canonical;
}

/// protocolInfo 条目（`http-get:*:<mime>:<fourth>`）的 mime 段。
String? _mimeOfSinkEntry(String entry) {
  final parts = entry.split(':');
  if (parts.length < 3) return null;
  final mime = parts[2].trim().toLowerCase();
  if (mime.isEmpty || mime == '*/*') return null;
  return mime;
}

/// 按 URL 路径扩展名同步判定（无 hint、无嗅探；本地文件路径等场景）。
/// 无已知扩展名返回 [CastMediaType.unknown]。
CastMediaType castMediaTypeFromUrlPath(Uri url) =>
    _typeFromUrlPath(url) ?? CastMediaType.unknown;

/// URL 路径扩展名 → 类型（判定表，design §4.1）。
CastMediaType? _typeFromUrlPath(Uri url) {
  final path = url.path.toLowerCase();
  final dot = path.lastIndexOf('.');
  if (dot < 0) return null;
  final ext = path.substring(dot + 1);
  if (ext.isEmpty || ext.contains('/')) return null;
  return switch (ext) {
    'm3u8' || 'm3u' => _hls(),
    'ts' => _ts(),
    'mp4' || 'm4v' => _video('video/mp4', 'video.mp4'),
    'mkv' => _video('video/x-matroska', 'video.mkv'),
    'webm' => _video('video/webm', 'video.webm'),
    'flv' => _video('video/x-flv', 'video.flv'),
    'mov' => _video('video/quicktime', 'video.mov'),
    'avi' => _video('video/x-msvideo', 'video.avi'),
    'mp3' => _audio('audio/mpeg', 'audio.mp3'),
    'm4a' || 'aac' => _audio('audio/mp4', 'audio.m4a'),
    'flac' => _audio('audio/flac', 'audio.flac'),
    'wav' => _audio('audio/wav', 'audio.wav'),
    'ogg' => _audio('audio/ogg', 'audio.ogg'),
    'jpg' || 'jpeg' => _image('image/jpeg', 'image.jpg'),
    'png' => _image('image/png', 'image.png'),
    'webp' => _image('image/webp', 'image.webp'),
    _ => null,
  };
}

/// 显式 mime 提示 → 类型（hint 拼写照原样保留，判定表同上）。
CastMediaType? _typeFromHint(String? hintMime) {
  final mime = (hintMime ?? '').trim().toLowerCase();
  if (mime.isEmpty) return null;
  if (_hlsAliasGroup.contains(mime)) {
    return CastMediaType(
        mime: mime, fileName: 'index.m3u8', kind: CastMediaKind.video);
  }
  if (_tsAliasGroup.contains(mime)) {
    return CastMediaType(
        mime: mime, fileName: 'stream.ts', kind: CastMediaKind.video);
  }
  const table = <String, (String, CastMediaKind)>{
    'video/mp4': ('video.mp4', CastMediaKind.video),
    'video/x-matroska': ('video.mkv', CastMediaKind.video),
    'video/x-mkv': ('video.mkv', CastMediaKind.video),
    'video/webm': ('video.webm', CastMediaKind.video),
    'video/x-flv': ('video.flv', CastMediaKind.video),
    'video/quicktime': ('video.mov', CastMediaKind.video),
    'video/x-msvideo': ('video.avi', CastMediaKind.video),
    'audio/mpeg': ('audio.mp3', CastMediaKind.audio),
    'audio/mp4': ('audio.m4a', CastMediaKind.audio),
    'audio/flac': ('audio.flac', CastMediaKind.audio),
    'audio/wav': ('audio.wav', CastMediaKind.audio),
    'audio/ogg': ('audio.ogg', CastMediaKind.audio),
    'image/jpeg': ('image.jpg', CastMediaKind.image),
    'image/png': ('image.png', CastMediaKind.image),
    'image/webp': ('image.webp', CastMediaKind.image),
  };
  final hit = table[mime];
  if (hit == null) return null;
  return CastMediaType(mime: mime, fileName: hit.$1, kind: hit.$2);
}

CastMediaType _hls() => CastMediaType(
    mime: 'application/vnd.apple.mpegurl',
    fileName: 'index.m3u8',
    kind: CastMediaKind.video);
CastMediaType _ts() => CastMediaType(
    mime: 'video/mp2t', fileName: 'stream.ts', kind: CastMediaKind.video);
CastMediaType _video(String mime, String fileName) =>
    CastMediaType(mime: mime, fileName: fileName, kind: CastMediaKind.video);
CastMediaType _audio(String mime, String fileName) =>
    CastMediaType(mime: mime, fileName: fileName, kind: CastMediaKind.audio);
CastMediaType _image(String mime, String fileName) =>
    CastMediaType(mime: mime, fileName: fileName, kind: CastMediaKind.image);

/// 内容嗅探（前 8KB 原始字节）：HLS / MP4(ftyp) / TS sync(0x47@0&188) / FLV。
/// 二进制容器特征优先于文本特征（MP4 首字节可能是任意值，包括 `{`）。
CastMediaType? _typeFromSniff(List<int>? head) {
  if (head == null || head.isEmpty) return null;
  if (_asciiStartsWith(head, _textStart(head), '#EXTM3U')) return _hls();
  if (head.length >= 8 && _asciiEqualsAt(head, 4, 'ftyp')) {
    return _video('video/mp4', 'video.mp4');
  }
  if (_asciiStartsWith(head, 0, 'FLV')) return _video('video/x-flv', 'video.flv');
  if (head[0] == 0x47 && head.length > 188 && head[188] == 0x47) return _ts();
  return null;
}

/// 文本文档特征（HTML / JSON）：命中即明确失败，不投。
/// HTML 标记大小写不敏感（`<!DOCTYPE` 是惯例写法）。
bool _looksLikeHtmlOrJson(List<int>? head) {
  if (head == null || head.isEmpty) return false;
  final start = _textStart(head);
  for (final mark in const ['<!doctype', '<html', '<?xml', '{', '[']) {
    if (_asciiStartsWithIgnoreCase(head, start, mark)) return true;
  }
  return false;
}

/// 跳过 BOM 与前导空白后的文本起点。
int _textStart(List<int> head) {
  var start = 0;
  if (head.length >= 3 && head[0] == 0xEF && head[1] == 0xBB && head[2] == 0xBF) {
    start = 3;
  }
  while (start < head.length) {
    final b = head[start];
    if (b == 0x20 || b == 0x09 || b == 0x0D || b == 0x0A) {
      start++;
      continue;
    }
    break;
  }
  return start;
}

bool _asciiStartsWith(List<int> head, int offset, String mark) {
  if (offset < 0 || offset + mark.length > head.length) return false;
  return _asciiEqualsAt(head, offset, mark);
}

bool _asciiEqualsAt(List<int> head, int offset, String mark) {
  for (var i = 0; i < mark.length; i++) {
    if (head[offset + i] != mark.codeUnitAt(i)) return false;
  }
  return true;
}

bool _asciiStartsWithIgnoreCase(List<int> head, int offset, String mark) {
  if (offset < 0 || offset + mark.length > head.length) return false;
  for (var i = 0; i < mark.length; i++) {
    final b = head[offset + i] | 0x20; // ASCII 小写化
    if (b != mark.codeUnitAt(i)) return false;
  }
  return true;
}

/// 默认嗅探实现：GET + `Range: bytes=0-8191` 取前 8KB 原始字节。
///
/// 复用现有 HTTP 客户端模式（[HttpClient] + connectionTimeout）；4s 读取
/// 上限；任何失败返回 null——嗅探只是第三级证据，失败不阻断判定。
/// [headers] 传媒体自带请求头（防盗链直链嗅探需要 Referer/UA）。
Future<List<int>?> defaultSniffHead(
  Uri url, {
  Map<String, String> headers = const <String, String>{},
  Duration timeout = const Duration(seconds: 4),
}) async {
  final client = HttpClient();
  try {
    client.connectionTimeout = timeout;
    final req = await client.getUrl(url);
    headers.forEach(req.headers.set);
    req.headers.set('Range', 'bytes=0-8191');
    final res = await req.close().timeout(timeout);
    if (res.statusCode >= 400) {
      return null;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
      if (builder.length >= 8192) break; // 上游不理 Range 时止步 8KB
    }
    return builder.takeBytes();
  } catch (_) {
    return null;
  } finally {
    client.close(force: true);
  }
}
