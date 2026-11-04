import 'dart:async';
import 'dart:convert';
import 'dart:typed_data' show BytesBuilder;

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import 'source_adapter.dart';
import 'source_seed.dart';

/// 配置的发现来源。
enum DiscoveryOrigin {
  github('GitHub'),
  gitlab('GitLab'),
  gitee('Gitee'),
  builtin('内置'),
  manual('手动');

  const DiscoveryOrigin(this.label);
  final String label;

  static DiscoveryOrigin fromName(Object? name) => values.firstWhere(
        (v) => v.name == name,
        orElse: () => DiscoveryOrigin.manual,
      );
}

/// 一条在线发现的配置候选（尚未验证）。
class DiscoveredConfig {
  const DiscoveredConfig({
    required this.name,
    required this.url,
    required this.origin,
    this.detail = '',
  });

  final String name;
  final String url;
  final DiscoveryOrigin origin;

  /// 例如 `qist/tvbox@master` 或搜索关键词。
  final String detail;
}

/// 一次发现的结果。
class DiscoveryReport {
  DiscoveryReport(this.configs);

  final List<DiscoveredConfig> configs;
  final List<String> notes = <String>[];

  void note(String text) {
    if (text.isEmpty || notes.contains(text)) return;
    notes.add(text);
  }
}

/// 单个平台的扫描参数（默认值取自 TVBox `source_index.json`）。
class DiscoveryPlatformConfig {
  const DiscoveryPlatformConfig({
    this.enabled = true,
    this.repos = const <String>[],
    this.queries = const <String>[],
    this.maxRepos = 8,
    this.maxFilesPerRepo = 8,
    this.guessFilenames = const <String>[],
    this.readmeCandidates = const <String>['README.md', 'readme.md', 'README.txt'],
  });

  final bool enabled;
  final List<String> repos;
  final List<String> queries;
  final int maxRepos;
  final int maxFilesPerRepo;
  final List<String> guessFilenames;
  final List<String> readmeCandidates;
}

/// 默认发现配置。
class DiscoveryConfig {
  const DiscoveryConfig({
    this.github = const DiscoveryPlatformConfig(
      repos: <String>['qist/tvbox@master', 'gaotianliuyun/gao@master'],
      queries: <String>[
        'tvbox config in:name,description',
        'tvbox 接口 in:name,description',
        'tvbox json in:name,description',
        'catvod config in:name,description',
      ],
      guessFilenames: <String>[
        'jsm.json',
        '0821.json',
        '0825.json',
        '0827.json',
        'dianshi.json',
        'config.json',
        'api.json',
        'tvbox.json',
        'single.json',
        'main.json',
        'tvbox_config.json',
        'json/config.json',
        'json/jsm.json',
        'color.json',
      ],
    ),
    this.gitlab = const DiscoveryPlatformConfig(
      repos: <String>['noimank/tvbox@main'],
      queries: <String>['tvbox', 'tvbox config'],
      maxRepos: 3,
      maxFilesPerRepo: 5,
      guessFilenames: <String>[
        'tvboxmuti.json',
        'tvbox.json',
        'config.json',
        'api.json',
        'jsm.json',
      ],
    ),
    this.gitee = const DiscoveryPlatformConfig(
      repos: <String>['gaoops404/tvbox-config@main'],
      queries: <String>['tvbox', 'tvbox config', '电视盒子'],
      maxRepos: 3,
      maxFilesPerRepo: 5,
      guessFilenames: <String>[
        'tvbox.json',
        'config.json',
        'api.json',
        'jsm.json',
        'single.json',
      ],
    ),
    this.maxCandidates = 40,
  });

  final DiscoveryPlatformConfig github;
  final DiscoveryPlatformConfig gitlab;
  final DiscoveryPlatformConfig gitee;

  /// 一轮发现最多保留的候选数（对齐 TVBox `MAX_CANDIDATES`）。
  final int maxCandidates;
}

/// 在线发现：三平台搜索 + 仓库扫描（猜名 / 文件树 / jsDelivr / README）。
///
/// 只产出「看起来像配置」的地址，不做验证；验证由 [SourceValidator] 负责。
/// 任何平台失败只记 note，不影响其它平台。
class SourceDiscovery {
  SourceDiscovery({
    this.config = const DiscoveryConfig(),
    http.Client? client,
    this.timeout = const Duration(seconds: 12),
  }) : _client = client ?? http.Client();

  final DiscoveryConfig config;
  final http.Client _client;
  final Duration timeout;

  static const int _maxBytes = 512 * 1024;

  /// 触发杀软误报的地址（TVBox 侧同样屏蔽）。
  static const List<String> _blockedFragments = <String>['js.134584.xyz'];

