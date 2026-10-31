// spider 源生态收口集成测试：ext 传递 → init(cfg) → playerContent 解析 →
// spiderJs 真探测。运行前置同 spider_synthetic_test（双 DLL + AQUAN_SPIDER_TESTS=1）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_probe.dart';
import 'package:aquan_duanju/core/sources/spider_js_adapter.dart';

import 'native_lib_guard.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => HttpOverrides.global = null);

  late HttpServer server;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      if (req.uri.path == '/spider.js') {
        req.response.headers.contentType =
            ContentType('application', 'javascript', charset: 'utf-8');
        req.response.write(r'''
var __cfg = {};
function init(cfg) {
  __cfg = cfg;
  return setResult({ok: true});
}
function home(filter) {
  return setResult({class: [
    {type_id: '1', type_name: '电影'},
    {type_id: '2', type_name: '短剧'}
  ], extSeen: __cfg.ext, skey: __cfg.skey});
}
function category(tid, pg, filter, extend) {
  return setResult({list: [
    {vod_id: tid + '-a', vod_name: '剧A', vod_remarks: '第1集'}
  ]});
}
function detail(ids) {
  return setResult({list: [{
    vod_id: ids[0],
    vod_name: '剧A',
    vod_play_from: '线路一',
    vod_play_url: '第1集$token-1#第2集$token-2'
  }]});
}
function playerContent(flag, id, vipFlags) {
  return setResult({parse: 0, url: 'http://cdn.example/' + id + '.m3u8'});
}
''');
        await req.response.close();
      } else {
        req.response.statusCode = 404;
        await req.response.close();
      }
    });
  });

  SpiderJsAdapter makeAdapter() {
    final config = SourceConfig(
      id: 's_js_test',
      name: '测试 JS 源',
      apis: ['http://127.0.0.1:${server.port}/spider.js'],
      kind: SourceKind.spiderJs,
      spiderKey: 'js_test_key',
      ext: '{"theme":"dark"}',
    );
    return SpiderJsAdapter(config);
  }

  test('init(cfg) 携带 api/skey/ext；home 可见 ext 原文', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final adapter = makeAdapter();
    final home = await adapter.categories();
    expect(home.map((c) => c.name), contains('短剧'));
    // init 是否真的收到 cfg：从 home 的回显里看（home 在 init 之后执行）。
    final raw = await adapter.homeRawForTest();
    expect(raw['extSeen'], '{"theme":"dark"}');
    expect(raw['skey'], 'js_test_key');
  });

  test('playerContent 二次解析：令牌 → 真实播放地址', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final adapter = makeAdapter();
    final url = await adapter.resolvePlayUrl(flag: '线路一', id: 'token-2');
    expect(url, 'http://cdn.example/token-2.m3u8');
  });

  test('probeSource(spiderJs)：下载 + home 探测给出时延与存活', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final config = SourceConfig(
      id: 's_js_probe',
      name: '测试 JS 源',
      apis: ['http://127.0.0.1:${server.port}/spider.js'],
      kind: SourceKind.spiderJs,
      ext: '{}',
    );
    final outcome = await probeSource(config);
    expect(outcome.state, ProbeState.ok, reason: outcome.reason);
    expect(outcome.latencyMs, isNotNull);
  });

  test('probeSource(spiderJs)：home 无分类 → failed 带原因', () async {
    if (!ensureFlutterQjsLibrary()) return;
    final config = SourceConfig(
      id: 's_js_bad',
      name: '坏 JS 源',
      apis: ['http://127.0.0.1:${server.port}/missing.js'],
      kind: SourceKind.spiderJs,
    );
    final outcome = await probeSource(config);
    expect(outcome.isOk, isFalse);
    expect(outcome.reason, isNotEmpty);
  });
}
