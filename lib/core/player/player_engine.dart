// ============================================================
// 文件：lib/core/player/player_engine.dart
// 说明：仅替换 MpvPlayerEngine.open 方法（减轻播放卡顿）
// ============================================================

  @override
  Future<void> open(Media media, {bool play = true}) async {
    await _player.open(media, play: play);
    // open 成功才算「可 seek」：之前的目标一律不补发（位置已由 open 决定）。
    _seekGate.open();

    // ---- 播放卡顿优化：硬解 + 预读缓冲（失败静默，不影响起播）----
    try {
      // Android 优先硬解；桌面/其它平台 auto-safe 同样可降 CPU
      await setProperty('hwdec', 'auto-safe');
      await setProperty('cache', 'yes');
      // 预读约 20s / 上限约 150MB，弱网少卡
      await setProperty('demuxer-readahead-secs', '20');
      await setProperty('demuxer-max-bytes', '150M');
      await setProperty('demuxer-max-back-bytes', '50M');
      // 解码跟不上时丢帧保流畅（可按设置再做成开关）
      await setProperty('framedrop', 'vo');
    } catch (_) {
      // 部分属性在非 NativePlayer / 旧 libmpv 上可能不可用
    }
  }
@override
  Future<void> open(Media media, {bool play = true}) async {
    await _player.open(media, play: play);
    _seekGate.open();

    try {
      await setProperty('hwdec', 'auto-safe');
      await setProperty('cache', 'yes');
      await setProperty('demuxer-readahead-secs', '20');
      await setProperty('demuxer-max-bytes', '150M');
      await setProperty('demuxer-max-back-bytes', '50M');
      await setProperty('framedrop', 'vo');
    } catch (_) {}
  }
