// 合成 CatVod 爬虫全链路测试：本地 HTTP 夹具 + catvod JS（req/pdfa/pdfh/setResult）
// 经 QuickJS 运行时跑 home/category/detail/search 四接口。
// 运行前置：flutter build windows --debug 后把 runner/Debug 加入 PATH。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/spider_js_runtime.dart';

import 'native_lib_guard.dart';

const _spiderJs = r'''
var base = '';
function home(filter) {
  return setResult({class: [
    {type_id: '1', type_name: '电影'},
    {type_id: '2', type_name: '短剧'}
  ]});
}
function category(tid, pg, filter, extend) {
  var html = req({url: base + '/list?tid=' + tid + '&pg=' + pg, method: 'get'}).body;
  var names = pdfa(html, '.item&&span&&Text');
  var list = [];
  for (var i = 0; i < names.length; i++) {
    list.push({vod_id: tid + '/' + i, vod_name: names[i], vod_remarks: '第' + (i + 1) + '集'});
  }
  return setResult({list: list});
}
function detail(ids) {
  var id = ids[0];
  var parts = id.split('/');
  return setResult({list: [{
    vod_id: id,
    vod_name: '剧' + parts[0] + '-' + parts[1],
    vod_play_from: '线路一$$$线路二',
    vod_play_url: '第1集$http://e/1.m3u8#第2集$http://e/2.m3u8$$$线路二第1集$http://f/1.m3u8'
  }]});
}
function search(wd, quick) {
  var html = req({url: base + '/search?wd=' + encodeURIComponent(wd)}).body;
  var name = pdfh(html, '.hit&&.title&&Text');
  return setResult({list: [{vod_id: '9/0', vod_name: name, vod_play_url: '第1集$http://e/9.m3u8'}]});
}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // flutter_test 的 binding 会把 HttpClient 替换成「一律 400」的 mock；
  // 本测试跑真实本地 HTTP 夹具，必须恢复真实实现。
  setUp(() => HttpOverrides.global = null);

  test('合成爬虫全链路：home → category(req+pdfa) → detail → search(req+pdfh)',
      () async {
    // 没有 QuickJS 原生桥就跳过（flutter test 是纯 Dart VM，加载不了插件原生库）。
    if (!ensureFlutterQjsLibrary()) return;
    // 本地夹具服务器。
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      final path = req.uri.path;
      req.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      if (path == '/list') {
        final tid = req.uri.queryParameters['tid'] ?? '0';
        req.response.write('''
<html><body>
<div class="item"><span>影片$tid-A</span></div>
<div class="item"><span>影片$tid-B</span></div>
<div class="item"><span>影片$tid-C</span></div>
</body></html>''');
      } else if (path == '/search') {
        // queryParameters 已解码；再 decodeQueryComponent 会把正常中文
        // 判成非法百分号（双重解码，本次端到端联调抓出）。
        final wd = req.uri.queryParameters['wd'] ?? '';
        req.response.write(
            '<html><body><div class="hit"><p class="title">$wd 的结果</p></div></body></html>');
      } else {
        req.response.statusCode = 404;
      }
      await req.response.close();
    });

    // 把 base 注入 JS（fixture 参数化）。
    final js = _spiderJs.replaceFirst("var base = '';", "var base = '$base';");
    final runtime = SpiderJsRuntime.instance;
    addTearDown(runtime.dispose);

    // home：分类列表。
    final home = await runtime.call(js, 'home', [false]);
    final classes = home['class'] as List;
    expect(classes.length, 2);
    expect((classes[1] as Map)['type_name'], '短剧');

    // category：req + pdfa 列表。
    final cat = await runtime.call(js, 'category', ['1', 1, true, {}]);
    final list = cat['list'] as List;
    expect(list.length, 3);
    expect((list.first as Map)['vod_name'], '影片1-A');
    expect((list.first as Map)['vod_remarks'], '第1集');

    // detail：播放串。
    final detail = await runtime.call(js, 'detail', [['1/0']]);
    final d0 = (detail['list'] as List).first as Map;
    expect(d0['vod_name'], '剧1-0');
    expect(d0['vod_play_from'], contains('线路一'));

    // search：req + pdfh。
    final search = await runtime.call(js, 'search', ['三体', false]);
    final s0 = (search['list'] as List).first as Map;
    expect(s0['vod_name'], '三体 的结果');

  }, timeout: const Timeout(Duration(minutes: 3)));
}
