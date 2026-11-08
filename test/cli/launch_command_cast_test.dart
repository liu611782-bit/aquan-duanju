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
    });
  });
}
