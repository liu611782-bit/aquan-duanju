// Venera 收藏闭环：详情收藏 → FollowStore 落盘（venera: 前缀键）→ 取消。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/venera/venera_js_runtime.dart';
import 'package:aquan_duanju/core/sources/venera/venera_manga_source.dart';
import 'package:aquan_duanju/store/stores.dart';

import 'native_lib_guard.dart';

const _fixtureJs = '''
class FollowFixture extends ComicSource {
    name = "收藏夹具"
    key = "follow_fixture"
    version = "1.0.0"

    comic = {
      loadInfo: (id) => {
        return {title: '收藏测试漫画', cover: 'http://c/1.jpg', description: '',
          chapters: [{id: 'g1', title: '正篇', episodes: [{id: 'e1', title: '第1话'}, {id: 'e2', title: '第2话'}]}]};
      }
    }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  test('Venera 收藏：toggle 落盘 FollowStore（venera: 键 + 章节数）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final store = VeneraStore(testDirectory: Directory.systemTemp
        .createTempSync('aquan_venera_follow'));
    addTearDown(() {
      if (store.testDirectory!.existsSync()) {
        store.testDirectory!.deleteSync(recursive: true);
      }
    });
    await store.ensureLoaded();
    final runtime = VeneraJsRuntime.instance;
    runtime.store = store;
    addTearDown(runtime.dispose);

    final source = VeneraMangaSource(_fixtureJs);
    await source.load();
    final detail = await source.loadInfo('comic-9');
    expect(detail.title, '收藏测试漫画');
    expect(detail.flatEpisodes, hasLength(2));

    // 模拟详情页收藏 toggle（与 VeneraMangaDetailScreen 同参数）。
    final follows = FollowStore(testDirectory: Directory.systemTemp
        .createTempSync('aquan_follow'));
    addTearDown(() {
      if (follows.testDirectory!.existsSync()) {
        follows.testDirectory!.deleteSync(recursive: true);
      }
    });
    await follows.toggle(
      seriesId: 'venera:follow_fixture:comic-9',
      title: detail.title,
      coverUrl: detail.cover,
      episodeCount: detail.flatEpisodes.length,
    );
    final entry = follows.get('venera:follow_fixture:comic-9');
    expect(entry, isNotNull);
    expect(entry!.title, '收藏测试漫画');
    expect(entry.episodeCount, 2);

    // 取消。
    await follows.toggle(
      seriesId: 'venera:follow_fixture:comic-9',
      title: detail.title,
      coverUrl: detail.cover,
      episodeCount: detail.flatEpisodes.length,
    );
    expect(follows.get('venera:follow_fixture:comic-9'), isNull);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
