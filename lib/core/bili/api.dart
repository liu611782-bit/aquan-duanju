import 'dart:convert';
import 'dart:typed_data';

import 'session.dart';
import 'wbi.dart';

/// B 站封面字段（pic/cover）多为协议相对路径（`//i0.hdslb.com/...`），
/// 直接塞给 Image.network 会当相对路径加载失败 → 全部显示占位图。
String _biliCover(Object? raw) {
  final url = raw?.toString() ?? '';
  if (url.startsWith('//')) return 'https:$url';
  return url;
}

/// B 站 web API 客户端（搜索/推荐/详情/番剧/playurl/弹幕）。
///
/// 风控要点（两个参考项目均缺失、此处补齐）：所有请求带 buvid3 + bili_ticket；
/// WBI 接口（搜索）带 w_rid/wts；Cookie 失效（-101）由调用方引导重新登录。
class BiliApi {
  BiliApi(this.session);

  final BiliSession session;

  static const _base = 'https://api.bilibili.com';

  // ---------- 通用 ----------

  Future<Map<String, dynamic>> _getJson(
    String path,
    Map<String, String> query, {
    bool wbi = false,
  }) async {
    await session.ensureRiskParams();
    var params = query;
    if (wbi) {
      final cache = session.wbiCache;
      if (!cache.isFresh) {
        try {
          await session.fetchAccount();
        } catch (_) {}
      }
      params = WbiSigner.sign(query, cache.mixinKey);
    }
    final uri = Uri.parse('$_base$path').replace(
        queryParameters: params.isEmpty ? null : params);
    final res = await session.request(uri);
    final json = jsonDecode(utf8.decode(res));
    if (json is! Map) {
      throw BiliException('响应结构异常', detail: path);
    }
    final code = json['code'] as int? ?? -1;
    if (code != 0) {
      throw BiliException(json['message']?.toString() ?? '接口错误',
          code: code, detail: path);
    }
    return (json['data'] as Map?)?.cast<String, dynamic>() ?? {};
  }

  // ---------- 搜索（WBI） ----------

  /// 综合（视频 + 番剧）搜索：一次请求两个 search_type。
  Future<List<BiliSearchItem>> search(String query) async {
    final out = <BiliSearchItem>[];
    for (final type in ['video', 'media_bangumi']) {
      try {
        final data = await _getJson('/x/web-interface/wbi/search/type', {
          'search_type': type,
          'keyword': query,
          'page': '1',
        }, wbi: true);
        final result = data['result'];
        if (result is! List) continue;
        for (final item in result) {
          if (item is! Map) continue;
          out.add(BiliSearchItem.fromJson(item.cast<String, dynamic>(), type));
        }
      } on BiliException catch (e) {
        // -412 风控：直接抛给上层降速提示；单个类型失败不影响另一类型。
        if (e.code == -412) rethrow;
      }
    }
    return out;
  }

  // ---------- 首页推荐 ----------

  /// 推荐 feed（未登录可用，但需 buvid）。
  Future<List<BiliVideoCard>> homeFeed({int freshIndex = 1}) async {
    final data = await _getJson('/x/web-interface/index/top/feed/rcmd', {
      'fresh_idx_1h': '$freshIndex',
      'fresh_idx': '$freshIndex',
      'ps': '20',
    });
    final items = data['item'];
    if (items is! List) return const [];
    return [
      for (final item in items)
        if (item is Map)
          BiliVideoCard.fromJson(item.cast<String, dynamic>())
    ];
  }

  // ---------- 详情 ----------

  /// 视频详情（bvid）。
  Future<BiliVideoDetail> videoDetail(String bvid) async {
    final data = await _getJson('/x/web-interface/view', {'bvid': bvid});
    return BiliVideoDetail.fromJson(data);
  }

  /// 番剧/影视 season（ss_id 或 ep_id）。
  Future<BiliSeason> season({String? seasonId, String? epId}) async {
    final params = <String, String>{
      ?seasonId: seasonId,
      ?epId: epId,
    };
    final data = await _getJson('/pgc/view/web/season', params);
    return BiliSeason.fromJson(data);
  }

  // ---------- 播放地址 ----------

