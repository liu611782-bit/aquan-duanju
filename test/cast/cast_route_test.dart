import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_type.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_route.dart';
import 'package:aquan_duanju/core/cast/didl.dart';

void main() {
  const mp4 = CastMediaType(mime: 'video/mp4', fileName: 'video.mp4', kind: CastMediaKind.video);
  const mkv = CastMediaType(mime: 'video/x-matroska', fileName: 'video.mkv', kind: CastMediaKind.video);
  const flv = CastMediaType(mime: 'video/x-flv', fileName: 'video.flv', kind: CastMediaKind.video);
  const webm = CastMediaType(mime: 'video/webm', fileName: 'video.webm', kind: CastMediaKind.video);
  const ts = CastMediaType(mime: 'video/mp2t', fileName: 'stream.ts', kind: CastMediaKind.video);
  const hls = CastMediaType(
      mime: 'application/vnd.apple.mpegurl', fileName: 'index.m3u8', kind: CastMediaKind.video);
  const sinkHls = <String>['http-get:*:application/vnd.apple.mpegurl:*'];
  const sinkMp4Only = <String>['http-get:*:video/mp4:*'];

  group('auto 选路判定表（design §4.10）', () {
    test('HLS + Sink 含 HLS mime → 直投', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: hls, sinkMimes: sinkHls),
        CastRoute.direct,
      );
    });

    test('HLS + Sink 不含 HLS mime → 中继（产物已是 .m3u8）', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: hls, sinkMimes: sinkMp4Only),
        CastRoute.relay,
      );
    });

    test('HLS + Sink 为空（预检失败）→ 直投（能力未知不强制转码，现状不回归）', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: hls, sinkMimes: const <String>[]),
        CastRoute.direct,
      );
    });

    test('HLS 别名拼写：Sink 宣告 x-mpegurl 也算支持 HLS', () {
      expect(
        resolveCastRoute(
          mode: CastTranscodeMode.auto,
          mediaType: hls,
          sinkMimes: const <String>['http-get:*:application/x-mpegurl:*'],
        ),
        CastRoute.direct,
      );
    });

    test('MKV / FLV / WEBM → 中继（国产电视多不支持；Sink 无关）', () {
      for (final type in [mkv, flv, webm]) {
        expect(
          resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: type, sinkMimes: sinkHls),
          CastRoute.relay,
          reason: type.mime,
        );
        expect(
          resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: type, sinkMimes: const <String>[]),
          CastRoute.relay,
          reason: '${type.mime}（无 Sink）',
        );
      }
    });

    test('HEVC / AV1 编码提示 → 中继转 H.264', () {
      for (final codec in const ['hevc', 'h265', 'h.265', 'HEVC', 'av1', 'AV1']) {
        expect(
          resolveCastRoute(
            mode: CastTranscodeMode.auto,
            mediaType: mp4,
            codecHint: codec,
          ),
          CastRoute.relay,
          reason: codec,
        );
      }
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: mp4, codecHint: 'h264'),
        CastRoute.direct,
        reason: 'H.264 不命中',
      );
    });

    test('MP4 / TS / 未知类型 → 直投（Sink 无关，维持现状）', () {
      for (final type in [mp4, ts, CastMediaType.unknown]) {
        expect(
          resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: type, sinkMimes: sinkMp4Only),
          CastRoute.direct,
          reason: type.mime,
        );
      }
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, sinkMimes: sinkMp4Only),
        CastRoute.direct,
        reason: '无媒体类型（本地文件等）不选路转码',
      );
    });

    test('防盗链头（needsProxy）在 auto 下维持代理现状', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: mp4, needsProxy: true),
        CastRoute.proxy,
      );
      expect(
        resolveCastRoute(
            mode: CastTranscodeMode.auto, mediaType: hls, sinkMimes: sinkHls, needsProxy: true),
        CastRoute.proxy,
      );
    });
  });

  group('兼容模式三态覆盖（AC-22 / G5）', () {
    test('always：全部走中继（MP4 也转）', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.always, mediaType: mp4),
        CastRoute.relay,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.always, mediaType: hls, sinkMimes: sinkHls),
        CastRoute.relay,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.always, mediaType: mp4, needsProxy: true),
        CastRoute.relay,
      );
    });

    test('never：全部按现状直投/代理（MKV、HLS-无-Sink 也不转）', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.never, mediaType: mkv),
        CastRoute.direct,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.never, mediaType: hls, sinkMimes: sinkMp4Only),
        CastRoute.direct,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.never, mediaType: mp4, needsProxy: true),
        CastRoute.proxy,
      );
    });

    test('加密分集 → 强制中继（现状不变；never 也不改变这一行）', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: mp4, encrypted: true),
        CastRoute.relay,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.always, mediaType: mp4, encrypted: true),
        CastRoute.relay,
      );
    });

    test('viaRelay（URL 已是本机中继产物）→ 恒直投，不再套一层转码', () {
      expect(
        resolveCastRoute(mode: CastTranscodeMode.always, mediaType: hls, viaRelay: true),
        CastRoute.direct,
        reason: 'always 也不能对中继产物二次转码',
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: mkv, viaRelay: true),
        CastRoute.direct,
      );
    });
  });

  group('sinkHasHls（Sink 判定口径）', () {
    test('两条 HLS 拼写任一命中；残缺条目与 */* 不算证据', () {
      expect(sinkHasHls(const <String>['http-get:*:application/vnd.apple.mpegurl:*']), isTrue);
      expect(sinkHasHls(const <String>['http-get:*:application/x-mpegurl:*']), isTrue);
      expect(sinkHasHls(const <String>['http-get:*:*:*', 'http-get']), isFalse);
      expect(sinkHasHls(const <String>[]), isFalse);
    });
  });

  group('编码提示合并与嗅探→relay（R1 / AC-2）', () {
    test('mergeCodecHint：红果显式优先于嗅探（回归断言）', () {
      // 显式提示恒优先——哪怕显式是 H.264、嗅探说 HEVC（显式就是权威）。
      expect(mergeCodecHint('h264', 'hevc'), 'h264');
      expect(mergeCodecHint('hevc', 'av1'), 'hevc');
      expect(mergeCodecHint(' HEVC ', 'av1'), 'HEVC', reason: '显式原样透传，大小写归一在 _isHighCodec');
      // 显式为空 → 用嗅探。
      expect(mergeCodecHint('', 'av1'), 'av1');
      expect(mergeCodecHint('  ', 'hevc'), 'hevc');
      // 都缺 → 空串（不转码）。
      expect(mergeCodecHint('', null), '');
    });

    test('嗅探 codecHint → auto 中继（CMS 无显式提示的源）', () {
      const sniffedHevc = CastMediaType(
          mime: 'video/mp4', fileName: 'video.mp4', kind: CastMediaKind.video, codecHint: 'hevc');
      const sniffedAv1 = CastMediaType(
          mime: 'video/mp4', fileName: 'video.mp4', kind: CastMediaKind.video, codecHint: 'av1');
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: sniffedHevc),
        CastRoute.relay,
      );
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: sniffedAv1, sinkMimes: sinkHls),
        CastRoute.relay,
        reason: '嗅探 HEVC/AV1 无视 Sink 宣告，统一转 H.264',
      );
      // 无嗅探无显式（现状回归）：MP4 直投。
      const plain = CastMediaType(mime: 'video/mp4', fileName: 'video.mp4', kind: CastMediaKind.video);
      expect(
        resolveCastRoute(mode: CastTranscodeMode.auto, mediaType: plain),
        CastRoute.direct,
      );
    });

    test('显式提示与嗅探提示合并后进选路（controller 口径演练）', () {
      const sniffed = CastMediaType(
          mime: 'video/mp4', fileName: 'video.mp4', kind: CastMediaKind.video, codecHint: 'hevc');
      // 红果说 h264 → 合并结果 h264 → 不转码（显式优先，现状不回归）。
      expect(
        resolveCastRoute(
            mode: CastTranscodeMode.auto,
            mediaType: sniffed,
            codecHint: mergeCodecHint('h264', sniffed.codecHint)),
        CastRoute.direct,
      );
      // 红果无提示 → 合并结果 hevc → 中继。
      expect(
        resolveCastRoute(
            mode: CastTranscodeMode.auto,
            mediaType: sniffed,
            codecHint: mergeCodecHint('', sniffed.codecHint)),
        CastRoute.relay,
      );
    });
  });

  group('中继输出档位 relayFormatFor（R2 / AC-4）', () {
    test('Sink 含 HLS mime → hls（现状）', () {
      expect(relayFormatFor(sinkHls), 'hls');
      expect(relayFormatFor(const <String>['http-get:*:application/x-mpegurl:*']), 'hls');
      // HLS 与 TS 同告 → HLS 优先（hls 产物是最普遍的兼容形态）。
      expect(
        relayFormatFor(const <String>[
          'http-get:*:video/mp2t:*',
          'http-get:*:application/x-mpegurl:*',
        ]),
        'hls',
      );
    });

    test('Sink 无 HLS 有 TS 容器拼写 → ts（WMP 族）', () {
      expect(relayFormatFor(const <String>['http-get:*:video/mp2t:*']), 'ts');
      expect(
        relayFormatFor(const <String>['http-get:*:video/vnd.dlna.mpeg-tts:*']),
        'ts',
        reason: '果果投屏/投屏电视Q3 的 TS 拼写',
      );
      expect(
        relayFormatFor(const <String>['http-get:*:video/mp4:*', 'http-get:*:video/mp2t:*']),
        'ts',
      );
    });

    test('Sink 缺失/未知 → hls（证据缺失回落现状，不回归）', () {
      expect(relayFormatFor(const <String>[]), 'hls');
      expect(relayFormatFor(const <String>['http-get:*:video/mp4:*']), 'hls');
      expect(relayFormatFor(const <String>['http-get:*:*/*:*', 'http-get']), 'hls',
          reason: '通配与残缺条目不算证据');
    });
  });

  group('中继 TS 档配方链升级 upgradeChainForTsProduct（R2 DIDL 对齐）', () {
    test('默认 standard 升级 sinkEntry；其余模板保持原样', () {
      const chain = <CastRecipe>[
        CastRecipe(), // full + standard（梯度首项 = 现状默认形态）
        CastRecipe(
            didl: DidlVariant.compact,
            protocolInfoTemplate: DidlProtocolInfoTemplate.bare),
        CastRecipe(
            didl: DidlVariant.full,
            protocolInfoTemplate: DidlProtocolInfoTemplate.withPn),
      ];
      final upgraded = upgradeChainForTsProduct(chain);
      expect(upgraded[0].protocolInfoTemplate, DidlProtocolInfoTemplate.sinkEntry,
          reason: 'standard → sinkEntry（Sink 无 TS 条目时模板自身回落 standard）');
      expect(upgraded[0].didl, DidlVariant.full, reason: '其余字段不动');
      expect(upgraded[1].protocolInfoTemplate, DidlProtocolInfoTemplate.bare,
          reason: '显式旋钮不覆盖');
      expect(upgraded[2].protocolInfoTemplate, DidlProtocolInfoTemplate.withPn);
      expect(upgraded.length, chain.length);
    });

    test('sinkEntry 模板自身回落语义：Sink 无同容器条目 → 第 4 段用标准 flags', () {
      // didl.dart 现有语义演练：升级到 sinkEntry 后 Sink 缺条目不炸。
      final fourth = sinkEntryFourthSegment(
        const <String>['http-get:*:video/mp4:*'],
        'video/mp2t',
      );
      expect(fourth, isNull, reason: '无同容器条目回落 standard（buildDidl 处理）');
      final hit = sinkEntryFourthSegment(
        const <String>['http-get:*:video/vnd.dlna.mpeg-tts:DLNA.ORG_PN=MPEG_TS_HD_NA;*'],
        'video/mp2t',
      );
      expect(hit, 'DLNA.ORG_PN=MPEG_TS_HD_NA;*', reason: '别名组对上后逐字照抄');
    });
  });
}
