import 'package:http/http.dart' as http;

import 'cms_json_adapter.dart';
import 'config_decoder.dart';
import 'market_classify.dart';
import 'source_adapter.dart';
import 'source_fetch.dart';
import 'source_import.dart';

/// 一条配置的验证结论（三层：能下载解码 / 有采集站 / 抽样站点真响应）。
class ConfigValidation {
  const ConfigValidation({
    required this.url,
    required this.usable,
    required this.name,
    required this.siteCount,
    required this.cmsSiteCount,
    required this.verifiedSites,
    required this.latencyMs,
    required this.message,
    required this.checkedAt,
  });

  /// 实际生效的配置地址：多仓命中某条线路时会回写成线路地址。
  final String url;
  final bool usable;
  final String name;
  final int siteCount;

  /// 其中可直连的 CMS 站点数（type 0/1）。
  final int cmsSiteCount;

  /// 抽样中真实返回分类列表的站点数。
  final int verifiedSites;
  final int latencyMs;
  final String message;
  final DateTime checkedAt;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'url': url,
        'usable': usable,
        'name': name,
        'site_count': siteCount,
        'cms_site_count': cmsSiteCount,
        'verified_sites': verifiedSites,
        'latency_ms': latencyMs,
        'message': message,
        'checked_at': checkedAt.millisecondsSinceEpoch,
      };
}

/// 配置验证器。
///
/// 门槛对齐 TVBox `FinderProbe`：抽样站点里**至少 1 个**能返回非空分类列表
/// 才算可用；爬虫站只计数，不加载（本地只有 JS 运行时，验证代价高）。
class SourceValidator {
  SourceValidator({
    http.Client? client,
    this.maxSitesPerConfig = 2,
    this.requestTimeout = const Duration(seconds: 5),
    this.totalBudget = const Duration(seconds: 25),
    this.maxMultiRepoLines = 5,
  }) : _client = client ?? http.Client();

  final http.Client _client;
  final int maxSitesPerConfig;
  final Duration requestTimeout;
  final Duration totalBudget;
  final int maxMultiRepoLines;

  Future<ConfigValidation> validate(
    String url, {
    CancelToken? cancel,
  }) async {
    final sw = Stopwatch()..start();
    final deadline = DateTime.now().add(totalBudget);
    final checkedAt = DateTime.now();
    var effectiveUrl = url;

    final fetched = await fetchProbe(
      url,
      connectTimeout: const Duration(milliseconds: 4500),
      readTimeout: const Duration(milliseconds: 5500),
      maxBytes: 1024 * 1024,
      cancel: cancel,
    );
    if (!fetched.ok) {
      return _dead(url, checkedAt, fetched.error, sw);
    }

    Map<String, dynamic>? config;
    try {
      config = ConfigDecoder.decode(fetched.text);
    } on SourceException catch (e) {
      return _dead(url, checkedAt, '配置解析失败：${e.friendlyText}', sw);
    } catch (_) {
      return _dead(url, checkedAt, '配置解析失败', sw);
    }

    final info = classifyConfig(config);
    if (info == null || !info.known) {
      return _dead(url, checkedAt, '无法识别的配置结构', sw);
    }

    if (info.shape.isMulti) {
      final picked = await _resolveMultiRepo(
        info.children,
        cancel: cancel,
        deadline: deadline,
      );
      if (picked == null) {
        return _dead(url, checkedAt, '多仓线路均不可用', sw);
      }
      effectiveUrl = picked.url;
      config = picked.config;
    }

    final extracted = SourceImporter.extractSites(config, sourceUrl: effectiveUrl);
    final usable = extracted.where((c) => c.usable).toList();
    if (usable.isEmpty) {
      return ConfigValidation(
        url: effectiveUrl,
        usable: false,
        name: info.name,
        siteCount: 0,
        cmsSiteCount: 0,
        verifiedSites: 0,
        latencyMs: fetched.ttfbMs,
        message: '配置里没有可用的采集站',
        checkedAt: checkedAt,
      );
    }

    final cms = usable
        .where((c) =>
            c.kind == SourceKind.cmsJson || c.kind == SourceKind.cmsXml)
        .toList();
    var verified = 0;
    String message = '';
    final samples = cms.take(maxSitesPerConfig);
    for (final candidate in samples) {
      if (cancel?.isCancelled ?? false) break;
      if (DateTime.now().isAfter(deadline)) {
        message = '验证超出预算';
        break;
      }
      final ok = await _siteResponds(candidate);
      if (ok) {
        verified++;
      }
    }

    return ConfigValidation(
      url: effectiveUrl,
      usable: verified > 0,
      name: info.name,
      siteCount: usable.length,
      cmsSiteCount: cms.length,
      verifiedSites: verified,
      latencyMs: fetched.ttfbMs,
      message: verified > 0
          ? ''
          : (cms.isEmpty
              ? '只有爬虫站，未做抽样验证'
              : (message.isEmpty ? '抽样站点均无响应' : message)),
      checkedAt: checkedAt,
    );
  }

  Future<bool> _siteResponds(SourceCandidate candidate) async {
    final config = SourceConfig(
      id: 'validate_${candidate.api}',
      name: candidate.name,
      apis: <String>[candidate.api],
      kind: candidate.kind,
      spiderKey: candidate.spiderKey,
      headers: candidate.headers,
      ext: candidate.ext,
    );
    final adapter = CmsJsonAdapter(config, client: _client);
    try {
      final categories = await adapter.categories().timeout(requestTimeout);
      return categories.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<_PickedConfig?> _resolveMultiRepo(
    List<RepoChild> children, {
    CancelToken? cancel,
    required DateTime deadline,
  }) async {
    var tried = 0;
    for (final child in children) {
      if (cancel?.isCancelled ?? false) return null;
      if (tried >= maxMultiRepoLines || DateTime.now().isAfter(deadline)) break;
      tried++;
      final fetched = await fetchProbe(
        child.url,
        connectTimeout: const Duration(milliseconds: 4500),
        readTimeout: const Duration(milliseconds: 5500),
        maxBytes: 1024 * 1024,
        cancel: cancel,
      );
      if (!fetched.ok) continue;
      Map<String, dynamic>? config;
      try {
        config = ConfigDecoder.decode(fetched.text);
      } catch (_) {
        continue;
      }
      final sites = SourceImporter.extractSites(config, sourceUrl: child.url);
      if (sites.any((c) => c.usable)) {
        return _PickedConfig(url: child.url, config: config);
      }
    }
    return null;
  }

  ConfigValidation _dead(
    String url,
    DateTime checkedAt,
    String message,
    Stopwatch sw,
  ) =>
      ConfigValidation(
        url: url,
        usable: false,
        name: '',
        siteCount: 0,
        cmsSiteCount: 0,
        verifiedSites: 0,
        latencyMs: sw.elapsedMilliseconds,
        message: message,
        checkedAt: checkedAt,
      );
}

class _PickedConfig {
  const _PickedConfig({required this.url, required this.config});

  final String url;
  final Map<String, dynamic> config;
}
