import 'venera_js_runtime.dart';

/// Venera 漫画源的结构化封装：explore/search/loadInfo/loadEp → 漫画数据。
///
/// Venera 契约：`explore = [{title, load: async () => {title, comics}}]`、
/// `search = {load: async (kw, options, page)}`、
/// `comic = {loadInfo: async (id) → ComicDetails{chapters:[{id,title,episodes}]},
/// loadEp: async (comicId, epId) → {images, maxPage}}`。
class VeneraMangaSource {
  VeneraMangaSource(this.jsSource);

  final String jsSource;

  Map<String, dynamic> info = const {};
  String get key => info['key']?.toString() ?? '';
  String get name => info['name']?.toString() ?? '';

  Future<void> load() async {
    info = await VeneraJsRuntime.instance.loadSource(jsSource);
  }

  /// 探索页标题列表（`explore[i].title`）。
  Future<List<String>> exploreTitles() async {
    final raw = await VeneraJsRuntime.instance.evalJson(
        'JSON.stringify((globalThis.__veneraSources["$key"].explore ?? [])'
        '.map(e => ({title: e.title})))');
    if (raw is! List) return const [];
    return [
      for (final e in raw)
        if (e is Map) e['title']?.toString() ?? '',
    ];
  }

  /// 探索页内容：返回漫画列表（`explore[i].load()` → {title, comics} 或数组）。
  Future<List<VeneraComic>> exploreLoad(int index) async {
    final result =
        await VeneraJsRuntime.instance.callMethod(key, 'explore.$index.load', []);
    return VeneraComic.comicsOf(result);
  }

  /// 搜索（`search.load(kw, options, page)`）。
  Future<List<VeneraComic>> search(String keyword, int page) async {
    final result = await VeneraJsRuntime.instance
        .callMethod(key, 'search.load', [keyword, <String, dynamic>{}, page]);
    return VeneraComic.comicsOf(result);
  }

  /// 详情：`comic.loadInfo(id)` → ComicDetails。
  Future<VeneraComicDetail> loadInfo(String comicId) async {
    final result =
        await VeneraJsRuntime.instance.callMethod(key, 'comic.loadInfo', [comicId]);
    if (result is! Map) {
      throw Exception('Venera loadInfo 返回异常: $result');
    }
    final groups = <VeneraChapterGroup>[];
    final chapters = result['chapters'];
    if (chapters is List) {
      for (final g in chapters) {
        if (g is! Map) continue;
        final eps = <VeneraEpisode>[];
        final episodeList = g['episodes'];
        if (episodeList is List) {
          for (final e in episodeList) {
            if (e is! Map) continue;
            eps.add(VeneraEpisode(
              id: e['id']?.toString() ?? '',
              title: e['title']?.toString() ?? '',
            ));
          }
        }
        groups.add(VeneraChapterGroup(
          id: g['id']?.toString() ?? '',
          title: g['title']?.toString() ?? '',
          episodes: eps,
        ));
      }
    }
    return VeneraComicDetail(
      title: result['title']?.toString() ?? '',
      cover: result['cover']?.toString() ?? '',
      description: result['description']?.toString() ?? '',
      chapters: groups,
    );
  }

  /// 设置声明（`settings` 对象：key → {title, type, default, options...}）。
  Future<Map<String, dynamic>> settingsSchema() async {
    final raw = await VeneraJsRuntime.instance.evalJson(
        'JSON.stringify(globalThis.__veneraSources["$key"].settings ?? {})');
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(),
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{}));
  }

  /// 读当前设置值（源 loadSetting → 宿主 store，含默认值回退）。
  Future<dynamic> loadSettingValue(String settingKey) =>
      VeneraJsRuntime.instance.callMethod(key, 'loadSetting', [settingKey]);

  /// 写设置值（宿主职责：直接落 VeneraStore；源经 loadSetting 读回）。
  Future<void> saveSettingValue(String settingKey, dynamic value) =>
      VeneraJsRuntime.instance.saveSetting(key, settingKey, value);

  /// 源是否声明账号功能（`account` 对象）。
  Future<bool> hasAccount() async => (await VeneraJsRuntime.instance.evalJson(
          '!!globalThis.__veneraSources["$key"].account')) ==
      true;

  /// 登录态（源的 isLogged getter → 宿主按 token 判定）。
  Future<bool> isLogged() async => (await VeneraJsRuntime.instance.evalJson(
          '(globalThis.__veneraSources["$key"].isLogged) === true')) ==
      true;

  /// 登录（`account.login(username, password)`——源内部经 save_data 存 token）。
  Future<void> login(String username, String password) async {
    await VeneraJsRuntime.instance
        .callMethod(key, 'account.login', [username, password]);
  }

  /// 登出（`account.logout()` → delete_data(token)）。
  Future<void> logout() async {
    await VeneraJsRuntime.instance.callMethod(key, 'account.logout', []);
  }

  /// 章节图片：`comic.loadEp(comicId, epId)` → {images}。
  Future<List<String>> loadEpImages(String comicId, String epId) async {
    final result = await VeneraJsRuntime.instance
        .callMethod(key, 'comic.loadEp', [comicId, epId]);
    if (result is Map) {
      final images = result['images'];
      if (images is List) {
        return [for (final u in images) u?.toString() ?? ''].where((u) => u.isNotEmpty).toList();
      }
    }
    return const [];
  }
}

class VeneraComic {
  const VeneraComic({required this.id, required this.title, required this.cover});

  final String id;
  final String title;
  final String cover;

  /// Venera 结果的宽容取漫画列表，三形态：
  /// ① 数组本体；② {comics|list: [...]}；③ **分节键值**（键=栏目名、值=数组，
  /// 如 `{推荐: [...], 编辑推荐: [...]}`——explore 最常见返回）。
  static List<VeneraComic> comicsOf(dynamic result) {
    // ignore: avoid_print
    print('[VPDBG3] comicsOf type=${result.runtimeType} '
        'head=${result is Map ? result.keys.toList() : result.toString().substring(0, result.toString().length.clamp(0, 60))}');
    if (result is List) return _fromList(result);
    if (result is Map) {
      final named = result['comics'] ?? result['list'];
      if (named is List) return _fromList(named);
      final out = <VeneraComic>[];
      for (final v in result.values) {
        if (v is List) out.addAll(_fromList(v));
      }
      return out;
    }
    return const [];
  }

  static List<VeneraComic> _fromList(List list) => [
        for (final c in list)
          if (c is Map)
            VeneraComic(
              id: c['id']?.toString() ?? '',
              title: (c['title'] ?? c['name'])?.toString() ?? '',
              cover: c['cover']?.toString() ?? '',
            ),
      ].where((c) => c.id.isNotEmpty).toList();
}

class VeneraEpisode {
  const VeneraEpisode({required this.id, required this.title});

  final String id;
  final String title;
}

class VeneraChapterGroup {
  const VeneraChapterGroup({
    required this.id,
    required this.title,
    required this.episodes,
  });

  final String id;
  final String title;
  final List<VeneraEpisode> episodes;
}

class VeneraComicDetail {
  const VeneraComicDetail({
    required this.title,
    required this.cover,
    required this.description,
    required this.chapters,
  });

  final String title;
  final String cover;
  final String description;
  final List<VeneraChapterGroup> chapters;

  /// 展平的章节（组标题作卷名）。
  List<({String id, String title, String volume})> get flatEpisodes => [
        for (final g in chapters)
          for (final e in g.episodes) (id: e.id, title: e.title, volume: g.title),
      ];
}
