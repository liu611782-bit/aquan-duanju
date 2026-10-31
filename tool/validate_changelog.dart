import 'dart:convert';
import 'dart:io';

/// CHANGELOG.md 格式校验（Pathfin `extract_release_notes` 同思路的守门器）。
///
/// 规则（全部为 error，出现即退出码 1）：
/// - 第一个非空行必须是 `# ` 标题；
/// - 章节头 `## X.Y.Z (YYYY-MM-DD)` 或 `## [X.Y.Z] - YYYY-MM-DD`；
/// - 每个章节至少 1 条 `- ` 列表项；
/// - 版本号不得重复；
/// - 版本自上而下严格递减（新版本在前）；
/// - 给了 [pubspecVersion] 时，顶部章节版本必须与之一致。
///
/// 用法：
/// ```
/// dart run tool/validate_changelog.dart [--file CHANGELOG.md] [--pubspec pubspec.yaml]
/// ```
List<String> validateChangelog(String text, {String? pubspecVersion}) {
  final issues = <String>[];
  final lines = const LineSplitter().convert(text);

  final firstNonEmpty =
      lines.firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  if (!firstNonEmpty.startsWith('# ')) {
    issues.add('第一个非空行应以 "# " 开头（当前：${firstNonEmpty.isEmpty ? '<空文件>' : firstNonEmpty.trim()}）');
  }

  final header =
      RegExp(r'^##\s+(?:\[)?v?(\d+\.\d+\.\d+)(?:\])?\s*[(-]\s*(\d{4}-\d{2}-\d{2})');
  final versions = <String>[];
  var currentVersion = '';
  var currentBullets = 0;
  var inPreamble = true;

  void closeSection() {
    if (currentVersion.isEmpty) return;
    if (currentBullets == 0) {
      issues.add('章节 $currentVersion 没有任何 "- " 列表项');
    }
  }

  for (final line in lines) {
    final m = header.firstMatch(line);
    if (m != null) {
      closeSection();
      inPreamble = false;
      currentVersion = m.group(1)!;
      currentBullets = 0;
      if (versions.contains(currentVersion)) {
        issues.add('版本 $currentVersion 重复出现（章节头必须唯一）');
      } else {
        versions.add(currentVersion);
      }
      if (versions.length >= 2) {
        final prev = _parseVersion(versions[versions.length - 2]);
        final cur = _parseVersion(currentVersion);
        if (prev != null && cur != null && cur.compareTo(prev) >= 0) {
          issues.add(
              '版本顺序错误：$currentVersion 应比上一章节 ${versions[versions.length - 2]} 更新（新版本在前）');
        }
      }
      continue;
    }
    if (!inPreamble && line.trim().startsWith('- ')) currentBullets++;
  }
  closeSection();

  if (versions.isEmpty && issues.isEmpty) {
    issues.add('没有找到任何 "## X.Y.Z" 章节');
  }
  if (pubspecVersion != null &&
      versions.isNotEmpty &&
      versions.first != pubspecVersion) {
    issues.add(
        '顶部章节版本 ${versions.first} 与 pubspec version $pubspecVersion 不一致');
  }
  return issues;
}

Version? _parseVersion(String v) {
  final parts = v.split('.');
  if (parts.length != 3) return null;
  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  final patch = int.tryParse(parts[2]);
  if (major == null || minor == null || patch == null) return null;
  return Version(major, minor, patch);
}

class Version implements Comparable<Version> {
  const Version(this.major, this.minor, this.patch);
  final int major;
  final int minor;
  final int patch;

  @override
  int compareTo(Version other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is Version &&
      major == other.major &&
      minor == other.minor &&
      patch == other.patch;

  @override
  int get hashCode => Object.hash(major, minor, patch);
}

Future<void> main(List<String> args) async {
  var changelogPath = 'CHANGELOG.md';
  var pubspecPath = 'pubspec.yaml';
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--file':
        changelogPath = args[++i];
      case '--pubspec':
        pubspecPath = args[++i];
    }
  }
  final text = await File(changelogPath).readAsString();
  String? pubspecVersion;
  if (await File(pubspecPath).exists()) {
    final m = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(await File(pubspecPath).readAsString());
    // pubspec 版本常带 build 号（1.2.0+14）：只比对 semver 部分。
    if (m != null) pubspecVersion = m.group(1)!.split('+').first;
  }
  final issues = validateChangelog(text, pubspecVersion: pubspecVersion);
  if (issues.isEmpty) {
    stdout.writeln('CHANGELOG 校验通过');
    return;
  }
  for (final issue in issues) {
    stderr.writeln('CHANGELOG 校验失败：$issue');
  }
  exitCode = 1;
}
