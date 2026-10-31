// Venera Phase 3 登录闭环集成测试：account.login → token 经 save_data 落盘 →
// 带 token 的章节请求解锁 → 重启（dispose 后重载）token 仍在。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/venera/venera_js_runtime.dart';
import 'package:aquan_duanju/core/sources/venera/venera_manga_source.dart';
import 'package:aquan_duanju/store/stores.dart';

import 'native_lib_guard.dart';

const _fixtureJs = '''
class LoginFixture extends ComicSource {
    name = "登录夹具"
    key = "login_fixture"
    version = "1.0.0"

    base = '';

    account = {
      login: async (account, pwd) => {
        var res = await sendMessage({method: 'http', http_method: 'POST',
          url: this.base + '/login',
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          data: 'u=' + account + '&p=' + pwd});
        if (res.status !== 200) throw 'login failed: ' + res.status;
        var data = JSON.parse(res.body);
        this.saveData('token', data.token);
        return 'ok';
      },
      logout: () => { this.deleteData('token'); }
    }

    comic = {
      loadInfo: async (id) => {
        var token = this.loadData('token');
        var res = await sendMessage({method: 'http', http_method: 'GET',
          url: this.base + '/chapters?id=' + id, headers: {authorization: 'Token ' + token}});
        var data = JSON.parse(res.body);
        if (!data.chapters || data.chapters.length === 0) throw 'no chapters: token=' + token;
        return {title: '测试漫画', cover: '', chapters: data.chapters};
      },
      loadEp: async (comicId, epId) => {
        var token = this.loadData('token');
        var res = await sendMessage({method: 'http', http_method: 'GET',
          url: this.base + '/images?ep=' + epId, headers: {authorization: 'Token ' + token}});
        var data = JSON.parse(res.body);
        return {images: data.images};
      }
    }
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late Directory support;
  final seenAuth = <String?>[];

  setUp(() async {
    support = Directory.systemTemp.createTempSync('aquan_venera_login');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final auth = req.headers.value('authorization');
      seenAuth.add(auth);
      req.response.headers.contentType = ContentType.json;
      if (req.uri.path == '/login') {
        final body = await utf8.decoder.bind(req).join();
        final ok = body.contains('u=user1') && body.contains('p=pass1');
        req.response.statusCode = ok ? 200 : 401;
        req.response.write(jsonEncode({'token': ok ? 'T123' : ''}));
      } else if (req.uri.path == '/chapters') {
        // 章节端点要求登录态：无/错 token → 401（站方行为模型）。
        req.response.statusCode = auth == 'Token T123' ? 200 : 401;
        req.response.write(jsonEncode({
          'chapters': [
            {
              'id': 'g1',
              'title': '正篇',
              'episodes': [
                {'id': 'ep1', 'title': '第1话'},
              ],
            },
          ],
        }));
      } else if (req.uri.path == '/images') {
        req.response.statusCode = auth == 'Token T123' ? 200 : 401;
        req.response.write(jsonEncode({
          'images': ['http://img.example/1.jpg', 'http://img.example/2.jpg'],
        }));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
    addTearDown(() => server.close(force: true));
    addTearDown(() {
      if (support.existsSync()) support.deleteSync(recursive: true);
    });
  });

  Future<VeneraMangaSource> makeSource(VeneraJsRuntime runtime) async {
    final store = VeneraStore(testDirectory: support);
    await store.ensureLoaded();
    runtime.store = store;
    final source = VeneraMangaSource(_fixtureJs.replaceFirst(
        "base = '';", "base = 'http://127.0.0.1:${server.port}';"));
    await source.load();
    return source;
  }

  test('登录闭环：login → token 持久化 → 章节/图片解锁 → 重启仍在', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final runtime = VeneraJsRuntime.instance;
    addTearDown(runtime.dispose);
    var source = await makeSource(runtime);
    expect(await source.hasAccount(), isTrue);
    expect(await source.isLogged(), isFalse, reason: '未登录');

    // 登录（夹具校验用户名/密码，写 token 进 save_data）。
    await source.login('user1', 'pass1');
    expect(await source.isLogged(), isTrue, reason: 'token 已持久化');

    // 章节：带 token 的请求被夹具放行 → 章节分组返回。
    final detail = await source.loadInfo('comic-1');
    expect(detail.title, '测试漫画');
    expect(detail.flatEpisodes, hasLength(1));
    expect(detail.flatEpisodes.first.title, '第1话');

    // 图片：带 token 解锁。
    final images = await source
        .loadEpImages('comic-1', detail.flatEpisodes.first.id)
        .timeout(const Duration(seconds: 20));
    expect(images, hasLength(2));
    expect(
        seenAuth.where((a) => a == 'Token T123').length,
        greaterThanOrEqualTo(2),
        reason: '章节与图片请求都带了登录 token');

    // 重启（dispose → 重载源 + store 重新落盘加载）：token 仍在。
    runtime.dispose();
    source = await makeSource(runtime);
    expect(await source.isLogged(), isTrue, reason: 'token 经 VeneraStore 落盘存活');
    final detail2 = await source.loadInfo('comic-1');
    expect(detail2.flatEpisodes, hasLength(1));

    // 登出：token 删除 → 章节端点回到 401。
    await source.logout();
    expect(await source.isLogged(), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
