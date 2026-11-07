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

  test('无配方走三级梯度', () {
    final store = CastRecipeStore();
    final chain = store.fallbackChain(target());
    expect(chain.length, 3);
    expect(chain.map((r) => r.didl), [
      DidlVariant.full,
      DidlVariant.minimal,
      DidlVariant.none,
    ]);
  });

  test('记住的配方优先且不重复，成功次数累加', () async {
    final store = CastRecipeStore();
    final d = target();
    await store.remember(
        d, const CastRecipe(didl: DidlVariant.minimal, stopBeforeSet: true));
    final chain = store.fallbackChain(d);
    expect(chain.first.didl, DidlVariant.minimal);
    expect(chain.first.stopBeforeSet, isTrue);
    expect(chain.where((r) => r.didl == DidlVariant.minimal).length, 1);
    expect(store.lookup(d)!.successCount, 1);

    await store.remember(d, const CastRecipe(didl: DidlVariant.minimal));
    expect(store.lookup(d)!.successCount, 2);
  });

  test('配方失败后 forget 回到梯度', () async {
    final store = CastRecipeStore();
    final d = target();
    await store.remember(d, const CastRecipe(didl: DidlVariant.none));
    expect(store.lookup(d), isNotNull);
    await store.forget(d);
    expect(store.lookup(d), isNull);
    expect(store.fallbackChain(d).first.didl, DidlVariant.full);
  });

  test('JSON 往返与旧数据缺字段按默认值（v1 兼容）', () {
    final r = CastRecipe.fromJson(<String, dynamic>{
      'didl': 'none',
      'mPost': true,
    });
    expect(r.didl, DidlVariant.none);
    expect(r.mPost, isTrue);
    expect(r.quotedSoapAction, isTrue);
    expect(CastRecipe.fromJson(r.toJson()).didl, DidlVariant.none);

    final store = CastRecipeStore();
    expect(store.lookup(target()), isNull);
    store.replaceAll(<String, dynamic>{
      CastRecipeStore.keyOf(target()): r.toJson(),
    });
    expect(store.lookup(target())!.didl, DidlVariant.none);
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