  /// DASH 播放地址（fnval=4048）；PGC 走 /pgc/player/web/playurl。
  ///
  /// [isPgc] 时 [bvid]/[cid] 传 ep_id 对应 cid， avid/kv 用于普通视频。
  Future<BiliPlayUrls> playUrls({
    required String cid,
    String? bvid,
    String? avid,
    String? epId,
    String? seasonId,
    bool isPgc = false,
  }) async {
    final path = isPgc ? '/pgc/player/web/playurl' : '/x/player/wbi/playurl';
    final query = <String, String>{
      'fnval': '4048', // DASH + HDR + Dolby 等
      'fourk': '1',
      'qn': '127',
      'cid': cid,
      if (!isPgc && bvid != null) 'bvid': bvid,
      if (!isPgc && avid != null) 'avid': avid,
      if (isPgc && epId != null) 'ep_id': epId,
      if (isPgc && seasonId != null) 'season_id': seasonId,
    };
    final data = await _getJson(path, query, wbi: !isPgc);
    final dash = data['dash'];
    final videos = <BiliStream>[];
    final audios = <BiliStream>[];
    if (dash is Map) {
      for (final v in (dash['video'] as List? ?? const [])) {
        if (v is! Map) continue;
        videos.add(BiliStream.fromJson(v.cast<String, dynamic>()));
      }
      for (final a in (dash['audio'] as List? ?? const [])) {
        if (a is! Map) continue;
        audios.add(BiliStream.fromJson(a.cast<String, dynamic>()));
      }
    }
    // 试看识别（PGC 未登录/非大会员）：durl 存在或 dash 缺失即受限。
    final durl = data['durl'];
    final isPreview = data['is_preview'] == true || videos.isEmpty;
    String? previewHint;
    if (isPreview) {
      previewHint = data['toast']?.toString() ?? '试看内容';
    }
    return BiliPlayUrls(
      videos..sort((a, b) => b.bandwidth.compareTo(a.bandwidth)),
      audios..sort((a, b) => b.bandwidth.compareTo(a.bandwidth)),
      durlFirstUrl:
          durl is List && durl.isNotEmpty && durl.first is Map
              ? (durl.first as Map)['url']?.toString()
              : null,
      isPreview: isPreview,
      previewHint: previewHint,
    );
  }

  // ---------- 用户 ----------

  /// 大会员/登录态快速校验（供 UI 显示）。
  Future<bool> checkLogin() async {
    try {
      final account = await session.fetchAccount();
      return session.isLoggedIn && account != null;
    } catch (_) {
      return false;
    }
  }

  /// 发送弹幕（需登录；csrf 取 bili_jct）。
  Future<void> sendDanmaku({
    required String bvid,
    required String cid,
    required String msg,
    int mode = 1, // 1=滚动 4=底部 5=顶部
  }) async {
    if (!session.isLoggedIn) {
      throw BiliException('发送弹幕需要先登录', code: -101);
    }
    final json = await session.postForm('/x/v2/dm/send/msg', {
      'bvid': bvid,
      'cid': cid,
      'msg': msg,
      'csrf': session.biliJct ?? '',
      'mode': '$mode',
      'pool_id': '0',
      'rnd': '${DateTime.now().millisecondsSinceEpoch}',
      'color': '16777215',
    });
    if (json['code'] != 0) {
      throw BiliException(json['message']?.toString() ?? '发送失败',
          code: (json['code'] as num?)?.toInt() ?? -1);
    }
  }

  /// 弹幕：按 cid 拉取 6 分钟分段（最多 [maxSegments] 段）。
  Future<List<DanmakuItem>> danmaku(String cid,
      {int maxSegments = 6}) async {
    final out = <DanmakuItem>[];
    for (var seg = 1; seg <= maxSegments; seg++) {
      try {
        final bytes = await session.request(Uri.parse(
            '$_base/x/v2/dm/web/seg.so?type=1&oid=$cid&pid=0&segment_index=$seg'));
        out.addAll(parseDanmakuSegment(bytes));
      } catch (_) {
        break; // 拉不到后续段就到此为止。
      }
    }
    return out;
  }
}

/// 搜索结果条目（video / media_bangumi 统一形态）。
class BiliSearchItem {
  const BiliSearchItem({
    required this.kind,
    required this.id,
    required this.title,
    required this.coverUrl,
    this.subTitle = '',
    this.epId = '',
  });

