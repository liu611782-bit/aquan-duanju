
import 'package:aquan_duanju/core/castd/receiver_player_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mapReceiverTransportState（引擎实况 → UPnP TransportState）', () {
    // 缺省入参：有媒体、未 Stop、已加载未播、不缓冲、暂停中、未播完。
    String map({
      bool hasMedia = true,
      bool stopRequested = false,
      bool loadedNotPlayed = false,
      bool buffering = false,
      bool playing = false,
      bool completed = false,
    }) =>
        mapReceiverTransportState(
          hasMedia: hasMedia,
          stopRequested: stopRequested,
          loadedNotPlayed: loadedNotPlayed,
          buffering: buffering,
          playing: playing,
          completed: completed,
        );

    test('无媒体（从未 load）→ NO_MEDIA_PRESENT', () {
      expect(map(hasMedia: false), kTransportNoMedia);
      // 即使引擎残留 playing=true（mpv 复用实例），无媒体口径优先。
      expect(map(hasMedia: false, playing: true), kTransportNoMedia);
    });

    test('Stop 动作后（引擎实况不可信）恒 STOPPED，直到下次 load/play', () {
      expect(map(stopRequested: true), kTransportStopped);
      expect(map(stopRequested: true, playing: true), kTransportStopped);
      expect(map(stopRequested: true, buffering: true), kTransportStopped);
    });

    test('缓冲中 → TRANSITIONING（优先于 playing/paused）', () {
      expect(map(buffering: true), kTransportTransitioning);
      expect(map(buffering: true, playing: true), kTransportTransitioning);
    });

    test('SetAVTransportURI 后已加载未播 → STOPPED（已加载待播）', () {
      expect(map(loadedNotPlayed: true), kTransportStopped);
    });

    test('播放中 → PLAYING；自然播完 → STOPPED', () {
      expect(map(playing: true), kTransportPlaying);
      expect(map(completed: true), kTransportStopped);
      // completed 且 buffering（尾部缓冲抖动）：completed 语义优先于 paused，
      // 但 buffering 优先——先 TRANSITIONING 后 STOPPED，发端轮询自然收敛。
      expect(map(buffering: true, completed: true), kTransportTransitioning);
    });

    test('其余（暂停中）→ PAUSED_PLAYBACK', () {
      expect(map(), kTransportPaused);
    });
  });

  group('StubReceiverPlayer.statusStream（实况推送）', () {
    test('状态/进度/音量/静音变化都会推一帧实况', () async {
      final stub = StubReceiverPlayer();
      final events = <ReceiverPlayerStatus>[];
      final sub = stub.statusStream.listen(events.add);
      await Future<void>.delayed(Duration.zero);

      stub.state = kTransportPlaying;
      stub.position = const Duration(seconds: 3);
      await stub.setVolume(42);
      await stub.setMuted(true);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(events.map((e) => e.transportState), contains(kTransportPlaying));
      expect(
        events.any((e) => e.position == const Duration(seconds: 3)),
        isTrue,
      );
      expect(events.last.volume, 42);
      expect(events.last.muted, isTrue);
    });

    test('load：TRANSITIONING → STOPPED（已加载待播）；load 后 position 清零',
        () async {
      final stub = StubReceiverPlayer();
      final states = <String>[];
      final sub = stub.statusStream.listen((e) => states.add(e.transportState));
      await Future<void>.delayed(Duration.zero);

      stub.position = const Duration(minutes: 3);
      await stub.load(Uri.parse('http://192.168.1.9:18280/p/tok/v.mp4'));
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(states, contains(kTransportTransitioning));
      expect(states.last, kTransportStopped);
      expect(stub.status().position, Duration.zero);
    });
  });
}
