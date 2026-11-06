import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/player/playback_failure_gate.dart';

void main() {
  bool gate({
    bool confirmed = false,
    bool playing = false,
    Duration position = Duration.zero,
    bool buffering = false,
  }) =>
      hasVisiblePlayback(
        playingConfirmed: confirmed,
        playing: playing,
        position: position,
        buffering: buffering,
      );

  test('已确认出画 / playing / 有进度 / 缓冲中，任一信号都算可见播放', () {
    expect(gate(confirmed: true), isTrue);
    expect(gate(playing: true), isTrue);
    expect(gate(position: const Duration(milliseconds: 1)), isTrue);
    expect(gate(buffering: true), isTrue);
  });

  test('四个信号全无才是「真的打不开」', () {
    expect(gate(), isFalse);
  });

  test('开播阶段的非致命错误需经过宽限期', () {
    expect(playbackErrorGrace, const Duration(seconds: 6));
    expect(playbackErrorGrace.inSeconds, greaterThan(0));
  });
}
