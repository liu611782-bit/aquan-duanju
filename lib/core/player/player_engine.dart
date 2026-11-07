import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../error_log.dart';
import 'seek_gate.dart';

/// 播放引擎抽象。
///
/// 播放器页只依赖这一层：创建 / 销毁、打开媒体、播放控制、属性读写都在
/// 引擎内完成。当前实现是 media_kit（libmpv），未来替换内核或做假引擎
/// 单测时不需要改播放器页。
abstract class PlayerEngine {
  PlayerStream get stream;
  PlayerState get state;
  VideoController get videoController;

  Future<void> initialize();
  Future<void> open(Media media, {bool play = true});
  Future<void> play();
  Future<void> pause();
  Future<void> playOrPause();
  Future<void> stop();

  /// 跳转播放位置。
  ///
  /// media_kit 实现里经由 [SeekGate]：未打开媒体时忽略、密集连发合并成
  /// 最新目标、异常不外抛（只进 ErrorLog breadcrumb——安卓拖进度条崩溃
  /// 的证据先行防御）。详见 [SeekGate]。
  Future<void> seek(Duration position);

  Future<void> setVolume(double volume);
  Future<void> setRate(double rate);
  Future<void> setAudioTrack(AudioTrack track);
  Future<void> setSubtitleTrack(SubtitleTrack track);

  /// 写入 mpv 属性（非原生引擎 / 属性不可用时静默忽略）。
  Future<void> setProperty(String name, String value);

  /// 读取 mpv 属性；不可用时返回 null。
  Future<String?> getProperty(String name);

  /// 截取当前画面；不可用时返回 null。
  Future<Uint8List?> screenshot({
    String format = 'image/png',
    bool includeLibassSubtitles = true,
  });

  Future<void> dispose();
}

/// media_kit（libmpv）实现。
class MpvPlayerEngine implements PlayerEngine {
  MpvPlayerEngine({PlayerConfiguration? configuration})
      : _player = Player(
          configuration: configuration ??
              const PlayerConfiguration(logLevel: MPVLogLevel.warn),
        ) {
    videoController = VideoController(_player);
    _seekGate = SeekGate(
      run: _player.seek,
      onEvent: _onSeekEvent,
    );
  }

  final Player _player;

  @override
  late final VideoController videoController;

  /// seek 防御闸门（安卓拖进度条崩溃的 Dart 层防御 + breadcrumb）。
  late final SeekGate _seekGate;

  /// breadcrumb 节流：发起/完成 800ms 内只记一条（拖动几十连发不刷屏），
  /// 异常/忽略不节流。
  void _onSeekEvent(SeekGateEvent event, Duration position, Object? error,
      StackTrace? stack) {
    final ms = position.inMilliseconds;
    switch (event) {
      case SeekGateEvent.dispatch:
        ErrorLog.instance.record('播放', 'seek 发起 → ${ms}ms');
      case SeekGateEvent.applied:
        ErrorLog.instance.record('播放', 'seek 完成 → ${ms}ms');
      case SeekGateEvent.ignored:
        // 未就绪被忽略：通常是换源/关闭后残存的进度条事件。
        ErrorLog.instance.record('播放', 'seek 忽略（播放器未就绪）→ ${ms}ms');
      case SeekGateEvent.error:
        ErrorLog.instance.record('播放', 'seek 失败（$ms ms）：$error', stack);
    }
  }

  @override
  PlayerStream get stream => _player.stream;

  @override
  PlayerState get state => _player.state;

  @override
  Future<void> initialize() async {
    MediaKit.ensureInitialized();
  }

  @override
  Future<void> open(Media media, {bool play = true}) async {
    await _player.open(media, play: play);
    // open 成功才算「可 seek」：之前的目标一律不补发（位置已由 open 决定）。
    _seekGate.open();
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> playOrPause() => _player.playOrPause();

  @override
  Future<void> stop() async {
    _seekGate.close();
    await _player.stop();
  }

  @override
  Future<void> seek(Duration position) => _seekGate.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Future<void> setAudioTrack(AudioTrack track) =>
      _player.setAudioTrack(track);

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) =>
      _player.setSubtitleTrack(track);

  @override
  Future<void> setProperty(String name, String value) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(name, value);
    }
  }

  @override
  Future<String?> getProperty(String name) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      try {
        return await platform.getProperty(name);
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Future<Uint8List?> screenshot({
    String format = 'image/png',
    bool includeLibassSubtitles = true,
  }) =>
      _player.screenshot(
        format: format,
        includeLibassSubtitles: includeLibassSubtitles,
      );

  @override
  Future<void> dispose() async {
    _seekGate.close();
    await _player.dispose();
  }
}
