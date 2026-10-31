import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'dart:async';

import '../core/player/player_engine.dart';
import '../core/player/subtitle_delay.dart';
import '../core/player/track_preference.dart';

/// 音轨 / 字幕轨选择面板。
///
/// 支持内嵌音轨、内嵌字幕、关闭字幕，以及从本地加载外挂字幕
/// （SRT / ASS / SSA / VTT / SUB）。外挂字幕在下次打开媒体时自动卸载，
/// 与 media_kit 的语义一致。
///
/// 字幕同步：[initialSubtitleDelay]（秒）为当前时差；用户调整时面板实时
/// 写引擎 `sub-delay`，并回调 [onSubtitleDelayChanged]（毫秒）由调用方
/// 按剧持久化；不传回调则仅实时生效（向后兼容）。
Future<void> showPlayerTracksSheet(
    BuildContext context, PlayerEngine engine, {
  double initialSubtitleDelay = 0,
  Future<void> Function(double delayMs)? onSubtitleDelayChanged,
  Future<void> Function(int trackIndex, String trackKey)? onAudioTrackSelected,
  Future<void> Function(int trackIndex, String trackKey)?
      onSubtitleTrackSelected,
}) async {
  final tracks = engine.state.tracks;
  final audioTracks =
      tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
  final subtitleTracks = tracks.subtitle
      .where((t) => t.id != 'auto' && t.id != 'no')
      .toList();
  final currentAudio = engine.state.track.audio.id;
  final currentSubtitle = engine.state.track.subtitle.id;

  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      return SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const _SheetHeader('音轨'),
            if (audioTracks.isEmpty)
              const ListTile(title: Text('当前视频没有可选音轨'))
            else ...[
              ListTile(
                title: const Text('自动'),
                trailing:
                    currentAudio == 'auto' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setAudioTrack(AudioTrack.auto());
                  Navigator.pop(sheetContext);
                },
              ),
              for (final track in audioTracks)
                ListTile(
                  title: Text(_trackLabel(
                      track.title, track.language, track.id, '音轨')),
                  subtitle: (track.codec ?? '').isEmpty
                      ? null
                      : Text(track.codec!),
                  trailing: track.id == currentAudio
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    engine.setAudioTrack(track);
                    final idx = audioTracks.indexOf(track);
                    if (idx >= 0) {
                      unawaited(onAudioTrackSelected?.call(
                        idx,
                        TrackPreference.stableTrackKey(
                                language: track.language, title: track.title) ??
                            '',
                      ));
                    }
                    Navigator.pop(sheetContext);
                  },
                ),
            ],
            const Divider(height: 1),
            const _SheetHeader('字幕'),
            _SubtitleSyncSection(
              engine: engine,
              initialDelay:
                  SubtitleDelay.clamp(initialSubtitleDelay),
              onPersist: onSubtitleDelayChanged,
            ),
            if (subtitleTracks.isEmpty)
              const ListTile(title: Text('当前视频没有内嵌字幕'))
            else ...[
              ListTile(
                title: const Text('自动'),
                trailing:
                    currentSubtitle == 'auto' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setSubtitleTrack(SubtitleTrack.auto());
                  Navigator.pop(sheetContext);
                },
              ),
              for (final track in subtitleTracks)
                ListTile(
                  title: Text(_trackLabel(
                      track.title, track.language, track.id, '字幕')),
                  subtitle: (track.codec ?? '').isEmpty
                      ? null
                      : Text(track.codec!),
                  trailing: track.id == currentSubtitle
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () {
                    engine.setSubtitleTrack(track);
                    final idx = subtitleTracks.indexOf(track);
                    if (idx >= 0) {
                      unawaited(onSubtitleTrackSelected?.call(
                        idx,
                        TrackPreference.stableTrackKey(
                                language: track.language, title: track.title) ??
                            '',
                      ));
                    }
                    Navigator.pop(sheetContext);
                  },
                ),
              ListTile(
                title: const Text('关闭字幕'),
                trailing:
                    currentSubtitle == 'no' ? const Icon(Icons.check) : null,
                onTap: () {
                  engine.setSubtitleTrack(SubtitleTrack.no());
                  unawaited(onSubtitleTrackSelected?.call(
                      TrackPreference.subtitleOff, ''));
                  Navigator.pop(sheetContext);
                },
              ),
            ],
            ListTile(
              leading: const Icon(Icons.file_open_outlined),
              title: const Text('加载字幕文件…'),
              subtitle: const Text('支持 SRT / ASS / SSA / VTT / SUB'),
              onTap: () async {
                final file = await openFile(
                  acceptedTypeGroups: const [
                    XTypeGroup(
                      label: '字幕',
                      extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub'],
                    ),
                  ],
                );
                if (file == null) return;
                try {
                  await engine.setSubtitleTrack(
                    SubtitleTrack.uri(Uri.file(file.path).toString(),
                        title: file.name),
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                } catch (e) {
                  if (sheetContext.mounted) {
                    ScaffoldMessenger.of(sheetContext).showSnackBar(
                        SnackBar(content: Text('字幕加载失败：$e')));
                  }
                }
              },
            ),
          ],
        ),
      );
    },
  );
}

String _trackLabel(
    String? title, String? language, String id, String fallback) {
  final parts = <String>[];
  if (title != null && title.trim().isNotEmpty) parts.add(title.trim());
  if (language != null && language.trim().isNotEmpty) {
    parts.add(language.trim());
  }
  if (parts.isEmpty &&
      id.isNotEmpty &&
      id != 'auto' &&
      id != 'no') {
    parts.add('$fallback $id');
  }
  return parts.isEmpty ? fallback : parts.join(' · ');
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.outline,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 字幕同步段：±0.5s 步进实时写引擎，重置回 0；调整经 [onPersist] 落盘。
class _SubtitleSyncSection extends StatefulWidget {
  const _SubtitleSyncSection({
    required this.engine,
    required this.initialDelay,
    this.onPersist,
  });

  final PlayerEngine engine;
  final double initialDelay;
  final Future<void> Function(double delayMs)? onPersist;

  @override
  State<_SubtitleSyncSection> createState() => _SubtitleSyncSectionState();
}

class _SubtitleSyncSectionState extends State<_SubtitleSyncSection> {
  late double _delay = widget.initialDelay;

  Future<void> _set(double value) async {
    final v = SubtitleDelay.clamp(value);
    setState(() => _delay = v);
    try {
      await widget.engine.setProperty('sub-delay', '$v');
    } catch (_) {}
    final persist = widget.onPersist;
    if (persist != null) {
      try {
        await persist((v * 1000).roundToDouble());
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: const Icon(Icons.schedule_outlined),
      title: Text('字幕同步 · ${SubtitleDelay.label(_delay)}'),
      subtitle: const Text('字幕比声音慢就提前（−），快了就延后（+）'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '提前 0.5s',
            icon: const Icon(Icons.remove_circle_outline),
            onPressed: () => _set(SubtitleDelay.step(_delay, -1)),
          ),
          TextButton(
            onPressed: _delay == 0 ? null : () => _set(0),
            child: const Text('重置'),
          ),
          IconButton(
            tooltip: '延后 0.5s',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => _set(SubtitleDelay.step(_delay, 1)),
          ),
        ],
      ),
    );
  }
}
