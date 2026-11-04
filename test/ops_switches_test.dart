import 'dart:io';

import 'package:aquan_duanju/core/ops_switches.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(OpsSwitches.reset);

  test('parse：注释、布尔别名、坏行都不影响其它键', () {
    final values = OpsSwitches.parse('''
# 运维急停（只放急停项）
disable_auto_source: true   # 行尾注释
disable_auto_update: OFF
disable_auto_merge: yes
broken line without colon
disable_x:
: true
''');
    expect(values['disable_auto_source'], isTrue);
    expect(values['disable_auto_update'], isFalse);
    expect(values['disable_auto_merge'], isTrue);
    expect(values.containsKey('disable_x'), isFalse);
  });

  test('load：支持目录里的 app_ops.yaml 生效', () async {
    final tmp = await Directory.systemTemp.createTemp('aquan_ops_test');
    addTearDown(() => tmp.delete(recursive: true));
    await File('${tmp.path}${Platform.pathSeparator}${OpsSwitches.fileName}')
        .writeAsString('''
disable_auto_source: true
disable_auto_merge: true
''');
    await OpsSwitches.load(supportDirectory: tmp);
    expect(OpsSwitches.disableAutoSource, isTrue);
    expect(OpsSwitches.disableAutoUpdate, isFalse);
    expect(OpsSwitches.disableAutoMerge, isTrue);
    expect(OpsSwitches.anyActive, isTrue);
    expect(OpsSwitches.loadedFrom, contains(OpsSwitches.fileName));
  });

  test('load：没有配置文件时全部关闭', () async {
    final tmp = await Directory.systemTemp.createTemp('aquan_ops_none');
    addTearDown(() => tmp.delete(recursive: true));
    await OpsSwitches.load(supportDirectory: tmp);
    expect(OpsSwitches.anyActive, isFalse);
    expect(OpsSwitches.loadedFrom, isEmpty);
  });

  test('load：文件内容损坏不抛异常且按关闭处理', () async {
    final tmp = await Directory.systemTemp.createTemp('aquan_ops_bad');
    addTearDown(() => tmp.delete(recursive: true));
    await File('${tmp.path}${Platform.pathSeparator}${OpsSwitches.fileName}')
        .writeAsString('::: not yaml :::\n\t- broken');
    await OpsSwitches.load(supportDirectory: tmp);
    expect(OpsSwitches.anyActive, isFalse);
  });
}
