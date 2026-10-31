import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/sources/source_acceptance.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_adapter_factory.dart';

/// 书源验收执行器（CLI）：对源跑 L0–L3 分级自检，逐行 JSONL 输出到 stdout。
///
/// 用法：
/// ```
/// dart run tool/source_acceptance.dart --config sources.json [--deep] [--source <id>]
/// ```
/// `--config` 接受：单个 SourceConfig 对象、SourceConfig 数组、或
/// `{"sources":[…]}` 包装（与源导出/导入格式互通）。报告落盘交给调用方
/// 重定向（`> report.jsonl`）。
///
/// 归因速查：cause=siteOrNetwork(A) 站点/网络；needsUpstreamComparison(B)
/// 结构嫌疑需对照上游；undetermined(C) 证据不足。
Future<void> main(List<String> args) async {
  String? configPath;
  var deep = false;
  String? onlyId;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--config':
        configPath = args[++i];
      case '--deep':
        deep = true;
      case '--source':
        onlyId = args[++i];
      case '--help' || '-h':
        stdout.writeln(
            '用法: dart run tool/source_acceptance.dart --config <file> [--deep] [--source <id>]');
        return;
    }
  }
  if (configPath == null) {
    stderr.writeln('缺少 --config <file>');
    exitCode = 2;
    return;
  }

  final List<SourceConfig> configs;
  try {
    final raw = jsonDecode(File(configPath).readAsStringSync());
    configs = _parseConfigs(raw);
  } catch (e) {
    stderr.writeln('配置解析失败：$e');
    exitCode = 2;
    return;
  }
  if (configs.isEmpty) {
    stderr.writeln('配置里没有源');
    exitCode = 2;
    return;
  }

  var ran = 0;
  for (final config in configs) {
    if (onlyId != null && config.id != onlyId) continue;
    final adapter = buildSourceAdapter(config);
    if (adapter == null) {
      stdout.writeln(AcceptanceFinding(
        level: SourceAcceptanceLevel.l0Contract,
        ok: false,
        detail: '源 ${config.id}（${config.kind.name}）暂不支持自动验收，跳过',
      ).toJsonLine());
      continue;
    }
    ran++;
    await for (final finding
        in const SourceAcceptanceRunner().run(adapter, deep: deep)) {
      stdout.writeln(finding.toJsonLine());
    }
  }
  if (ran == 0) {
    stderr.writeln('没有可运行的源（检查 --source 过滤或源类型）');
    exitCode = 1;
  }
}

List<SourceConfig> _parseConfigs(Object? raw) {
  List<Object?> entries;
  if (raw is List) {
    entries = raw;
  } else if (raw is Map && raw['sources'] is List) {
    entries = raw['sources'] as List<Object?>;
  } else if (raw is Map) {
    entries = [raw];
  } else {
    throw const FormatException('不支持的配置形状');
  }
  final out = <SourceConfig>[];
  for (final entry in entries) {
    if (entry is! Map) continue;
    final config = SourceConfig.fromJson(Map<String, dynamic>.from(entry));
    out.add(config);
  }
  return out;
}
