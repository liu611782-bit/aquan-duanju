import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/validate_changelog.dart';

void main() {
  group('validateChangelog', () {
    test('合法文档（两种章节头风格 + 多版本）通过', () {
      const text = '''
# 更新日志

## 1.2.0 (2026-10-30)

- 新功能 A
- 修复 B

## [1.1.0] - 2026-10-01

- 初版
''';
      expect(validateChangelog(text, pubspecVersion: '1.2.0'), isEmpty);
    });

    test('重复版本章节报错（对齐仓库现存缺陷）', () {
      const text = '''
# 更新日志

## 1.2.0 (2026-10-30)

- A

## 1.2.0 (2026-10-30)

- B
''';
      final issues = validateChangelog(text, pubspecVersion: '1.2.0');
      expect(issues.any((s) => s.contains('重复')), isTrue);
    });

    test('章节缺列表项报错', () {
      const text = '''
# 更新日志

## 1.0.0 (2026-01-01)

说明文字，但没有列表项。
''';
      final issues = validateChangelog(text);
      expect(issues.any((s) => s.contains('列表项')), isTrue);
    });

    test('版本顺序倒挂报错', () {
      const text = '''
# 更新日志

## 1.0.0 (2026-01-01)

- 旧

## 1.1.0 (2026-02-01)

- 新
''';
      final issues = validateChangelog(text);
      expect(issues.any((s) => s.contains('顺序错误')), isTrue);
    });

    test('顶部版本与 pubspec 不一致报错', () {
      const text = '''
# 更新日志

## 1.2.0 (2026-10-30)

- A
''';
      final issues = validateChangelog(text, pubspecVersion: '1.3.0');
      expect(issues.any((s) => s.contains('pubspec')), isTrue);
    });

    test('缺少标题行报错；空文件报错', () {
      expect(validateChangelog('## 1.0.0 (2026-01-01)\n\n- a\n'),
          anyElement(contains('# ')));
      expect(validateChangelog(''), isNotEmpty);
    });
  });

  test('仓库当前 CHANGELOG.md 与 pubspec 版本一致（常驻守门）', () {
    final text = File('CHANGELOG.md').readAsStringSync();
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    final issues = validateChangelog(
      text,
      pubspecVersion: m?.group(1)!.split('+').first,
    );
    expect(issues, isEmpty, reason: issues.join('\n'));
  });
}
