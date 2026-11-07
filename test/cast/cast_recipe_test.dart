import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_profile.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/store/stores.dart';

CastTarget target({
  String udn = 'uuid:test-1',
  String model = 'QQLiveTV Render',
  String maker = 'Tencent',
  String name = '客厅极光TV',
}) =>
    CastTarget.dlna(DlnaDevice(
      udn: udn,
      friendlyName: name,
      modelName: model,
      manufacturer: maker,
      controlUrl: 'http://192.168.1.9/AVTransport/control',
      location: 'http://192.168.1.9/description.xml',
    ));

const sinkMp4 = <String>['http-get:*:video/mp4:*'];

void main() {
  test('双层键：udn 精确键与 model 共享键的形状与归一化', () {
    expect(CastRecipeStore.udnKeyOf(target()), 'udn:uuid:test-1');
    // 归一化：大小写与空白不敏感。
    expect(
      CastRecipeStore.modelKeyOf(target(udn: 'u2'),
          sink: const <String>[]),
      CastRecipeStore.modelKeyOf(
        target(udn: 'u2', model: ' qqlivetv  render ', maker: ' TENCENT '),
        sink: const <String>[],
      ),
    );
    // model 键 = model|manufacturer:Sink 短哈希；空 Sink 用 nosink。
    expect(
      CastRecipeStore.modelKeyOf(target(), sink: const <String>[]),
      'model:qqlivetvrender|tencent:nosink',
    );
    final withSink = CastRecipeStore.modelKeyOf(target(), sink: sinkMp4)!;
    expect(withSink, startsWith('model:qqlivetvrender|tencent:'));
    expect(withSink.split(':').last, matches(RegExp(r'^[0-9a-f]{8}$')));
    // model 与 manufacturer 全空 → 不生成共享键（防匿名设备互相污染）。
    expect(
      CastRecipeStore.modelKeyOf(
        target(udn: 'u3', model: '', maker: ''),
        sink: sinkMp4,
      ),
      isNull,
    );
  });

  test('castSinkHash：顺序无关、内容敏感、空清单 nosink', () {
    expect(castSinkHash(const <String>[]), 'nosink');
    expect(castSinkHash(const <String>['  ']), 'nosink');
    final a = castSinkHash(sinkMp4);
    expect(a, castSinkHash(sinkMp4.reversed.toList()), reason: '顺序无关');
    expect(a, isNot(castSinkHash(['http-get:*:video/mpeg:*'])),
        reason: '内容不同 → 哈希不同');
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
      CastRecipeStore.udnKeyOf(target()): noneRecipe.toJson(),
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

  group('M3 双层键查找', () {
    test('udn 精确命中优先于 model 共享命中', () {
      final store = CastRecipeStore();
      final t1 = target();
      const udnRecipe = CastRecipe(
          didl: DidlVariant.compatEscaped,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare);
      const modelRecipe = CastRecipe(didl: DidlVariant.full, stopBeforeSet: true);
      // 两层各放不同配方（模拟「同型号其他设备的共享配方」与本机精确配方并存）。
      store.replaceAll(<String, dynamic>{
        'udn:uuid:test-1': udnRecipe.toJson(),
        'model:qqlivetvrender|tencent:${castSinkHash(sinkMp4)}':
            modelRecipe.toJson(),
      });

      // udn 层优先命中。
      expect(store.lookup(t1, sink: sinkMp4)!.didl, DidlVariant.compatEscaped);
      // 链首 = udn 配方，第 2 位 = model 共享配方（语义不同不去重）。
      final chain = store.fallbackChain(t1, sink: sinkMp4);
      expect(chain[0].didl, DidlVariant.compatEscaped);
      expect(chain[0].protocolInfoTemplate, DidlProtocolInfoTemplate.bare);
      expect(chain[1].didl, DidlVariant.full);
      expect(chain[1].stopBeforeSet, isTrue);
    });

    test('model 共享层：同型号同 Sink 免扫命中，不同 Sink（固件不同）不命中',
        () async {
      final store = CastRecipeStore();
      final t1 = target();
      const hit = CastRecipe(
          didl: DidlVariant.compact,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare);
      await store.remember(t1, hit, sink: sinkMp4);

      // 同型号另一台（不同 UDN）+ 相同 Sink → model 层命中。
      final t2 = target(udn: 'uuid:test-2', name: '卧室极光TV');
      expect(store.lookup(t2, sink: sinkMp4)?.didl, DidlVariant.compact);
      final chain = store.fallbackChain(t2, sink: sinkMp4);
      expect(chain.first.didl, DidlVariant.compact);
      expect(chain.first.protocolInfoTemplate, DidlProtocolInfoTemplate.bare);

      // 同型号但 Sink 宣告不同（固件升级）→ 不命中，回全梯度。
      const sinkTts = <String>['http-get:*:video/vnd.dlna.mpeg-tts:*'];
      expect(store.lookup(t2, sink: sinkTts), isNull);
      expect(store.fallbackChain(t2, sink: sinkTts).first.didl,
          DidlVariant.full);
    });

    test('remember 双写两层；forget 清空 udn 层与该型号全部共享变体', () async {
      final store = CastRecipeStore();
      final t1 = target();
      await store.remember(t1, const CastRecipe(didl: DidlVariant.compact),
          sink: sinkMp4);
      // 两个键都存在（udn + model:sinkHash）。
      expect(
        store.toJson().keys,
        containsAll(<String>[
          'udn:uuid:test-1',
          'model:qqlivetvrender|tencent:${castSinkHash(sinkMp4)}',
        ]),
      );
      await store.forget(t1);
      expect(store.toJson(), isEmpty);
    });
  });

  group('M3 配方链与画像预设', () {
    test('链顺序：udn → model(+sinkHash) → 画像预设 → 梯度（语义去重）', () async {
      final store = CastRecipeStore();
      final t1 = target();
      await store.remember(t1, const CastRecipe(didl: DidlVariant.compact),
          sink: sinkMp4);
      final t2 = target(udn: 'uuid:test-2', name: '卧室极光TV');
      final profile = const CastDeviceProfile(
        udn: 'uuid:test-2',
        profileId: kProfilePnRequired,
      );
      final chain = store.fallbackChain(t2, sink: sinkMp4, profile: profile);

      // 第 1 位：model 共享命中（t2 无 udn 配方）。
      expect(chain[0].didl, DidlVariant.compact);
      // 第 2 位：pnRequired 画像预设（full + withPn）。
      expect(chain[1].didl, DidlVariant.full);
      expect(chain[1].protocolInfoTemplate, DidlProtocolInfoTemplate.withPn);
      // 预设与梯度 withPn 项语义相同 → 去重；model 命中（compact+standard）
      // 也去重梯度里的 compact+standard → 总长 = 2 + 梯度去重后 5 项。
      expect(chain.length, 7);
      expect(
        chain.where((r) =>
            r.protocolInfoTemplate == DidlProtocolInfoTemplate.withPn).length,
        1,
      );
      // udn 命中优先于 model：t1 自己的链以 udn 配方开头。
      final chain1 = store.fallbackChain(t1, sink: sinkMp4, profile: profile);
      expect(chain1[0].didl, DidlVariant.compact);
    });

    test('profilePreset 四态映射', () {
      // generic = 梯度首项（现状默认 full + standard）。
      expect(profilePreset(kProfileGeneric), CastRecipeStore.gradient[0]);
      // strictTitle：v2 恒含 title，预设与现状默认一致（记录历史）。
      expect(profilePreset(kProfileStrictTitle)!.didl, DidlVariant.full);
      expect(
          profilePreset(kProfileStrictTitle)!.protocolInfoTemplate,
          DidlProtocolInfoTemplate.standard);
      // hlsByUrl：URL 回退裸形态。
      expect(profilePreset(kProfileHlsByUrl)!.urlSuffixMode,
          CastUrlSuffixMode.bare);
      // pnRequired：full + withPn。
      expect(profilePreset(kProfilePnRequired)!.didl, DidlVariant.full);
      expect(profilePreset(kProfilePnRequired)!.protocolInfoTemplate,
          DidlProtocolInfoTemplate.withPn);
      // 未知 id：无预设。
      expect(profilePreset('bogus'), isNull);
      expect(profilePreset(null), isNull);
    });
  });

  group('M3 aquan_cast.json v4 兼容', () {
    Future<Directory> tempDir(String prefix) async {
      final dir = await Directory.systemTemp.createTemp(prefix);
      addTearDown(() => dir.delete(recursive: true));
      return dir;
    }

    File castFile(Directory dir) =>
        File('${dir.path}${Platform.pathSeparator}aquan_cast.json');

    test('v3 文件读入：旧配方视为空表并升 v4 回写（lastDevice/pinned 保留）',
        () async {
      final dir = await tempDir('cast_store_v3');
      castFile(dir).writeAsStringSync(
        '{"version":3,'
        '"lastDevice":{"udn":"u1","name":"旧电视","model":"X",'
        '"control_url":"http://192.168.1.9/ctrl",'
        '"location":"http://192.168.1.9/desc.xml"},'
        '"pinned":[{"udn":"u2","name":"钉选电视","model":"Y",'
        '"control_url":"http://192.168.1.10/ctrl",'
        '"location":"http://192.168.1.10/desc.xml"}],'
        '"recipes":{"x|y|z":{"didl":"none","quotedSoapAction":false}}}',
      );
      final store = CastStore(testDirectory: dir);
      await store.loadFromDisk();

      // 旧三段式键按设计视为空表（新查找语义不同，且旧版配方从未接线落盘）。
      expect(store.recipes.toJson(), isEmpty);
      expect(store.profiles.toJson(), isEmpty);
      // 设备记忆原样保留。
      expect(store.lastDevice?.id, 'u1');
      expect(store.lastDevice?.name, '旧电视');
      expect(store.pinned.length, 1);
      expect(store.pinned.first.id, 'u2');

      // 升 v4 回写。
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(json['version'], 4);
      expect(json['recipes'], isEmpty);
      expect(json['profiles'], isEmpty);
      expect((json['pinned'] as List).length, 1);
    });

    test('v1 文件（无 recipes 字段）读入升 v4', () async {
      final dir = await tempDir('cast_store_v1_m3');
      castFile(dir).writeAsStringSync(
        '{"version":1,"pinned":[]}',
      );
      final store = CastStore(testDirectory: dir);
      await store.loadFromDisk();
      expect(store.recipes.toJson(), isEmpty);
      final json =
          jsonDecode(castFile(dir).readAsStringSync()) as Map<String, dynamic>;
      expect(json['version'], 4);
    });

    test('v4 往返：remember 落盘 → 新 store（模拟重启）读回命中', () async {
      final dir = await tempDir('cast_store_v4_roundtrip');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      const hit = CastRecipe(
          didl: DidlVariant.compact,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare);
      await store.recipes.remember(target(), hit, sink: sinkMp4);
      await store.profiles.remember(const CastDeviceProfile(
        udn: 'uuid:test-1',
        profileId: kProfileHlsByUrl,
        sinkProtocols: sinkMp4,
      ));

      // 模拟重启：新 store 实例从磁盘读回。
      final store2 = CastStore(testDirectory: dir);
      await store2.ensureLoaded();
      final back = store2.recipes.lookup(target(), sink: sinkMp4);
      expect(back?.didl, DidlVariant.compact);
      expect(back?.protocolInfoTemplate, DidlProtocolInfoTemplate.bare);
      final profile = store2.profiles.lookup('uuid:test-1');
      expect(profile?.profileId, kProfileHlsByUrl);
    });

    test('备份导入：v3 旧键忽略；v4 键吸收且不覆盖本机配方', () async {
      final dir = await tempDir('cast_store_v4_import');
      final store = CastStore(testDirectory: dir);
      await store.ensureLoaded();
      const mine = CastRecipe(didl: DidlVariant.compatEscaped);
      await store.recipes.remember(target(), mine, sink: const <String>[]);

      await store.importData(<String, dynamic>{
        'recipes': <String, dynamic>{
          'x|y|z': <String, dynamic>{'didl': 'full'},
          'udn:uuid:other': <String, dynamic>{
            'didl': 'compact',
            'protocolInfoTemplate': 'bare',
          },
        },
        'profiles': <String, dynamic>{
          'udn:uuid:other': <String, dynamic>{
            'udn': 'uuid:other',
            'profileId': 'pnRequired',
          },
          'bogus-key': <String, dynamic>{'udn': 'x'},
        },
      });

      final keys = store.recipes.toJson().keys.toSet();
      expect(keys, contains('udn:uuid:other'));
      expect(keys, isNot(contains('x|y|z')), reason: '旧三段式键被忽略');
      expect(keys, contains('udn:uuid:test-1'));
      // 本机已验证配方不被覆盖。
      expect(store.recipes.lookup(target())!.didl, DidlVariant.compatEscaped);
      // 画像只补没有的键；非法前缀键忽略。
      expect(store.profiles.lookup('uuid:other')?.profileId, kProfilePnRequired);
    });
  });

  group('setTranscodeMode（M5-0 / AC-22 面板开关写配方）', () {
    test('只更新三态：其余字段与 successCount 保留', () async {
      final store = CastRecipeStore();
      final d = target();
      const existing = CastRecipe(didl: DidlVariant.compact);
      await store.remember(d, existing, sink: const <String>[]);
      // remember 自带一次成功计数（0 → 1）；setTranscodeMode 不应再加。
      final before = store.lookup(d)!;
      expect(before.successCount, 1);

      await store.setTranscodeMode(d, CastTranscodeMode.always);
      final r = store.lookup(d)!;
      expect(r.transcodeMode, CastTranscodeMode.always);
      expect(r.didl, DidlVariant.compact, reason: '其余字段保留');
      expect(r.successCount, 1, reason: '不当作一次成功（不再 +1）');
    });

    test('无既有配方时写入仅含三态的配方；三态三档往返', () async {
      final store = CastRecipeStore();
      final d = target();
      await store.setTranscodeMode(d, CastTranscodeMode.never);
      expect(store.lookup(d)!.transcodeMode, CastTranscodeMode.never);
      expect(store.lookup(d)!.successCount, 0);
      expect(store.lookup(d)!.didl, DidlVariant.full, reason: '其余字段为默认');

      for (final mode in CastTranscodeMode.values) {
        await store.setTranscodeMode(d, mode);
        expect(store.lookup(d)!.transcodeMode, mode);
      }
    });

    test('写盘回调触发（CastStore 持久化挂点）', () async {
      var persisted = 0;
      final store = CastRecipeStore(onChanged: () async => persisted++);
      await store.setTranscodeMode(target(), CastTranscodeMode.always);
      expect(persisted, 1);
    });
  });
}