  /// 明显不是配置的路径。
  static const List<String> _excludedFragments = <String>[
    'node_modules',
    '/jar/',
    '/assets/',
    '/.github/',
    '/src/',
    '/test/',
    '/docs/',
    '/build/',
    '/dist/',
  ];

  static const List<String> _excludedFiles = <String>[
    'package.json',
    'tsconfig.json',
    'manifest.json',
    'package-lock.json',
    'composer.json',
  ];

  /// 成人向配置排除词（TVBox `DEFAULT_EXCLUDES` 同款）。
  static const List<String> _adultMarks = <String>[
    '9918',
    '99188',
    '0707',
    'adult',
  ];

  static final RegExp _urlPattern =
      RegExp(r'''https?://[^\s"'<>()\[\]{},;，。；、！？`]+''');

  Future<DiscoveryReport> discover({
    CancelToken? cancel,
    String githubToken = '',
  }) async {
    final report = DiscoveryReport(<DiscoveredConfig>[]);
    final seen = <String>{};

    void add(String name, String url, DiscoveryOrigin origin, String detail) {
      if (cancel?.isCancelled ?? false) return;
      if (report.configs.length >= config.maxCandidates) return;
      final trimmed = url.trim();
      if (!_isConfigCandidate(trimmed, allowAnyFile: true)) return;
      if (_isAdult(name, trimmed)) return;
      final norm = normalizeSeedUrl(trimmed);
      if (norm.isEmpty || !seen.add(norm)) return;
      report.configs.add(DiscoveredConfig(
        name: name.trim().isEmpty ? _hostOf(norm) : name.trim(),
        url: trimmed,
        origin: origin,
        detail: detail,
      ));
    }

    await Future.wait(<Future<void>>[
      _scanGithub(add, report, cancel, githubToken),
      _scanGitlab(add, report, cancel),
      _scanGitee(add, report, cancel),
    ]);

    report.note('共 ${report.configs.length} 条候选配置');
    return report;
  }

  // ---------------- GitHub ----------------

  Future<void> _scanGithub(
    void Function(String, String, DiscoveryOrigin, String) add,
    DiscoveryReport report,
    CancelToken? cancel,
    String token,
  ) async {
    final cfg = config.github;
    if (!cfg.enabled) return;
    final headers = <String, String>{
      'Accept': 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
      if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
    };
    final repos = <String>[...cfg.repos];
    for (final query in cfg.queries) {
      if (cancel?.isCancelled ?? false) return;
      if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      final url = 'https://api.github.com/search/repositories'
          '?q=${Uri.encodeQueryComponent(query)}&sort=stars'
          '&per_page=${cfg.maxRepos}';
      final body = await _getJson(url, headers);
      if (body is! Map) {
        report.note('GitHub 搜索失败（可能触发限流）');
        break;
      }
      final items = body['items'];
      if (items is! List) continue;
      for (final item in items) {
        if (item is! Map) continue;
        final full = item['full_name']?.toString() ?? '';
        final branch = item['default_branch']?.toString() ?? 'main';
        if (full.isEmpty) continue;
        repos.add('$full@$branch');
        if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      }
    }
    for (final entry in repos) {
      if (cancel?.isCancelled ?? false) return;
      final spec = _RepoSpec.parse(entry);
      if (spec == null) continue;
      await _scanGithubRepo(spec, cfg, headers, add, cancel);
    }
  }

  Future<void> _scanGithubRepo(
    _RepoSpec repo,
    DiscoveryPlatformConfig cfg,
    Map<String, String> headers,
    void Function(String, String, DiscoveryOrigin, String) add,
    CancelToken? cancel,
  ) async {
    final guessed = <String>[
      for (final name in cfg.guessFilenames)
        'https://raw.githubusercontent.com/${repo.full}/${repo.branch}/$name',
    ];
    final discovered = <String>[];
    final tree = await _getJson(
      'https://api.github.com/repos/${repo.full}/git/trees/${repo.branch}?recursive=1',
      headers,
    );
    if (tree is Map) {
      final nodes = tree['tree'];
      if (nodes is List) {
        for (final node in nodes) {
          if (node is! Map) continue;
          final path = node['path']?.toString() ?? '';
          if (_isConfigCandidate(path, allowAnyFile: false)) {
            discovered.add('https://raw.githubusercontent.com/'
                '${repo.full}/${repo.branch}/$path');
          }
        }
      }
    } else {
      final jsdelivr = await _getJson(
        'https://data.jsdelivr.com/v1/packages/gh/${repo.full}@${repo.branch}?structure=flat',
        const <String, String>{},
      );
      final files = jsdelivr?['files'];
      if (files is List) {
        for (final file in files) {
          if (file is! Map) continue;
          final path = file['name']?.toString() ?? '';
          if (_isConfigCandidate(path, allowAnyFile: false)) {
            discovered.add('https://cdn.jsdelivr.net/gh/'
                '${repo.full}@${repo.branch}/$path');
          }
        }
      }
    }

    // README 里作者自己写的配置地址。
    final readmeUrls = <String>[];
    for (final name in cfg.readmeCandidates) {
      if (cancel?.isCancelled ?? false) return;
      final text = await _getText(
        'https://raw.githubusercontent.com/${repo.full}/${repo.branch}/$name',
      );
      if (text == null) continue;
      for (final match in _urlPattern.allMatches(text)) {
        final url = match.group(0)!;
        if (_isConfigCandidate(url, allowAnyFile: true)) readmeUrls.add(url);
      }
      break;
    }

    // 名额分配：猜名保底（cap>=6 时 3 个），发现结果占满，余量回填猜名。
    final cap = cfg.maxFilesPerRepo;
    final picked = <String>[];
    for (final url in guessed.take(cap >= 6 ? 3 : 1)) {
      picked.add(url);
    }
    for (final url in <String>[...discovered, ...readmeUrls]) {
      if (picked.length >= cap) break;
      if (!picked.contains(url)) picked.add(url);
    }
    for (final url in guessed) {
      if (picked.length >= cap) break;
      if (!picked.contains(url)) picked.add(url);
    }
    for (final url in picked) {
      if (cancel?.isCancelled ?? false) return;
      add(_nameForUrl(url, repo.full), url, DiscoveryOrigin.github, repo.spec);
    }
  }

