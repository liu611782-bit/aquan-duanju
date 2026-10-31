// FongMi 引擎集成测试：后台 isolate + 同步 req（阻塞 FFI）+ 短名方法调用 +
// 模块加载器（ES import 经 moduleHandler 网络抓取）。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
// 注意：AquaNew 需 Go 核心库（aquan_core.dll），与 quickjs DLL 并存加载。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/fongmi/fongmi_spider_runtime.dart';

import 'native_lib_guard.dart';

const _spiderJs = r'''
var base = '';
function init(ext) { globalThis.__ext = ext; }
function home(filter) {
  var r = req(base + '/home');
  var data = JSON.parse(r.body);
  return JSON.stringify({class: data.classes});
}
function category(tid, pg, filter, extend) {
  var r = req(base + '/list?tid=' + tid + '&pg=' + pg);
  var data = JSON.parse(r.body);
  var list = [];
  for (var i = 0; i < data.items.length; i++) {
    list.push({vod_id: data.items[i].id, vod_name: data.items[i].name, vod_pic: data.items[i].pic});
  }
  return JSON.stringify({list: list});
}
function detail(id) {
  var r = req(base + '/detail?id=' + id);
  var data = JSON.parse(r.body);
  return JSON.stringify({list: [{vod_id: id, vod_name: data.name, vod_play_from: '线1', vod_play_url: '第1集$' + data.play + '#第2集$' + data.play2}]});
}
function search(kw, quick) {
  var r = req(base + '/search?wd=' + encodeURIComponent(kw));
  var data = JSON.parse(r.body);
  return JSON.stringify({list: data.items});
}
function play(flag, id, vipFlags) {
  return JSON.stringify({parse: 0, url: id});
}
globalThis.__JS_SPIDER__ = {init: init, home: home, category: category, detail: detail, search: search, play: play};
''';

// 模块加载器夹具：spider 以 ES import 引入相对模块。
const _moduleSpiderJs = r'''
import * as lib from './lib.js';
var base = '';
function home(filter) {
  var r = req(base + '/home');
  var data = JSON.parse(r.body);
  return JSON.stringify({class: data.classes, tag: lib.decorate('x')});
}
globalThis.__JS_SPIDER__ = {home: home};
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/lib.js') {
        req.response.headers.contentType =
            ContentType('application', 'javascript');
        req.response.write('export function decorate(n) { return "mod-" + n; }');
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      if (path == '/home') {
        req.response.write(jsonEncode({
          'classes': [
            {'type_id': '1', 'type_name': '电影'},
            {'type_id': '2', 'type_name': '短剧'},
          ],
        }));
      } else if (path == '/list') {
        req.response.write(jsonEncode({
          'items': [
            {'id': 'v1', 'name': '影片A', 'pic': 'http://p/1.jpg'},
            {'id': 'v2', 'name': '影片B', 'pic': 'http://p/2.jpg'},
          ],
        }));
      } else if (path == '/detail') {
        req.response.write(jsonEncode({
          'name': '影片A',
          'play': 'http://cdn.example/1.m3u8',
          'play2': 'http://cdn.example/2.m3u8',
        }));
      } else if (path == '/search') {
        req.response.write(jsonEncode({
          'items': [
            {'id': 's1', 'name': '搜索结果', 'pic': ''},
          ],
        }));
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });
  });

  String makeJs() => _spiderJs.replaceFirst(
      "var base = '';", "var base = 'http://127.0.0.1:${server.port}';");

  Future<String> httpJs() => rootBundle.loadString('assets/fongmi/http.js');

  test('FongMi 全链：home → category → detail → play（同步 req）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final profile =
        '${Directory.systemTemp.path}/fongmi_profile_${DateTime.now().millisecondsSinceEpoch}.json';
    final js = await httpJs();

    final home = await FongmiSpiderRuntime.call(
      jsSource: makeJs(),
      method: 'home',
      args: [false],
      httpJs: js,
      profilePath: profile,
    );
    // ignore: avoid_print
    print('home → $home');
    expect((home['class'] as List), hasLength(2));

    final category = await FongmiSpiderRuntime.call(
      jsSource: makeJs(),
      method: 'category',
      args: ['1', 1, true, <String, String>{}],
      httpJs: js,
      profilePath: profile,
    );
    final list = category['list'] as List;
    // ignore: avoid_print
    print('category → ${list.length} 项');
    expect(list, hasLength(2));
    expect((list.first as Map)['vod_name'], '影片A');

    final detail = await FongmiSpiderRuntime.call(
      jsSource: makeJs(),
      method: 'detail',
      args: ['v1'],
      httpJs: js,
      profilePath: profile,
    );
    // ignore: avoid_print
    print('detail → ${(detail['list'] as List).length}');
    expect((detail['list'] as List).first['vod_play_url'], contains('1.m3u8'));

    final play = await FongmiSpiderRuntime.call(
      jsSource: makeJs(),
      method: 'play',
      args: ['线1', 'http://cdn.example/1.m3u8', <String>[]],
      httpJs: js,
      profilePath: profile,
    );
    expect(play['url'], 'http://cdn.example/1.m3u8');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('FongMi 搜索', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final profile =
        '${Directory.systemTemp.path}/fongmi_profile_${DateTime.now().millisecondsSinceEpoch}.json';
    final js = await httpJs();
    final hits = await FongmiSpiderRuntime.call(
      jsSource: makeJs(),
      method: 'search',
      args: ['海贼', false],
      httpJs: js,
      profilePath: profile,
    );
    expect((hits['list'] as List), hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('FongMi 模块加载器：ES import 相对模块（网络抓取）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final profile =
        '${Directory.systemTemp.path}/fongmi_profile_${DateTime.now().millisecondsSinceEpoch}.json';
    final result = await FongmiSpiderRuntime.call(
      jsSource: _moduleSpiderJs.replaceFirst(
          "var base = '';", "var base = 'http://127.0.0.1:${server.port}';"),
      method: 'home',
      args: [false],
      httpJs: await httpJs(),
      sourceUrl: 'http://127.0.0.1:${server.port}/spider.js',
      profilePath: profile,
    );
    // ignore: avoid_print
    print('module home → $result');
    expect((result['class'] as List), hasLength(2));
    expect(result['tag'], 'mod-x',
        reason: 'ES import 模块应经 moduleHandler 抓取并生效');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
