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

  /// 生成 GitHub 多镜像等价地址（owner/repo/branch/path）。
  ///
  /// 顺序按「国内可达性」排：jsdelivr 系在两网都较稳，raw.githubusercontent 常被重置，
  /// 放最后兜底。扫描时命中即用，不会全部请求一遍。
  static List<String> github(String ownerRepoRefPath) => [
        '$_fastly/${_toJsdelivr(ownerRepoRefPath)}',
        '$_jsdelivr/${_toJsdelivr(ownerRepoRefPath)}',
        '$_ghRaw/$ownerRepoRefPath',
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
  // 只保留**实测能拉到 JSON** 的种子：旧的内置源（XIU2 / 大灰狼 / zgq-inc）
  // 要么整站被墙，要么里面的源全部失效，扫一轮全是红色失败，反而干扰判断。
  //
  // aoaostar 是 HTML 索引页：页面里给出 `.json` 直链，扫描器抓页面 → 抽链接 → 合并。
  BookSeed(
    id: 'aoaostar-legado',
    name: 'legado 源站合集 (aoaostar)',
    urls: ['https://legado.aoaostar.com/'],
  ),
  // 以下三条取自喵公子更新页的「一键导入」直链，本机实测可解析：
  BookSeed(
    id: 'xiu2-ns114',
    name: 'XIU2 精品书源（镜像）',
    urls: [
      'https://gh.ns114.cc/github.com/XIU2/Yuedu/raw/refs/heads/master/shuyuan',
    ],
  ),
  BookSeed(
    id: 'pobing-miaogongzi',
    name: '破冰书源 (91 个)',
    urls: ['https://legado.miaogongzi.org/阅读书源/sy.json'],
  ),
  BookSeed(
    id: 'yiove-stable-collection',
    name: 'Yiove 稳定书源合集',
    urls: [
      'https://shuyuan-api.yiove.com/import/book-source-collection/'
          'eaedccd4-1252-4962-a565-c7a342f95f90',
    ],
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

/// 站点入口（UI 直接打开浏览器，方便用户自己复制 JSON 地址）。
class BookSourceHub {
  const BookSourceHub({
    required this.name,
    required this.url,
    this.note = '',
  });

  final String name;
  final String url;
  final String note;
}

const List<BookSourceHub> bookSourceHubs = [
  BookSourceHub(
    name: 'Yiove 书源仓库',
    url: 'https://shuyuan.yiove.com/book-sources',
    note: '书源列表 / 合集（数据走 API，页面需浏览器执行 JS）',
  ),
  BookSourceHub(
    name: '源仓库（防失联）',
    url: 'https://yckceo.vip/',
    note: '阅读 / TVBox / 搜书大师等分类入口',
  ),
  BookSourceHub(
    name: 'legado 源站（aoaostar）',
    url: 'https://legado.aoaostar.com/',
    note: '书源 / 订阅源 / 净化规则 / TTS 引擎，含直链',
  ),
  BookSourceHub(
    name: '喵公子阅读',
    url: 'https://yuedu.miaogongzi.net/',
    note: '书源管理与订阅源导出',
  ),
];