  factory BiliSearchItem.fromJson(Map<String, dynamic> json, String type) {
    final rawTitle = json['title']?.toString() ?? '';
    // 搜索结果标题带 <em class="keyword"> 高亮标签。
    final title = rawTitle.replaceAll(RegExp(r'</?em[^>]*>'), '');
    if (type == 'media_bangumi') {
      return BiliSearchItem(
        kind: BiliItemKind.season,
        id: json['season_id']?.toString() ?? '',
        title: title,
        coverUrl: _biliCover(json['cover']),
        subTitle: (json['desc']?.toString() ?? '').replaceAll('\n', ' '),
        epId: json['eps_id']?.toString() ?? '',
      );
    }
    return BiliSearchItem(
      kind: BiliItemKind.video,
      id: json['bvid']?.toString() ?? '',
      title: title,
      coverUrl: _biliCover(json['pic']),
      subTitle:
          'UP：${json['author']?.toString() ?? ''} · ${json['duration']?.toString() ?? ''}',
    );
  }

  final BiliItemKind kind;
  final String id;
  final String title;
  final String coverUrl;
  final String subTitle;

  /// 番剧条目带默认 ep_id（点进详情直接定位 season）。
  final String epId;
}

enum BiliItemKind { video, season }

/// 推荐 feed 卡片。
class BiliVideoCard {
  const BiliVideoCard({
    required this.bvid,
    required this.title,
    required this.coverUrl,
    this.upName = '',
    this.durationLabel = '',
  });

  factory BiliVideoCard.fromJson(Map<String, dynamic> json) => BiliVideoCard(
        bvid: json['bvid']?.toString() ?? '',
        title: (json['title']?.toString() ?? '')
            .replaceAll('<em class="keyword">', '')
            .replaceAll('</em>', ''),
        coverUrl: _biliCover(json['pic']),
        upName: json['owner'] is Map
            ? ((json['owner'] as Map)['name']?.toString() ?? '')
            : '',
        durationLabel:
            json['duration'] is num ? _fmtSeconds(json['duration'] as num) : '',
      );

  static String _fmtSeconds(num total) {
    final s = total.toInt();
    final m = s ~/ 60;
    final sec = s % 60;
    return '$m:${sec.toString().padLeft(2, '0')}';
  }

  final String bvid;
  final String title;
  final String coverUrl;
  final String upName;
  final String durationLabel;
}

/// 视频详情：分 P 列表。
class BiliVideoDetail {
  const BiliVideoDetail({
    required this.bvid,
    required this.title,
    required this.coverUrl,
    required this.description,
    required this.upName,
    required this.pages,
  });

  factory BiliVideoDetail.fromJson(Map<String, dynamic> json) {
    final pages = json['pages'];
    final owner = json['owner'];
    return BiliVideoDetail(
      bvid: json['bvid']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      coverUrl: _biliCover(json['pic']),
      description: json['desc']?.toString() ?? '',
      upName: owner is Map ? owner['name']?.toString() ?? '' : '',
      pages: [
        if (pages is List)
          for (final p in pages)
            if (p is Map)
              BiliPage(
                cid: p['cid']?.toString() ?? '',
                title: p['part']?.toString() ?? '',
                index: (p['page'] as num? ?? 1).toInt(),
              ),
      ],
    );
  }

  final String bvid;
  final String title;
  final String coverUrl;
  final String description;
  final String upName;
  final List<BiliPage> pages;
}

class BiliPage {
  const BiliPage({required this.cid, required this.title, required this.index});
  final String cid;
  final String title;
  final int index;
}

/// 番剧/影视 season：剧集列表。
class BiliSeason {
  const BiliSeason({
    required this.seasonId,
    required this.title,
    required this.coverUrl,
    required this.description,
    required this.episodes,
  });

  factory BiliSeason.fromJson(Map<String, dynamic> json) => BiliSeason(
        seasonId: json['season_id']?.toString() ?? '',
        title: json['title']?.toString() ?? '',
        coverUrl: _biliCover(json['cover']),
        description: (json['evaluate']?.toString() ?? '')
            .replaceAll(RegExp(r'<[^>]+>'), ''),
        episodes: [
          if (json['episodes'] is List)
            for (final ep in json['episodes'] as List)
              if (ep is Map)
                BiliEpisode(
                  epId: ep['id']?.toString() ?? '',
                  cid: ep['cid']?.toString() ?? '',
                  bvid: ep['bvid']?.toString() ?? '',
                  title: (ep['long_title']?.toString() ??
                          ep['title']?.toString() ??
                          '')
                      .trim(),
                  index: int.tryParse(ep['title']?.toString() ?? '') ?? 0,
                ),
        ],
      );

