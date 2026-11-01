/// 内置书源种子目录（影视 `source_seed.dart` 的书源版）。
///
/// 一条种子指向**一个 legado 书源 JSON 数组地址**（可导入的多源集合）。
/// GitHub raw 地址一律带镜像变体，扫描时按 [urls] 顺序回退取第一个能连通的。
/// 网页型聚合站（Yiove / 源仓库 等）不在此列——它们不返回可直读的 JSON 数组，
/// 需其导出/API 地址，改由「仓库拉取」手填，扫描会诚实标注不可解析。
///
/// 可达性以**设备内扫描**为准（本机 shell 出网与用户网络不同）；这里只登记候选。
library;

class BookSeed {
  const BookSeed({
    required this.id,
    required this.name,
    required this.urls,
    this.builtin = true,
  });

  final String id;
  final String name;

  /// 依次回退的等价地址（直连 + 镜像），命中即用。
  final List<String> urls;
  final bool builtin;

  String get url => urls.first;

  static const _ghRaw = 'https://raw.githubusercontent.com';
  static const _jsdelivr = 'https://cdn.jsdelivr.net/gh';
  static const _fastly = 'https://fastly.jsdelivr.net/gh';

  /// 生成 GitHub raw + jsdelivr + fastly 三个等价地址（owner/repo@ref/path）。
  static List<String> github(String ownerRepoRefPath) => [
        '$_ghRaw/$ownerRepoRefPath',
        // raw 用 /owner/repo/branch/path；jsdelivr 用 /gh/owner/repo@branch/path
        '$_jsdelivr/${_toJsdelivr(ownerRepoRefPath)}',
        '$_fastly/${_toJsdelivr(ownerRepoRefPath)}',
      ];

  static String _toJsdelivr(String rawPath) {
    // rawPath: owner/repo/branch/rest...
    final seg = rawPath.split('/');
    if (seg.length < 4) return rawPath;
    final owner = seg[0], repo = seg[1], ref = seg[2];
    final rest = seg.sublist(3).join('/');
    return '$owner/$repo@$ref/$rest';
  }
}

/// 内置书源种子（用户所列仓库中「可直读 JSON 数组」的候选；扫描按设备网络判可达）。
final List<BookSeed> builtinBookSeeds = [
  BookSeed(
    id: 'xiu2-yuedu',
    name: '「阅读」APP 精品书源 (XIU2)',
    urls: [
      'https://fastly.jsdelivr.net/gh/XIU2/Yuedu@master/shuyuan',
      'https://cdn.jsdelivr.net/gh/XIU2/Yuedu@master/shuyuan',
      'https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan',
    ],
  ),
  BookSeed(
    id: 'shidahuilang-shuyuan',
    name: '大灰狼书源合集 (shuyuan)',
    urls: BookSeed.github('shidahuilang/shuyuan/shuyuan/good.json'),
  ),
  BookSeed(
    id: 'zgq-inc-source',
    name: 'zgq-inc 源整合',
    urls: BookSeed.github('zgq-inc/source/master/data/source_url.json'),
  ),
];

/// 净化规则源（P3 吸收进 replace_rules，不参与书源三连校验）。
final BookSeed builtinPurificationSeed = BookSeed(
  id: 'shidahuilang-jinghua',
  name: '大灰狼 规则净化 (jinghua)',
  urls: BookSeed.github('shidahuilang/shuyuan/shuyuan/jinghua.json'),
);

/// 网页型聚合站：不返回可直读 JSON 数组，登记为「需手填导出地址」的引导项。
final List<BookSeed> bookSourceAggregators = [
  BookSeed(id: 'yiove', name: 'Yiove 书源仓库', urls: ['https://shuyuan.yiove.com/']),
  BookSeed(id: 'yckceo', name: '源仓库 (yckceo)', urls: ['https://www.yckceo.com/yuedu/shuyuan/index.html']),
  BookSeed(id: 'aoaostar', name: 'legado (aoaostar)', urls: ['https://legado.aoaostar.com/']),
];
