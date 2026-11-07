import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_media_fallback.dart';

void main() {
  test('中继成功：返回中继 URL + viaRelay=true（mime 提示跟随中继）', () async {
    final result = await castMediaViaRelayOrDirect(
      title: '剧 · 第1集',
      directUrl: 'http://up/video.m4s',
      startRelay: () async => 'http://192.168.1.5:29170/cast/tok/index.m3u8',
    );
    expect(result, isNotNull);
    final (media, viaRelay) = result!;
    expect(viaRelay, isTrue);
    expect(media.url, 'http://192.168.1.5:29170/cast/tok/index.m3u8');
    expect(media.mimeHint, 'application/vnd.apple.mpegurl');
  });

  test('AC-21：中继必败 → 仍返回可用 CastMedia（直投原始 URL）', () async {
    final errors = <Object>[];
    final result = await castMediaViaRelayOrDirect(
      title: '剧 · 第1集',
      directUrl: 'http://up/video.m4s',
      startRelay: () async => throw Exception('ffmpeg 起不来'),
      onRelayError: (e, st) => errors.add(e),
    );
    expect(result, isNotNull, reason: '中继失败不能让「该集没有可投的流」终结投屏');
    final (media, viaRelay) = result!;
    expect(viaRelay, isFalse);
    expect(media.url, 'http://up/video.m4s');
    expect(media.mimeHint, isEmpty, reason: '直投 URL 不携带中继的 HLS 提示');
    expect(errors, hasLength(1), reason: '原始异常经 onRelayError 出口进 ErrorLog');
  });

  test('中继失败且无直投地址 → null（彻底没有可投媒体）', () async {
    final result = await castMediaViaRelayOrDirect(
      title: '剧 · 第1集',
      directUrl: '',
      startRelay: () async => throw Exception('fail'),
    );
    expect(result, isNull);
  });

  test('直投回退保留标题/分集/时长元数据', () async {
    final result = await castMediaViaRelayOrDirect(
      title: '剧 · 第3集',
      directUrl: 'http://up/video.m4s',
      startRelay: () async => throw Exception('fail'),
      episodeIndex: 3,
      episodeCount: 12,
      position: const Duration(minutes: 2),
      duration: const Duration(minutes: 20),
    );
    final (media, _) = result!;
    expect(media.title, '剧 · 第3集');
    expect(media.episodeIndex, 3);
    expect(media.episodeCount, 12);
    expect(media.position, const Duration(minutes: 2));
    expect(media.duration, const Duration(minutes: 20));
  });
}
