import 'cast_profile.dart';
import 'cast_target.dart';
import 'didl.dart';

/// 投屏 URL 形态旋钮（M1，review §6「媒体 URL 形态」兜底）。
///
/// - `withExtension`（默认）：`/p/<token>/index.m3u8` —— 国产接收端靠 URL
///   扩展名选播放器；
/// - `bare`：`/p/<token>` —— 旧行为；诊断发现某设备只认裸 URL 时按设备
///   记该配方。
enum CastUrlSuffixMode { withExtension, bare }

/// 兼容模式（本机转码后投屏）三态（M5 接线选路逻辑；M2 先落字段与持久化）。
///
/// - `auto`（默认）：按媒体特征与设备 Sink 能力判定直投/中继；
/// - `always`：用户显式要求转码（设备投不出去时的第一动作）；
/// - `never`：禁用转码（保画质/CPU）。
enum CastTranscodeMode { auto, always, never }

/// 某型号设备一次成功的「发送配方」（v2）。
///
/// 字段全部有默认值：缺省配方等价于现状「完整 DIDL + standard 模板 +
/// 标准 SOAP 头」，保证「现在能投的设备不回归」；空链由
/// [CastRecipeStore.gradient] 逐级降级。
class CastRecipe {
  const CastRecipe({
    this.didl = DidlVariant.full,
    this.stopBeforeSet = false,
    this.quotedSoapAction = true,
    this.mPost = false,
    this.protocolMime = '',
    this.protocolInfoTemplate = DidlProtocolInfoTemplate.standard,
    this.playDelayMs = 0,
    this.subtitleMode = CastSubtitleMode.both,
    this.sendDcDescription = true,
    this.urlSuffixMode = CastUrlSuffixMode.withExtension,
    this.requirePlayConfirmation = false,
    this.transcodeMode = CastTranscodeMode.auto,
    this.successCount = 0,
  });

  /// DIDL 变体（v2：full / compact / compatEscaped，没有空 metadata）。
  final DidlVariant didl;

  /// SetAVTransportURI 前先 Stop（状态机卡在 PLAYING 的盒子需要）。
  final bool stopBeforeSet;

  /// **恒 true**（v2 起 SOAPACTION 无条件带双引号——cling 系接收端无条件
  /// 剥引号，不带引号必 401）。字段仅为旧 JSON 兼容保留，读入时强制 true。
  final bool quotedSoapAction;

  /// 该设备只吃 M-POST（POST 405 降级的结果被记住，省掉一次往返）。
  final bool mPost;

  /// 预检记录的 mime 段。**M1 起不再用于覆盖媒体 mime**（AC-13：Sink 只做
  /// 大类校验；`sinkEntry` 模板改由 Sink 条目实时解析）。
  final String protocolMime;

  /// `<res protocolInfo>` 第 4 段模板（v2 新增；默认 standard = 现状形状）。
  final DidlProtocolInfoTemplate protocolInfoTemplate;

  /// SetAVTransportURI 与 Play 之间的延迟（v2 新增；合法值 0/300/500ms）。
  final int playDelayMs;

  /// 字幕标签投送模式（v2 新增；默认 both = 三件套全量）。
  final CastSubtitleMode subtitleMode;

  /// 是否把防盗链头塞进 `dc:description`（v2 新增；默认 true = 现状）。
  final bool sendDcDescription;

  /// 投屏 URL 形态（默认带扩展名；`bare` 回退旧裸 URL 形态）。
  final CastUrlSuffixMode urlSuffixMode;

  /// Play 后是否强制状态确认（v2 新增；**默认 false = 现状行为**——门控
  /// 超时仍视为成功，避免误伤 AirPin / 央视频这类状态上报非标准的设备）。
  /// 打开后双确认（GetTransportInfo=PLAYING 且 GetPositionInfo URI 一致）
  /// 才算命中。
  final bool requirePlayConfirmation;

