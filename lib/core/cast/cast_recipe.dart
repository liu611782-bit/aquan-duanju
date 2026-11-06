import 'cast_target.dart';
import 'didl.dart';

/// 某型号设备一次成功的「发送配方」。
///
/// 字段全部有默认值：缺省配方等价于「完整 DIDL + 标准 SOAP 头」，
/// 空链则由 [CastRecipeStore.gradient] 逐级降级。
class CastRecipe {
  const CastRecipe({
    this.didl = DidlVariant.full,
    this.stopBeforeSet = false,
    this.quotedSoapAction = true,
    this.mPost = false,
    this.protocolMime = '',
    this.successCount = 0,
  });

  /// DIDL 变体（full → minimal → none 梯度）。
  final DidlVariant didl;

  /// SetAVTransportURI 前先 Stop（状态机卡在 PLAYING 的盒子需要）。
  final bool stopBeforeSet;

  /// `SOAPACTION` 是否带引号；false 时同时改用混合大小写头名 `SoapAction`。
  final bool quotedSoapAction;

  /// 该设备只吃 M-POST（POST 405 降级的结果被记住，省掉一次往返）。
  final bool mPost;

  /// GetProtocolInfo 预检挑中的 mime 段；空 = 用媒体自身 mime。
  final String protocolMime;

  /// 累计成功次数（诊断用；配方失败一次即清空）。
  final int successCount;

  CastRecipe copyWith({
    DidlVariant? didl,
    bool? stopBeforeSet,
    bool? quotedSoapAction,
    bool? mPost,
    String? protocolMime,
    int? successCount,
  }) =>
      CastRecipe(
        didl: didl ?? this.didl,
        stopBeforeSet: stopBeforeSet ?? this.stopBeforeSet,
        quotedSoapAction: quotedSoapAction ?? this.quotedSoapAction,
        mPost: mPost ?? this.mPost,
        protocolMime: protocolMime ?? this.protocolMime,
        successCount: successCount ?? this.successCount,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'didl': didl.name,
        'stopBeforeSet': stopBeforeSet,
        'quotedSoapAction': quotedSoapAction,
        'mPost': mPost,
        'protocolMime': protocolMime,
        'successCount': successCount,
      };

  factory CastRecipe.fromJson(Map<String, dynamic> json) => CastRecipe(
        didl: DidlVariant.values.firstWhere(
          (v) => v.name == json['didl'],
          orElse: () => DidlVariant.full,
        ),
        stopBeforeSet: json['stopBeforeSet'] as bool? ?? false,
        quotedSoapAction: json['quotedSoapAction'] as bool? ?? true,
        mPost: json['mPost'] as bool? ?? false,
        protocolMime: json['protocolMime'] as String? ?? '',
        successCount: json['successCount'] as int? ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is CastRecipe &&
      other.didl == didl &&
      other.stopBeforeSet == stopBeforeSet &&
      other.quotedSoapAction == quotedSoapAction &&
      other.mPost == mPost &&
      other.protocolMime == protocolMime &&
      other.successCount == successCount;

  @override
  int get hashCode => Object.hash(
        didl,
        stopBeforeSet,
        quotedSoapAction,
        mPost,
        protocolMime,
        successCount,
      );

  @override
  String toString() => 'CastRecipe(${toJson()})';
}

/// 设备指纹 → 成功配方表。
///
/// 键 = 归一化 `modelName|manufacturer|friendlyName`（小写、去空白，空用 `-`）。
/// 持久化由 `CastStore` 落到 `aquan_cast.json` 的 `recipes` 字段（v3），
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

  /// 首次投屏的梯度：完整 → 最小 → 空 metadata。
  static const List<CastRecipe> gradient = <CastRecipe>[
    CastRecipe(didl: DidlVariant.full),
    CastRecipe(didl: DidlVariant.minimal),
    CastRecipe(didl: DidlVariant.none),
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

  /// 命中配方优先，其后按 DIDL 梯度（跳过与命中项同变体的重复项）。
  List<CastRecipe> fallbackChain(CastTarget d) {
    final hit = lookup(d);
    if (hit == null) return List<CastRecipe>.of(gradient);
    return <CastRecipe>[
      hit,
      ...gradient.where((r) => r.didl != hit.didl),
    ];
  }

  // ---------- 与 CastStore 的 v3 持久化接口 ----------

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
