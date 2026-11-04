import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'source_adapter.dart';
import 'source_import.dart';

/// 本地合并源的标识。`local://` 只是配置列表里的展示身份，不做 URL 解析：
/// 真身是应用支持目录下的 [mergedSourceFile]，读它走文件系统。
const String mergedSourceScheme = 'local://';
const String mergedSourceFile = 'merged_sources.json';
const String mergedSourceUrl = 'local://merged_sources.json';
const String mergedSourceName = '本地合并源';

/// TVBox `sites[].type`：0 XML / 1 JSON / 3 爬虫。
int tvboxSiteType(SourceKind kind) => switch (kind) {
      SourceKind.cmsXml => 0,
      SourceKind.cmsJson => 1,
      SourceKind.spiderJs => 3,
      SourceKind.spider => 3,
    };

/// 合并结果。
class MergedBuildResult {
  const MergedBuildResult({
    required this.json,
    required this.siteCount,
    required this.sourceCount,
    required this.duplicates,
    this.message = '',
  });

  final String json;
  final int siteCount;
  final int sourceCount;

  /// 被后端签名判定为重复而丢弃的站点数。
  final int duplicates;
  final String message;

  bool get ok => siteCount > 0;
}

/// 把「当前所有可用站点」合成一份 TVBox 单仓配置。
///
/// 规则对齐 TVBox `LocalSourceMerger`：
/// - 站点去重键 `type|api|ext|生效 jar`，重复保留第一个；
/// - `key` 冲突追加 `_2/_3…`；`name` 冲突追加来源名；
/// - `parses` 按 url 去重；其余元数据（searchable/filterable/header/ext）原样保留。
class MergedSourceBuilder {
  const MergedSourceBuilder._();

  static MergedBuildResult build(
    Iterable<SourceConfig> sources, {
    List<ParseApi> parses = const <ParseApi>[],
  }) {
    final list = List<SourceConfig>.of(sources);
    final sites = <Map<String, dynamic>>[];
    final keys = <String>{};
    final names = <String>{};
    final signatures = <String>{};
    final parsedUrls = <String>{};
    var duplicates = 0;
    var usedSources = 0;

    for (final source in list) {
      final api = source.api.trim();
      if (api.isEmpty) continue;
      // 本地没有 JVM 爬虫引擎：jar 源导出后对端能识别，但本机重新导入会失败，
      // 这类站点不写入合并源。
      if (source.kind == SourceKind.spider) continue;

      final type = tvboxSiteType(source.kind);
      final ext = source.ext.trim();
      final jar = _effectiveJar(source);
      // 同一接口带不带尾斜杠很常见：合并时按归一化地址判重。
      final normalizedApi =
          api.endsWith('/') ? api.substring(0, api.length - 1) : api;
      final signature = '$type|$normalizedApi|$ext|$jar';
      if (!signatures.add(signature)) {
        duplicates++;
        continue;
      }

      var key = (source.spiderKey ?? source.id).trim();
      if (key.isEmpty) key = 'site_${sites.length + 1}';
      final baseKey = key;
      for (var n = 2; !keys.add(key); n++) {
        key = '${baseKey}_$n';
      }

      var name = source.name.trim();
      if (name.isEmpty) name = api;
      if (!names.add(name)) {
        final suffix = source.name.trim().isEmpty ? baseKey : source.name.trim();
        var candidate = '$name（$suffix）';
        var n = 2;
        while (!names.add(candidate)) {
          candidate = '$name（$suffix $n）';
          n++;
        }
        name = candidate;
      }

      final site = <String, dynamic>{
        'key': key,
        'name': name,
        'type': type,
        'api': api,
        'searchable': 1,
        'quickSearch': 1,
        'filterable': 1,
      };
      if (ext.isNotEmpty) site['ext'] = ext;
      if (source.headers.isNotEmpty) site['header'] = source.headers;
      sites.add(site);
      usedSources++;
    }

    final parseList = <Map<String, dynamic>>[];
    for (final parse in parses) {
      final url = parse.url.trim();
      if (url.isEmpty || !parsedUrls.add(url)) continue;
      parseList.add(<String, dynamic>{
        'name': parse.name,
        'type': 1,
        'url': url,
        if (parse.ext.trim().isNotEmpty) 'ext': parse.ext.trim(),
      });
    }

    final out = <String, dynamic>{'sites': sites};
    if (parseList.isNotEmpty) out['parses'] = parseList;

    final json = const JsonEncoder.withIndent('  ').convert(out);
    return MergedBuildResult(
      json: json,
      siteCount: sites.length,
      sourceCount: usedSources,
      duplicates: duplicates,
      message: sites.isEmpty ? '没有可合并的站点' : '',
    );
  }

  /// 生成本地配置的「生效 jar」签名位：本地只有 JS 爬虫，jar 为空；
  /// 保留该位是为了与 TVBox 的去重语义保持同构。
  static String _effectiveJar(SourceConfig source) {
    final key = source.spiderKey ?? '';
    return key.startsWith('jar:') ? key : '';
  }
}

/// 合并快照的读写（应用支持目录）。
class MergedSourceStore {
  MergedSourceStore({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  static int _seq = 0;

  Future<File> _file() async {
    final dir = await _supportDirectory();
    return File('${dir.path}${Platform.pathSeparator}$mergedSourceFile');
  }

  /// 写入快照：临时文件（带 pid + 序号）→ flush → rename。
  ///
  /// 文件名带 pid 是 xiugou-tv 的教训：多实例/上次崩溃残留的临时文件不能互相覆盖。
  Future<bool> write(String json) async {
    File? tmp;
    try {
      final target = await _file();
      tmp = File('${target.path}.tmp-$pid-${++_seq}');
      await tmp.writeAsString(json, flush: true);
      if (await target.exists()) {
        await target.delete();
      }
      await tmp.rename(target.path);
      return true;
    } catch (_) {
      try {
        if (tmp != null && await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return false;
    }
  }

  Future<String?> read() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (_) {
      return null;
    }
  }

  Future<MergedSnapshotInfo?> info() async {
    try {
      final file = await _file();
      if (!await file.exists()) return null;
      final stat = await file.stat();
      final raw = await file.readAsString();
      final decoded = jsonDecode(raw);
      final sites = decoded is Map ? decoded['sites'] : null;
      return MergedSnapshotInfo(
        siteCount: sites is List ? sites.length : 0,
        builtAt: stat.modified,
        path: file.path,
      );
    } catch (_) {
      return null;
    }
  }
}

/// 快照元信息（UI 展示用）。
class MergedSnapshotInfo {
  const MergedSnapshotInfo({
    required this.siteCount,
    required this.builtAt,
    required this.path,
  });

  final int siteCount;
  final DateTime builtAt;
  final String path;
}
