import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_type.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_route.dart';

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
}
