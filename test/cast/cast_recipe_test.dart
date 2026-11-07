import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';

CastTarget target({
  String model = 'QQLiveTV Render',
  String maker = 'Tencent',
  String name = '客厅极光TV',
}) =>
    CastTarget.dlna(DlnaDevice(
      udn: 'uuid:test-1',
      friendlyName: name,
      modelName: model,
      manufacturer: maker,
      controlUrl: 'http://192.168.1.9/AVTransport/control',
      location: 'http://192.168.1.9/description.xml',
    ));

void main() {
  test('设备指纹键归一化：大小写与空白不敏感', () {
    expect(
      CastRecipeStore.keyOf(target()),
      CastRecipeStore.keyOf(target(
        model: ' qqlivetv  render ',
        maker: ' TENCENT ',
        name: ' 客厅极光TV ',
      )),
    );
  });

  test('梯度 v2：7 项精选子集，首项 = 现状默认 full+standard（不回归）', () {
    final g = CastRecipeStore.gradient;
    expect(g.length, 7);
    expect(g[0].didl, DidlVariant.full);
    expect(g[0].protocolInfoTemplate, DidlProtocolInfoTemplate.standard);
    expect(g[1].didl, DidlVariant.compact);
    expect(g[1].protocolInfoTemplate, DidlProtocolInfoTemplate.standard);
    expect(g[2].didl, DidlVariant.full);
    expect(g[2].protocolInfoTemplate, DidlProtocolInfoTemplate.bare);
    expect(g[3].didl, DidlVariant.compact);
    expect(g[3].protocolInfoTemplate, DidlProtocolInfoTemplate.bare);
    expect(g[4].protocolInfoTemplate, DidlProtocolInfoTemplate.withPn);
    expect(g[5].didl, DidlVariant.compatEscaped);
    expect(g[6].didl, DidlVariant.compact);
    expect(g[6].protocolInfoTemplate, DidlProtocolInfoTemplate.wildcard);
  });

  test('无配方走 v2 梯度', () {
    final store = CastRecipeStore();
    final chain = store.fallbackChain(target());
    expect(chain, CastRecipeStore.gradient);
  });

  test('记住的配方优先且不重复，成功次数累加', () async {
    final store = CastRecipeStore();
    final d = target();

    // 命中项 = 梯度 g[3]（compact+bare）+ stopBeforeSet —— 与每个梯度项
    // 语义都不同 → 全梯度保留。
    const hit = CastRecipe(
        didl: DidlVariant.compact,
        protocolInfoTemplate: DidlProtocolInfoTemplate.bare,
        stopBeforeSet: true);
    await store.remember(d, hit);
    final chain = store.fallbackChain(d);
    final stored = store.lookup(d)!;
    expect(stored.didl, DidlVariant.compact);
    expect(stored.protocolInfoTemplate, DidlProtocolInfoTemplate.bare);
    expect(stored.stopBeforeSet, isTrue);
    expect(chain.where((r) => r == stored).length, 1, reason: '命中项不重复出现');
    expect(chain.length, 8, reason: '命中项与梯度项语义不同 → 1 + 全梯度 7 项');
    expect(stored.successCount, 1);

    await store.remember(d, hit);
    expect(store.lookup(d)!.successCount, 2);

    // 命中项与梯度条目语义相同（仅成功计数不同）→ 去重不重复出现。
    final store2 = CastRecipeStore();
    await store2.remember(
        d, const CastRecipe(didl: DidlVariant.compact, protocolInfoTemplate: DidlProtocolInfoTemplate.bare));
    final chain2 = store2.fallbackChain(d);
    expect(chain2.length, 7, reason: '命中项与梯度 g[3] 相同 → 跳过重复');
    expect(
        chain2.where((r) =>
            r.didl == DidlVariant.compact &&
            r.protocolInfoTemplate == DidlProtocolInfoTemplate.bare).length,
        1);
  });

  test('配方失败后 forget 回到梯度', () async {
    final store = CastRecipeStore();
    final d = target();
    await store.remember(d, const CastRecipe(didl: DidlVariant.compatEscaped));
    expect(store.lookup(d), isNotNull);
    await store.forget(d);
    expect(store.lookup(d), isNull);
    expect(store.fallbackChain(d).first.didl, DidlVariant.full);
  });

  test('旧 JSON（v3 及以下）读入兼容：none/minimal → compact；quotedSoapAction 强制 true',
      () {
    final noneRecipe = CastRecipe.fromJson(<String, dynamic>{
      'didl': 'none',
      'mPost': true,
      'quotedSoapAction': false,
    });
    expect(noneRecipe.didl, DidlVariant.compact,
        reason: '空 metadata 是致命动作，读入映射 compact');
    expect(noneRecipe.mPost, isTrue);
    expect(noneRecipe.quotedSoapAction, isTrue,
        reason: 'v2 起 SOAPACTION 恒带引号，旧 false 强制 true');
    expect(CastRecipe.fromJson(noneRecipe.toJson()).didl, DidlVariant.compact);

    final minimalRecipe =
        CastRecipe.fromJson(<String, dynamic>{'didl': 'minimal'});
    expect(minimalRecipe.didl, DidlVariant.compact);

    final store = CastRecipeStore();
    store.replaceAll(<String, dynamic>{
      CastRecipeStore.keyOf(target()): noneRecipe.toJson(),
    });
    expect(store.lookup(target())!.didl, DidlVariant.compact);
  });

  test('M2-5 新字段：默认值、JSON 往返、非法值回落', () {
    // 默认值 = 现状行为。
    const def = CastRecipe();
    expect(def.protocolInfoTemplate, DidlProtocolInfoTemplate.standard);
    expect(def.playDelayMs, 0);
    expect(def.subtitleMode, CastSubtitleMode.both);
    expect(def.sendDcDescription, isTrue);
    expect(def.requirePlayConfirmation, isFalse,
        reason: 'AC-23：默认 false，行为与现状一致');
    expect(def.transcodeMode, CastTranscodeMode.auto);

    // 往返不丢。
    const full = CastRecipe(
      didl: DidlVariant.compatEscaped,
      protocolInfoTemplate: DidlProtocolInfoTemplate.sinkEntry,
      playDelayMs: 300,
      subtitleMode: CastSubtitleMode.captionInfoEx,
      sendDcDescription: false,
      requirePlayConfirmation: true,
      transcodeMode: CastTranscodeMode.always,
      successCount: 2,
    );
    final back = CastRecipe.fromJson(full.toJson());
    expect(back.didl, DidlVariant.compatEscaped);
    expect(back.protocolInfoTemplate, DidlProtocolInfoTemplate.sinkEntry);
    expect(back.playDelayMs, 300);
    expect(back.subtitleMode, CastSubtitleMode.captionInfoEx);
    expect(back.sendDcDescription, isFalse);
    expect(back.requirePlayConfirmation, isTrue);
    expect(back.transcodeMode, CastTranscodeMode.always);
    expect(back.successCount, 2);
    expect(back, full);

    // 非法值回落默认。
    final illegal = CastRecipe.fromJson(<String, dynamic>{
      'protocolInfoTemplate': 'not-a-template',
      'playDelayMs': 12345,
      'subtitleMode': 'wild-mode',
      'transcodeMode': 'sometimes',
      'didl': 'bogus',
    });
    expect(illegal.protocolInfoTemplate, DidlProtocolInfoTemplate.standard);
    expect(illegal.playDelayMs, 0, reason: '合法值仅 0/300/500');
    expect(illegal.subtitleMode, CastSubtitleMode.both);
    expect(illegal.transcodeMode, CastTranscodeMode.auto);
    expect(illegal.didl, DidlVariant.full);
  });

  test('playDelayMs 合法值 0/300/500 往返', () {
    for (final ms in const [0, 300, 500]) {
      final r = CastRecipe.fromJson(
          CastRecipe(playDelayMs: ms).toJson());
      expect(r.playDelayMs, ms);
    }
  });

  test('urlSuffixMode：默认带扩展名；bare 往返；旧 JSON 未知值回落默认（M1/R1）',
      () {
    // 默认值 = withExtension（URL 带扩展名是新默认形态）。
    expect(const CastRecipe().urlSuffixMode, CastUrlSuffixMode.withExtension);
    // bare 往返。
    final bare = const CastRecipe(urlSuffixMode: CastUrlSuffixMode.bare);
    expect(CastRecipe.fromJson(bare.toJson()).urlSuffixMode,
        CastUrlSuffixMode.bare);
    // 旧 JSON 无该字段 → 默认；非法值 → 回落默认。
    expect(
      CastRecipe.fromJson(<String, dynamic>{'didl': 'full'}).urlSuffixMode,
      CastUrlSuffixMode.withExtension,
    );
    expect(
      CastRecipe.fromJson(<String, dynamic>{
        'urlSuffixMode': 'not-a-mode',
      }).urlSuffixMode,
      CastUrlSuffixMode.withExtension,
    );
  });
}