  // ---------------- GitLab ----------------

  Future<void> _scanGitlab(
    void Function(String, String, DiscoveryOrigin, String) add,
    DiscoveryReport report,
    CancelToken? cancel,
  ) async {
    final cfg = config.gitlab;
    if (!cfg.enabled) return;
    final repos = <String>[...cfg.repos];
    for (final query in cfg.queries) {
      if (cancel?.isCancelled ?? false) return;
      if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      final url = 'https://gitlab.com/api/v4/projects'
          '?search=${Uri.encodeQueryComponent(query)}&simple=true'
          '&per_page=${cfg.maxRepos}&order_by=last_activity_at&sort=desc';
      final body = await _getJson(url, const <String, String>{});
      if (body is! List) {
        report.note('GitLab 搜索失败');
        break;
      }
      for (final item in body) {
        if (item is! Map) continue;
        final full = item['path_with_namespace']?.toString() ?? '';
        final branch = item['default_branch']?.toString() ?? 'main';
        if (full.isEmpty) continue;
        repos.add('$full@$branch');
        if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      }
    }
    for (final entry in repos) {
      if (cancel?.isCancelled ?? false) return;
      final repo = _RepoSpec.parse(entry);
      if (repo == null) continue;
      final paths = <String>[];
      final tree = await _getJson(
        'https://gitlab.com/api/v4/projects/${Uri.encodeComponent(repo.full)}'
        '/repository/tree?ref=${repo.branch}&recursive=true&per_page=100',
        const <String, String>{},
      );
      if (tree is List) {
        for (final node in tree) {
          if (node is! Map) continue;
          final path = node['path']?.toString() ?? '';
          if (_isConfigCandidate(path, allowAnyFile: false)) paths.add(path);
        }
      }
      final picked = <String>{
        ...cfg.guessFilenames.take(1),
        ...paths.take(cfg.maxFilesPerRepo),
      };
      for (final path in picked.take(cfg.maxFilesPerRepo)) {
        final url = 'https://gitlab.com/${repo.full}/-/raw/${repo.branch}/$path';
        add(_nameForUrl(url, repo.full), url, DiscoveryOrigin.gitlab, repo.spec);
      }
    }
  }

  // ---------------- Gitee ----------------

  Future<void> _scanGitee(
    void Function(String, String, DiscoveryOrigin, String) add,
    DiscoveryReport report,
    CancelToken? cancel,
  ) async {
    final cfg = config.gitee;
    if (!cfg.enabled) return;
    final repos = <String>[...cfg.repos];
    for (final query in cfg.queries) {
      if (cancel?.isCancelled ?? false) return;
      if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      final url = 'https://gitee.com/api/v5/search/repositories'
          '?q=${Uri.encodeQueryComponent(query)}&per_page=${cfg.maxRepos}';
      final body = await _getJson(url, const <String, String>{});
      if (body is! List) {
        report.note('Gitee 搜索失败');
        break;
      }
      for (final item in body) {
        if (item is! Map) continue;
        final full = item['full_name']?.toString() ?? '';
        final branch = item['default_branch']?.toString() ?? 'master';
        if (full.isEmpty) continue;
        repos.add('$full@$branch');
        if (repos.length >= cfg.repos.length + cfg.maxRepos) break;
      }
    }
    for (final entry in repos) {
      if (cancel?.isCancelled ?? false) return;
      final repo = _RepoSpec.parse(entry);
      if (repo == null) continue;
      final paths = <String>[];
      final tree = await _getJson(
        'https://gitee.com/api/v5/repos/${repo.full}/git/trees/${repo.branch}?recursive=1',
        const <String, String>{},
      );
      final nodes = tree is Map ? tree['tree'] : null;
      if (nodes is List) {
        for (final node in nodes) {
          if (node is! Map) continue;
          final path = node['path']?.toString() ?? '';
          if (_isConfigCandidate(path, allowAnyFile: false)) paths.add(path);
        }
      }
      final picked = <String>{
        ...cfg.guessFilenames.take(1),
        ...paths.take(cfg.maxFilesPerRepo),
      };
      for (final path in picked.take(cfg.maxFilesPerRepo)) {
        final url = 'https://gitee.com/${repo.full}/raw/${repo.branch}/$path';
        add(_nameForUrl(url, repo.full), url, DiscoveryOrigin.gitee, repo.spec);
      }
    }
  }

