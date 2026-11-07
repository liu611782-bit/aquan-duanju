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

/// 设备指纹 → 成功配方表。
///
/// 键 = 归一化 `modelName|manufacturer|friendlyName`（小写、去空白，空用 `-`）。
/// 持久化由 `CastStore` 落到 `aquan_cast.json` 的 `recipes` 字段，
/// 本类只负责内存表 + JSON 编解码；[onChanged] 是可选的写盘回调。
class CastRecipeStore {
  CastRecipeStore({this.onChanged});

  /// 可选写盘回调（`CastStore` 注入）；内存表单独使用时为 null。
  final Future<void> Function()? onChanged;
  final Map<String, CastRecipe> _byKey = <String, CastRecipe>{};

  static String _norm(String raw) {
    final v = raw.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return v.isEmpty ? '-' : v;
  }

  static String keyOf(CastTarget d) =>
      '${_norm(d.modelName)}|${_norm(d.manufacturer)}|${_norm(d.name)}';

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

  CastRecipe? lookup(CastTarget d) => _byKey[keyOf(d)];

  Future<void> remember(CastTarget d, CastRecipe r) async {
    final key = keyOf(d);
    _byKey[key] =
        r.copyWith(successCount: (_byKey[key]?.successCount ?? 0) + 1);
    await _notify();
  }

  Future<void> forget(CastTarget d) async {
    if (_byKey.remove(keyOf(d)) == null) return;
    await _notify();
  }

  /// 命中配方优先，其后按梯度（跳过与命中项语义相同的条目）。
  ///
  /// 语义比较忽略 successCount（记忆项的成功计数会累加，不影响去重）。
  List<CastRecipe> fallbackChain(CastTarget d) {
    final hit = lookup(d);
    if (hit == null) return List<CastRecipe>.of(gradient);
    final normalized = hit.copyWith(successCount: 0);
    return <CastRecipe>[
      hit,
      ...gradient.where((r) => r.copyWith(successCount: 0) != normalized),
    ];
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

  /// 备份导入：只补当前没有的键，不覆盖本机已验证的成功配方。
  void absorb(Map<String, dynamic> json) {
    for (final e in json.entries) {
      if (e.key.isEmpty) continue;
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