  /// 兼容模式三态（v2 新增；默认 auto，M5 接线选路）。
  final CastTranscodeMode transcodeMode;

  /// 累计成功次数（诊断用；配方失败一次即清空）。
  final int successCount;

  CastRecipe copyWith({
    DidlVariant? didl,
    bool? stopBeforeSet,
    bool? quotedSoapAction,
    bool? mPost,
    String? protocolMime,
    DidlProtocolInfoTemplate? protocolInfoTemplate,
    int? playDelayMs,
    CastSubtitleMode? subtitleMode,
    bool? sendDcDescription,
    CastUrlSuffixMode? urlSuffixMode,
    bool? requirePlayConfirmation,
    CastTranscodeMode? transcodeMode,
    int? successCount,
  }) =>
      CastRecipe(
        didl: didl ?? this.didl,
        stopBeforeSet: stopBeforeSet ?? this.stopBeforeSet,
        quotedSoapAction: quotedSoapAction ?? this.quotedSoapAction,
        mPost: mPost ?? this.mPost,
        protocolMime: protocolMime ?? this.protocolMime,
        protocolInfoTemplate:
            protocolInfoTemplate ?? this.protocolInfoTemplate,
        playDelayMs: playDelayMs ?? this.playDelayMs,
        subtitleMode: subtitleMode ?? this.subtitleMode,
        sendDcDescription: sendDcDescription ?? this.sendDcDescription,
        urlSuffixMode: urlSuffixMode ?? this.urlSuffixMode,
        requirePlayConfirmation:
            requirePlayConfirmation ?? this.requirePlayConfirmation,
        transcodeMode: transcodeMode ?? this.transcodeMode,
        successCount: successCount ?? this.successCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'didl': didl.name,
        'stopBeforeSet': stopBeforeSet,
        'quotedSoapAction': quotedSoapAction,
        'mPost': mPost,
        'protocolMime': protocolMime,
        'protocolInfoTemplate': protocolInfoTemplate.name,
        'playDelayMs': playDelayMs,
        'subtitleMode': subtitleMode.name,
        'sendDcDescription': sendDcDescription,
        'urlSuffixMode': urlSuffixMode.name,
        'requirePlayConfirmation': requirePlayConfirmation,
        'transcodeMode': transcodeMode.name,
        'successCount': successCount,
      };