  final String seasonId;
  final String title;
  final String coverUrl;
  final String description;
  final List<BiliEpisode> episodes;
}

class BiliEpisode {
  const BiliEpisode({
    required this.epId,
    required this.cid,
    required this.bvid,
    required this.title,
    required this.index,
  });
  final String epId;
  final String cid;
  final String bvid;
  final String title;
  final int index;
}

/// playurl 结果：DASH 音视频分离 + 受限提示。
class BiliPlayUrls {
  const BiliPlayUrls(
    this.videos,
    this.audios, {
    this.durlFirstUrl,
    this.isPreview = false,
    this.previewHint,
  });

  /// 按带宽降序（≈清晰度优先）。
  final List<BiliStream> videos;
  final List<BiliStream> audios;
  final String? durlFirstUrl; // 非 DASH 兜底（部分受限内容）。
  final bool isPreview;
  final String? previewHint;

  bool get isPlayable => videos.isNotEmpty || durlFirstUrl != null;
}

/// 一条 DASH 流。
class BiliStream {
  const BiliStream({
    required this.url,
    required this.bandwidth,
    this.width = 0,
    this.height = 0,
    this.codecs = '',
  });

  factory BiliStream.fromJson(Map<String, dynamic> json) {
    var url =
        json['baseUrl']?.toString() ?? json['base_url']?.toString() ?? '';
    if (url.isEmpty) {
      final backup = json['backupUrl'];
      if (backup is List && backup.isNotEmpty) url = backup.first.toString();
    }
    return BiliStream(
      url: url,
      bandwidth: (json['bandwidth'] as num? ?? 0).toInt(),
      width: (json['width'] as num? ?? 0).toInt(),
      height: (json['height'] as num? ?? 0).toInt(),
      codecs: json['codecs']?.toString() ?? '',
    );
  }

  final String url;
  final int bandwidth;
  final int width;
  final int height;
  final String codecs;
}

/// 弹幕条目。
class DanmakuItem {
  const DanmakuItem({required this.progressMs, required this.text});
  final int progressMs;
  final String text;
}

/// 解析 /x/v2/dm/web/seg.so（protobuf wire format 手解）。
///
/// 消息结构（字段号）：DanmakuElem{ id=1(varint), progress=2(varint, ms),
/// mode=3(varint), text=4(string) }；Segment{ elems=1(repeated message) }。
List<DanmakuItem> parseDanmakuSegment(Uint8List bytes) {
  final out = <DanmakuItem>[];
  final reader = _PbReader(bytes);
  while (reader.hasMore) {
    final (field, wire) = reader.readTag();
    if (field == 1 && wire == 2) {
      out.add(_parseElem(reader.readBytes()));
    } else {
      reader.skipField(wire);
    }
  }
  out.sort((a, b) => a.progressMs.compareTo(b.progressMs));
  return out;
}

DanmakuItem _parseElem(Uint8List bytes) {
  final reader = _PbReader(bytes);
  var progressMs = 0;
  var text = '';
  while (reader.hasMore) {
    final (field, wire) = reader.readTag();
    if (field == 2 && wire == 0) {
      progressMs = reader.readVarint();
    } else if (field == 4 && wire == 2) {
      text = utf8.decode(reader.readBytes(), allowMalformed: true);
    } else {
      reader.skipField(wire);
    }
  }
  return DanmakuItem(progressMs: progressMs, text: text);
}

class _PbReader {
  _PbReader(this._bytes);

  final Uint8List _bytes;
  int _pos = 0;

  bool get hasMore => _pos < _bytes.length;

  (int, int) readTag() {
    final key = readVarint();
    return (key >> 3, key & 0x7);
  }

  int readVarint() {
    var result = 0;
    var shift = 0;
    while (true) {
      final b = _bytes[_pos++];
      result |= (b & 0x7f) << shift;
      if (b & 0x80 == 0) break;
      shift += 7;
    }
    return result;
  }

  Uint8List readBytes() {
    final len = readVarint();
    final out = Uint8List.sublistView(_bytes, _pos, _pos + len);
    _pos += len;
    return out;
  }

  void skipField(int wire) {
    switch (wire) {
      case 0:
        readVarint();
      case 1:
        _pos += 8;
      case 2:
        _pos += readVarint();
      case 5:
        _pos += 4;
      default:
        throw FormatException('未知 wire type $wire');
    }
  }
}
