import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/relay_dirs.dart';

void main() {
  tearDown(() {
    // 级联不能作用于 Type 上的 static setter，逐个置空（注入即重置 memoize）。
    RelayDirs.debugWorkDirResolver = null;
    RelayDirs.debugCaFileResolver = null;
  });

  group('RelayDirs（11-08-android-cast-device-fixes）', () {
    test('workDir：注入 resolver 生效', () async {
      RelayDirs.debugWorkDirResolver = () async => '/fake/tmp';
      expect(await RelayDirs.workDir(), '/fake/tmp');
    });

    test('workDir：resolver 失败返回 null（payload 置空 → Go 回落现状）', () async {
      RelayDirs.debugWorkDirResolver = () async => null;
      expect(await RelayDirs.workDir(), isNull);
    });

    test('caFile：注入 resolver 生效（真机路径在 flutter test 无插件通道）', () async {
      RelayDirs.debugCaFileResolver = () async => '/fake/tmp/aquan-cast-ca.pem';
      expect(await RelayDirs.caFile(), '/fake/tmp/aquan-cast-ca.pem');
    });

    test('caFile：memoize 复用 + 注入重置（防测试间静态状态互串）', () async {
      final base = await Directory.systemTemp.createTemp('aquan-ca-test');
      addTearDown(() async => await base.delete(recursive: true));
      final pem = utf8.encode(
          '-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n');
      var loads = 0;
      RelayDirs.debugWorkDirResolver = () async => base.path;
      RelayDirs.debugCaFileResolver = () async {
        loads++;
        final f = File('${base.path}${Platform.pathSeparator}aquan-cast-ca.pem');
        if (!await f.exists()) {
          await f.writeAsBytes(Uint8List.fromList(pem), flush: true);
        }
        return f.path;
      };
      final p1 = await RelayDirs.caFile();
      final p2 = await RelayDirs.caFile();
      expect(p1, p2);
      expect(await File(p1!).exists(), isTrue);
      expect(await File(p1).readAsString(), contains('BEGIN CERTIFICATE'));
      expect(loads, 1, reason: 'caFile memoize：二次调用不再触发 resolver');

      // 重新注入（重置 memoize）：新 resolver 立即生效。
      RelayDirs.debugCaFileResolver = () async => '/reset/path.pem';
      expect(await RelayDirs.caFile(), '/reset/path.pem');
    });
  });
}