  factory CastRecipe.fromJson(Map<String, dynamic> json) {
    // 旧 JSON（v3 及以下）的 didl 值映射：`none`（空 metadata，致命动作已
    // 取消）与 `minimal`（旧最小变体）→ `compact`。
    const didlLegacyMap = <String, DidlVariant>{
      'none': DidlVariant.compact,
      'minimal': DidlVariant.compact,
    };
    final didlRaw = json['didl'] as String?;
    final didl = DidlVariant.values.firstWhere(
      (v) => v.name == didlRaw,
      orElse: () =>
          didlLegacyMap[didlRaw] ?? DidlVariant.full,
    );
    final playDelay = json['playDelayMs'] as int? ?? -1;
    return CastRecipe(
      didl: didl,
      stopBeforeSet: json['stopBeforeSet'] as bool? ?? false,
      // v2 起 SOAPACTION 恒带引号：旧 JSON 记录的 false 同样强制 true。
      quotedSoapAction: true,
      mPost: json['mPost'] as bool? ?? false,
      protocolMime: json['protocolMime'] as String? ?? '',
      protocolInfoTemplate: DidlProtocolInfoTemplate.values.firstWhere(
        (v) => v.name == json['protocolInfoTemplate'],
        orElse: () => DidlProtocolInfoTemplate.standard,
      ),
      playDelayMs: playDelay == 0 || playDelay == 300 || playDelay == 500
          ? playDelay
          : 0,
      subtitleMode: CastSubtitleMode.values.firstWhere(
        (v) => v.name == json['subtitleMode'],
        orElse: () => CastSubtitleMode.both,
      ),
      sendDcDescription: json['sendDcDescription'] as bool? ?? true,
      urlSuffixMode: CastUrlSuffixMode.values.firstWhere(
        (v) => v.name == json['urlSuffixMode'],
        orElse: () => CastUrlSuffixMode.withExtension,
      ),
      requirePlayConfirmation: json['requirePlayConfirmation'] as bool? ?? false,
      transcodeMode: CastTranscodeMode.values.firstWhere(
        (v) => v.name == json['transcodeMode'],
        orElse: () => CastTranscodeMode.auto,
      ),
      successCount: json['successCount'] as int? ?? 0,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CastRecipe &&
      other.didl == didl &&
      other.stopBeforeSet == stopBeforeSet &&
      other.quotedSoapAction == quotedSoapAction &&
      other.mPost == mPost &&
      other.protocolMime == protocolMime &&
      other.protocolInfoTemplate == protocolInfoTemplate &&
      other.playDelayMs == playDelayMs &&
      other.subtitleMode == subtitleMode &&
      other.sendDcDescription == sendDcDescription &&
      other.urlSuffixMode == urlSuffixMode &&
      other.requirePlayConfirmation == requirePlayConfirmation &&
      other.transcodeMode == transcodeMode &&
      other.successCount == successCount;

  @override
  int get hashCode => Object.hash(
        didl,
        stopBeforeSet,
        quotedSoapAction,
        mPost,
        protocolMime,
        protocolInfoTemplate,
        playDelayMs,
        subtitleMode,
        sendDcDescription,
        urlSuffixMode,
        requirePlayConfirmation,
        transcodeMode,
        successCount,
      );

  @override
  String toString() => 'CastRecipe(${toJson()})';
}

/// Sink 清单短哈希（8 位 FNV-1a 截断；File2TV `caps_key = (kind, tuple(sink),
/// manufacturer)` 思路）。
///
/// `model:` 层配方键掺 Sink 摘要——同型号不同固件（Sink 宣告不同）天然分开，
/// 避免配方互相污染。空清单返回 `nosink`。
String castSinkHash(Iterable<String> sink) {
  final items = sink
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList()
    ..sort();
  if (items.isEmpty) return 'nosink';
  var h = 0x811C9DC5;
  void byte(int b) {
    h = ((h ^ b) * 0x01000193) & 0xFFFFFFFF;
  }

  for (final item in items) {
    for (final cu in item.codeUnits) {
      byte(cu & 0xFF);
      byte((cu >> 8) & 0xFF);
    }
    byte(0x0A); // 条目分隔符，避免 "ab"+"c" 与 "a"+"bc" 同哈希。
  }
  return h.toRadixString(16).padLeft(8, '0');
}

/// 画像预设配方（design §4.5 配方链第 3 层）：由 [CastDeviceProfile.profileId]
/// 决定的内置起点。
///
/// - `generic`：梯度首项（现状默认 full + standard）；
/// - `strictTitle`：full + standard——v2 起 DIDL 恒含 `dc:title`，此预设
///   主要是记录「曾因缺 title 被拒」的历史，行为与现状默认一致；
/// - `hlsByUrl`：URL 回退裸形态（Sink 宣告了 HLS 却拒过 `.m3u8` URL）；
/// - `pnRequired`：full + withPn（Sink 条目全带 DLNA.ORG_PN，按 PN 匹配）；
/// - 未知 id：无预设（null，直接走梯度）。
CastRecipe? profilePreset(String? profileId) => switch (profileId) {
      kProfileStrictTitle => const CastRecipe(didl: DidlVariant.full),
      kProfileHlsByUrl =>
        const CastRecipe(urlSuffixMode: CastUrlSuffixMode.bare),
      kProfilePnRequired => const CastRecipe(
          didl: DidlVariant.full,
          protocolInfoTemplate: DidlProtocolInfoTemplate.withPn),
      kProfileGeneric => const CastRecipe(),
      _ => null,
    };

/// 设备配方表（v4 双层键）。
///
/// - 精确层 `udn:<udn>`：这台设备的已验证配方；
/// - 共享层 `model:<model|manufacturer>:<sinkHash>`：同型号同固件（Sink 一致）
///   的设备共享，首投免跑全梯度。
/// 持久化由 `CastStore` 落到 `aquan_cast.json` v4 的 `recipes` 字段
/// （v1/v2/v3 旧三段式键视为空表），本类只负责内存表 + JSON 编解码；
/// [onChanged] 是可选的写盘回调。
class CastRecipeStore {
  CastRecipeStore({this.onChanged});

  /// 可选写盘回调（`CastStore` 注入）；内存表单独使用时为 null。
  final Future<void> Function()? onChanged;
  final Map<String, CastRecipe> _byKey = <String, CastRecipe>{};

  static String _norm(String raw) {
    final v = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return v.isEmpty ? '-' : v;
  }

  /// 精确层键：`udn:<udn>`（DLNA = UDN；Chromecast = `cast:host:port`）。
  static String udnKeyOf(CastTarget d) => 'udn:${d.id.trim().isEmpty ? '-' : d.id.trim()}';

  /// 共享层键：`model:<model|manufacturer>:<sinkHash>`。
  ///
  /// model 与 manufacturer 全空时不生成共享键（返回 null）——避免一堆匿名
  /// 设备互相污染。
  static String? modelKeyOf(CastTarget d, {List<String> sink = const []}) {
    final model = _norm(d.modelName);
    final maker = _norm(d.manufacturer);
    if (model == '-' && maker == '-') return null;
    return 'model:$model|$maker:${castSinkHash(sink)}';
  }

  /// 共享层键前缀（forget 时按前缀清掉该型号所有 Sink 变体）。
  static String? _modelKeyPrefix(CastTarget d) {
    final model = _norm(d.modelName);
    final maker = _norm(d.manufacturer);
    if (model == '-' && maker == '-') return null;
    return 'model:$model|$maker:';
  }

  /// v4 键只认 `udn:` / `model:` 前缀（v1/v2/v3 旧三段式键直接丢弃——
  /// 旧键与新查找语义不同，且旧版配方表从未接线落盘）。
  static bool _isValidKey(String key) =>
      key.startsWith('udn:') || key.startsWith('model:');

  /// 首次投屏的降级梯度（design §4.5，精选子集而非全组合）。
  ///
  /// **首项必须是现状默认形态（full + standard）**——保证现在能投的设备
  /// 不回归。`withPn` 仅当设备 Sink 显示按 PN 匹配时才会被尝试
  /// （`DlnaTransport.load` 按 Sink 过滤）。
  static const List<CastRecipe> gradient = <CastRecipe>[
    CastRecipe(didl: DidlVariant.full),
    CastRecipe(didl: DidlVariant.compact),
    CastRecipe(
        didl: DidlVariant.full,
        protocolInfoTemplate: DidlProtocolInfoTemplate.bare),
    CastRecipe(
        didl: DidlVariant.compact,
        protocolInfoTemplate: DidlProtocolInfoTemplate.bare),
    CastRecipe(
        didl: DidlVariant.full,
        protocolInfoTemplate: DidlProtocolInfoTemplate.withPn),
    CastRecipe(didl: DidlVariant.compatEscaped),
    CastRecipe(
        didl: DidlVariant.compact,
        protocolInfoTemplate: DidlProtocolInfoTemplate.wildcard),
  ];

  /// 命中优先级：udn 精确 → model 共享（含 sinkHash）。
  ///
  /// sink 未知时共享层只能命中 `nosink` 键（连接前查 URL 形态旋钮的
  /// 尽力而为；预检后按真实 Sink 查询必然命中已记忆的共享键）。
  CastRecipe? lookup(CastTarget d, {List<String> sink = const []}) {
    final byUdn = _byKey[udnKeyOf(d)];
    if (byUdn != null) return byUdn;
    final mk = modelKeyOf(d, sink: sink);
    return mk == null ? null : _byKey[mk];
  }

  /// 记住成功配方：写入 udn 精确层 + model 共享层（同型号同固件下次免扫）。
  Future<void> remember(
    CastTarget d,
    CastRecipe r, {
    List<String> sink = const [],
  }) async {
    void upsert(String key) {
      _byKey[key] =
          r.copyWith(successCount: (_byKey[key]?.successCount ?? 0) + 1);
    }

    upsert(udnKeyOf(d));
    final mk = modelKeyOf(d, sink: sink);
    if (mk != null) upsert(mk);
    await _notify();
  }

  /// 只更新某设备的兼容模式三态（M5-0 面板开关，AC-22）：写 udn 精确层并
  /// 落盘；不当作一次成功（successCount 不变），设备已有配方时保留其余字段。
  Future<void> setTranscodeMode(CastTarget d, CastTranscodeMode mode) async {
    final key = udnKeyOf(d);
    final existing = _byKey[key];
    _byKey[key] =
        (existing ?? const CastRecipe()).copyWith(transcodeMode: mode);
    await _notify();
  }

  /// 配方失败一次即清空：删 udn 精确层 + 该型号的全部共享层变体
  /// （失败时未必知道当时的 Sink，按前缀清理；其他设备的 udn 精确层
  /// 不受影响，下次投屏重回梯度扫描）。
  Future<void> forget(CastTarget d) async {
    var removed = _byKey.remove(udnKeyOf(d)) != null;
    final prefix = _modelKeyPrefix(d);
    if (prefix != null) {
      _byKey.removeWhere((k, _) => k.startsWith(prefix));
    }
    if (removed) await _notify();
  }

  /// 配方链（design §4.5）：udn 精确 → model 共享（+sinkHash）→ 画像预设
  /// （profileId 决定）→ 通用梯度；语义重复项只保留首个。
  ///
  /// 语义比较忽略 successCount（记忆项的成功计数会累加，不影响去重）。
  List<CastRecipe> fallbackChain(
    CastTarget d, {
    List<String> sink = const [],
    CastDeviceProfile? profile,
  }) {
    final chain = <CastRecipe>[];
    void add(CastRecipe? r) {
      if (r == null) return;
      final normalized = r.copyWith(successCount: 0);
      for (final existing in chain) {
        if (existing.copyWith(successCount: 0) == normalized) return;
      }
      chain.add(r);
    }

    add(_byKey[udnKeyOf(d)]);
    final mk = modelKeyOf(d, sink: sink);
    if (mk != null) add(_byKey[mk]);
    add(profilePreset(profile?.profileId));
    for (final r in gradient) {
      add(r);
    }
    return chain;
  }

  // ---------- 与 CastStore 的持久化接口 ----------

  Map<String, dynamic> toJson() => <String, dynamic>{
        for (final e in _byKey.entries) e.key: e.value.toJson(),
      };

  /// 读盘时整体替换（不触发写盘，避免加载即回写）。
  void replaceAll(Map<String, dynamic> json) {
    _byKey.clear();
    absorb(json);
  }

  /// 备份导入：只补当前没有的键，不覆盖本机已验证的成功配方；
  /// 非法前缀键（旧版三段式键）忽略。
  void absorb(Map<String, dynamic> json) {
    for (final e in json.entries) {
      if (!_isValidKey(e.key)) continue;
      final v = e.value;
      if (v is! Map) continue;
      if (_byKey.containsKey(e.key)) continue;
      _byKey[e.key] = CastRecipe.fromJson(Map<String, dynamic>.from(v));
    }
  }

  void clear() => _byKey.clear();

  Future<void> _notify() async {
    final cb = onChanged;
    if (cb != null) await cb();
  }
}
