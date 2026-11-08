import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/cli/launch_command.dart';

void main() {
  group('LaunchCommand.parse · cast 命令', () {
    test('aquan-cli cast → kind=cast', () {
      final cmd = LaunchCommand.parse(['--cast']);
      expect(cmd.kind, 'cast');
      expect(cmd.isEmpty, isFalse);
    });

    test('aquan-cli cast stop → kind=cast_stop', () {
      final cmd = LaunchCommand.parse(['--cast-stop']);
      expect(cmd.kind, 'cast_stop');
    });

    test('cast 不在播放控制类词表（不走 PlayerBus）', () {
      expect(LaunchCommand.isPlayerKind('cast'), isFalse);
      expect(LaunchCommand.isPlayerKind('cast_stop'), isFalse);
      expect(LaunchCommand.isPlayerKind('cast_series'), isFalse);
    });

    test('aquan-cli cast <ID> --episode N → kind=cast_series', () {
      final cmd = LaunchCommand.parse(['--cast-series', '7701350814786259993', '--episode', '3']);
      expect(cmd.kind, 'cast_series');
      expect(cmd.value, '7701350814786259993');
      expect(cmd.episode, 3);
    });

    test('cast_series 缺 ID → none', () {
      expect(LaunchCommand.parse(['--cast-series']).isEmpty, isTrue);
    });
  });
}