  // ---------------- 过滤 ----------------

  @visibleForTesting
  bool isConfigCandidate(String path) =>
      _isConfigCandidate(path, allowAnyFile: true);

  static bool _isConfigCandidate(String raw, {required bool allowAnyFile}) {
    final url = raw.trim();
    if (url.isEmpty) return false;
    final lower = url.toLowerCase();
    for (final blocked in _blockedFragments) {
      if (lower.contains(blocked)) return false;
    }
    // 允许「裸路径」（仓库文件名）与完整 URL 两种输入。
    if (url.startsWith('http')) {
      final uri = Uri.tryParse(url);
      if (uri == null || uri.host.isEmpty) return false;
      final path = uri.path.toLowerCase();
      if (_excludedFiles.contains(path.split('/').last)) return false;
      for (final fragment in _excludedFragments) {
        if (path.contains(fragment)) return false;
      }
      if (!allowAnyFile) {
        return path.endsWith('.json') || path.endsWith('.txt');
      }
      return path.endsWith('.json') ||
          path.endsWith('.txt') ||
          !path.contains('.') ||
          path.endsWith('/tv');
    }
    final path = url.toLowerCase();
    if (_excludedFiles.contains(path.split('/').last)) return false;
    for (final fragment in _excludedFragments) {
      if (path.contains(fragment)) return false;
    }
    if (path.split('/').where((s) => s.isNotEmpty).length > 2) return false;
    return path.endsWith('.json') ||
        path.endsWith('.txt') ||
        !path.contains('.') ||
        path.endsWith('/tv');
  }

  static bool _isAdult(String name, String url) {
    final text = '${name.toLowerCase()} ${url.toLowerCase()}';
    for (final mark in _adultMarks) {
      if (text.contains(mark)) return true;
    }
    return false;
  }

  static String _nameForUrl(String url, String repo) {
    final uri = Uri.tryParse(url);
    final parts = uri?.pathSegments ?? const <String>[];
    if (parts.isEmpty) return repo;
    final file = parts.last;
    if (file.isEmpty) return repo;
    return file.replaceAll(RegExp(r'\.(json|txt)$', caseSensitive: false), '');
  }

  static String _hostOf(String url) {
    try {
      return Uri.parse(url).host;
    } catch (_) {
      return url;
    }
  }

  // ---------------- HTTP ----------------

  Future<dynamic> _getJson(
    String url,
    Map<String, String> headers,
  ) async {
    final text = await _getText(url, headers: headers);
    if (text == null) return null;
    try {
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  Future<String?> _getText(String url, {Map<String, String>? headers}) async {
    try {
      final request = http.Request('GET', Uri.parse(url));
      request.headers['User-Agent'] = 'aquan-duanju';
      if (headers != null) request.headers.addAll(headers);
      final streamed = await _client.send(request).timeout(timeout);
      // 403/429 多半是限流：按「本平台失败」处理，不重试、不影响其它平台。
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) return null;
      final builder = BytesBuilder(copy: false);
      var size = 0;
      await for (final chunk in streamed.stream.timeout(timeout)) {
        size += chunk.length;
        if (size > _maxBytes) break;
        builder.add(chunk);
      }
      return utf8.decode(builder.takeBytes(), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }
}

/// `owner/repo@branch` 解析结果。
class _RepoSpec {
  const _RepoSpec(this.full, this.branch);

  final String full;
  final String branch;

  String get spec => '$full@$branch';

  static _RepoSpec? parse(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final at = trimmed.lastIndexOf('@');
    if (at <= 0 || at == trimmed.length - 1) {
      return _RepoSpec(trimmed, 'main');
    }
    return _RepoSpec(trimmed.substring(0, at), trimmed.substring(at + 1));
  }
}
