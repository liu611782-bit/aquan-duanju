// FongmiSpiderAdapter 口味分发集成测试：FongMi 短名源（__JS_SPIDER__）与
// CatVod 长名源（setResult）同走 SourceKind.spiderJs，各自全链。
// 运行前置同 spider（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_adapter_factory.dart';

import 'native_lib_guard.dart';

const _fongmiJs = r'''
var base = '';
function home(filter) {
  var r = req(base + '/home');
  var data = JSON.parse(r.body);
  return JSON.stringify({class: data.classes});
}
function category(tid, pg, filter, extend) {
  var r = req(base + '/list?tid=' + tid);
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
  return JSON.stringify({list: [{vod_id: id, vod_name: data.name, vod_play_from: '线1', vod_play_url: '第1集$' + data.play}]});
}
function play(flag, id, vipFlags) {
  return JSON.stringify({parse: 0, url: id});
}
globalThis.__JS_SPIDER__ = {home: home, category: category, detail: detail, play: play};
''';

const _catvodJs = r'''
function homeContent(filter) {
  return JSON.stringify({class: [{type_id: '1', type_name: '电影'}]});
}
function categoryContent(tid, pg, filter, extend) {
  setResult({list: [{vod_id: 'c1', vod_name: '长名影片', vod_play_from: '线1', vod_play_url: '第1集$http://x/1.m3u8'}]});
}
''';

SourceConfig _config(String url) => SourceConfig(
      id: 's_smoke',
      name: '口味分发夹具',
      apis: [url],
      kind: SourceKind.spiderJs,
      spiderKey: 'smoke_key',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  late String mode;
  setUp(() async {
    mode = 'fongmi';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      if (req.uri.path == '/spider.js') {
        req.response.headers.contentType =
            ContentType('application', 'javascript', charset: 'utf-8');
        req.response.write(mode == 'fongmi'
            ? _fongmiJs.replaceFirst("var base = '';",
                "var base = 'http://127.0.0.1:${server.port}';")
            : _catvodJs);
        await req.response.close();
        return;
      }
      if (mode == 'fongmi') {
        req.response.headers.contentType = ContentType.json;
        if (req.uri.path == '/home') {
          req.response.write(jsonEncode({
            'classes': [
              {'type_id': '1', 'type_name': '电影'},
            ],
          }));
        } else if (req.uri.path == '/list') {
          req.response.write(jsonEncode({
            'items': [
              {'id': 'f1', 'name': '短名影片', 'pic': ''},
            ],
          }));
        } else if (req.uri.path == '/detail') {
          req.response.write(jsonEncode({
            'name': '短名影片',
            'play': 'http://cdn.example/f.m3u8',
          }));
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  Future<SourceAdapter> makeAdapter() async {
    final config = _config('http://127.0.0.1:${server.port}/spider.js');
    final adapter = buildSourceAdapter(config)!;
    // 触发取源（口味检测）。
    await adapter.categories();
    return adapter;
  }

  test('FongMi 口味：categories/list/detail 全链（短名 + 同步 req）', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final adapter = await makeAdapter();
    final cats = await adapter.categories();
    expect(cats.map((c) => c.name), contains('电影'));

    final page = await adapter.list(categoryId: '1', page: 1);
    expect(page.items, hasLength(1));
    expect(page.items.first.title, '短名影片');

    final series = await adapter.detail('f1');
    expect(series.title, '短名影片');
    expect(series.defaultLine!.episodes.first.url,
        'http://cdn.example/f.m3u8');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('CatVod 口味：setResult 长名源仍走原路径', () async {
    if (!ensureFlutterQjsLibrary()) return;
    mode = 'catvod';
    final adapter = await makeAdapter();
    final cats = await adapter.categories();
    // ignore: avoid_print
    print('catvod cats → $cats');
    expect(cats.map((c) => c.name), contains('电影'));
    final page = await adapter.list(categoryId: '1', page: 1);
    expect(page.items.first.title, '长名影片');
    expect(page.items.first.defaultLine!.episodes.first.url,
        'http://x/1.m3u8');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
