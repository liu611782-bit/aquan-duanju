import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'cast_media_proxy.dart';
import '../sources/qr_share_server.dart';

/// 二维码 / 局域网网页投屏句柄。
///
/// [url] 即给电视/手机浏览器打开的完整页面地址：
/// `http://<lan-ip>:<port>/w/<token>`。
class WebCastHandle {
  const WebCastHandle({
    required this.url,
    required this.port,
    required this.token,
  });

  final String url;
  final int port;
  final String token;
}

/// 标准 DLNA 无响应时的兜底：起一个局域网 HTTP 服务，返回一个自带
/// `<video>` 的网页，用二维码 / 手输地址让接收端浏览器自己播放。
///
/// 复用 [QrShareServer.lanIP] 的选路策略（192.168 > 10 > 172，跳过
/// loopback / link-local）与 site-local 来源校验；非 site-local 请求一律 403。
///
/// 与 [QrShareServer] 一样用 `dart:io` [HttpServer]——这里伺服的是 HTML 页面，
/// 不是媒体字节，不存在 HEAD 上 `Content-Length` 被归零的问题（那是
/// `LocalMediaServer` 必须手写 ServerSocket 的原因）。
///
/// 带防盗链 headers 的流交给 [CastMediaProxy]（同目录的局域网流式代理，绑定
/// anyIPv4、支持 HLS 清单改写与 Range 透传，本次同步补了 CORS 响应头）。
/// 没有用 `MediaProxy.instance.wrap`：那个代理绑的是 127.0.0.1 且是去广告用途，
/// 电视浏览器拿到回环地址会指向电视自己；注册失败则退回原始直链并在页面注明。
class WebCastService {
  WebCastService({
    this.defaultPort = 18390,
    this.portAttempts = 20,
    this.hostOverride,
    this.remoteChecker,
    this.ttl = defaultTtl,
  });

  static final WebCastService _singleton = WebCastService();

  static WebCastService get instance => _singleton;

  /// 页面 / token 有效期。
  static const Duration defaultTtl = Duration(minutes: 30);

  /// 起始端口；被占用时逐个 +1 降级。
  final int defaultPort;
  final int portAttempts;

  /// 测试注入点：跳过局域网地址探测（CI 上常拿不到私网地址）。
  final String? hostOverride;

  /// 测试注入点：覆盖 site-local 来源判定，用于模拟非内网来源。
  final bool Function(InternetAddress address)? remoteChecker;

  final Duration ttl;

  HttpServer? _server;
  Timer? _ttlTimer;
  String? _token;
  List<int>? _pageBytes;
  DateTime _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
  WebCastHandle? _handle;
  CastMediaProxy? _proxy;

  bool get running => _server != null;
  int? get port => _server?.port;

  /// 当前有效句柄；未启动或已 stop 时为 null。
  WebCastHandle? get current => _handle;

  /// 启动（会先停掉上一次会话）。失败返回 null（拿不到私网地址 / 端口全被占）。
  Future<WebCastHandle?> start({
    required String url,
    required String title,
    Map<String, String> headers = const {},
  }) async {
    await stop();

    // 拿不到私网地址时不退回 127.0.0.1（本地媒体服务同款约束）：
    // 回环地址对接收端浏览器没有意义。测试用 hostOverride 绕过。
    final host = hostOverride ?? await QrShareServer.lanIP();
    if (host.isEmpty || (hostOverride == null && host == '127.0.0.1')) {
      return null;
    }

    HttpServer? server;
    for (var i = 0; i < portAttempts; i++) {
      try {
        server = await HttpServer.bind(InternetAddress.anyIPv4, defaultPort + i);
        break;
      } on SocketException {
        continue; // 端口占用 → 顺延
      }
    }
    if (server == null) return null;

    final token = _randomToken();
    // isHls 必须按原始 url 判定：代理改写后的地址是 /p/<token>，不含 .m3u8。
    final isHls = _looksLikeHls(url);
    var videoSrc = url;
    var proxied = false;
    if (headers.isNotEmpty) {
      CastMediaProxy? proxy;
      try {
        proxy = CastMediaProxy(hostOverride: host);
        final wrapped = await proxy.register(url, headers: headers);
        if (wrapped != null) {
          videoSrc = wrapped;
          proxied = true;
          _proxy = proxy;
        }
      } catch (_) {
        // 代理起不来 → 原始直链 + 页面注明，不把异常透给用户。
        proxied = false;
      }
      if (!proxied) {
        try {
          await proxy?.stop();
        } catch (_) {}
      }
    }

    final page = _buildPage(
      title: title.isEmpty ? '投屏播放' : title,
      src: videoSrc,
      isHls: isHls,
      proxied: proxied,
      headersNeeded: headers.isNotEmpty,
      host: host,
      port: server.port,
      token: token,
    );
    _server = server;
    _token = token;
    _pageBytes = utf8.encode(page);
    _expiresAt = DateTime.now().add(ttl);
    final handle = WebCastHandle(
      url: 'http://$host:${server.port}/w/$token',
      port: server.port,
      token: token,
    );
    _handle = handle;

    server.listen((req) async {
      try {
        await _handleRequest(req);
      } catch (_) {
        try {
          await req.response.close();
        } catch (_) {}
      }
    }, onError: (Object _) {});
    _ttlTimer?.cancel();
    _ttlTimer = Timer(ttl, () => unawaited(stop()));
    return handle;
  }

  /// 停止并释放端口（幂等）。TTL 到点、面板 dispose、重新 start 都会走这里。
  Future<void> stop() async {
    _ttlTimer?.cancel();
    _ttlTimer = null;
    final server = _server;
    final proxy = _proxy;
    _server = null;
    _proxy = null;
    _token = null;
    _pageBytes = null;
    _handle = null;
    _expiresAt = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      await server?.close(force: true);
    } catch (_) {}
    try {
      await proxy?.stop();
    } catch (_) {}
  }

  Future<void> _handleRequest(HttpRequest req) async {
    final remote = req.connectionInfo?.remoteAddress;
    final checker = remoteChecker ?? _defaultRemoteChecker;
    if (remote == null || !checker(remote)) {
      req.response.statusCode = HttpStatus.forbidden;
      await req.response.close();
      return;
    }
    if (DateTime.now().isAfter(_expiresAt)) {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    final token = _token;
    if (token == null || req.uri.path != '/w/$token') {
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
      return;
    }
    if (req.method != 'GET' && req.method != 'HEAD') {
      req.response.statusCode = HttpStatus.methodNotAllowed;
      await req.response.close();
      return;
    }
    req.response.headers.contentType =
        ContentType('text', 'html', charset: 'utf-8');
    req.response.headers.set('Cache-Control', 'no-store');
    req.response.headers.set('Access-Control-Allow-Origin', '*');
    if (req.method == 'HEAD') {
      await req.response.close();
      return;
    }
    final bytes = _pageBytes;
    if (bytes != null) req.response.add(bytes);
    await req.response.close();
  }

  static final Random _random = Random.secure();

  /// SecureRandom 24B base64Url（去 padding = 32 字符），与本地媒体服务同款。
  static String _randomToken() {
    final bytes =
        List<int>.generate(24, (_) => _random.nextInt(256), growable: false);
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static bool _looksLikeHls(String url) => url.toLowerCase().contains('.m3u8');

  /// 与 `QrShareServer._isSiteLocal` 同源：允许 loopback（本机/单测）+ site-local
  /// IPv4。选中本机对外 IP 时跳过 loopback/link-local 是 lanIP() 的职责，两处不冲突。
  static bool _defaultRemoteChecker(InternetAddress addr) {
    if (addr.isLoopback) return true;
    if (addr.type != InternetAddressType.IPv4) return false;
    final ip = addr.address;
    return ip.startsWith('192.168.') ||
        ip.startsWith('10.') ||
        ip.startsWith('169.254.') ||
        RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
  }

  static String _buildPage({
    required String title,
    required String src,
    required bool isHls,
    required bool proxied,
    required bool headersNeeded,
    required String host,
    required int port,
    required String token,
  }) {
    // jsonEncode 生成合法 JS 字符串字面量；再转义 < > &，防止 URL 里的
    // `</script>` 提前闭合脚本块（用户可见文案不外泄原始异常）。
    final jsSrc = jsonEncode(src)
        .replaceAll('<', r'\u003C')
        .replaceAll('>', r'\u003E')
        .replaceAll('&', r'\u0026');
    final note = headersNeeded
        ? (proxied
            ? '该视频需要本机代理转发，请保持阿圈短剧在前台或后台运行。'
            : '该视频可能需要防盗链请求头，当前使用原始直链；若无法播放，请点击「用系统播放器打开」。')
        : '若播放失败，请检查网络或点击「用系统播放器打开」。';
    final addr = 'http://$host:$port/w/$token';
    final values = <String, String>{
      'TITLE': const HtmlEscape().convert(title),
      'SRC': jsSrc,
      'IS_HLS': isHls ? 'true' : 'false',
      'NOTE': const HtmlEscape().convert(note),
      'ADDR': const HtmlEscape().convert(addr),
    };
    return _pageTemplate.replaceAllMapped(
      RegExp(r'__([A-Z_]+)__'),
      (m) => values[m.group(1)] ?? m.group(0)!,
    );
  }

  static const String _pageTemplate = r'''
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>__TITLE__ · 网页投屏</title>
<style>
:root{color-scheme:dark}
*{box-sizing:border-box}
body{margin:0;background:#0f1115;color:#f2f4f8;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif}
.wrap{max-width:960px;margin:0 auto;padding:24px 16px 40px}
.tag{display:inline-block;padding:4px 12px;border-radius:999px;background:#1f6feb22;color:#79b8ff;font-size:13px;letter-spacing:.5px}
h1{font-size:22px;margin:14px 0 6px;font-weight:600;word-break:break-all}
.sub{margin:0 0 20px;color:#9aa4b2;font-size:14px}
.player{position:relative;background:#000;border-radius:14px;overflow:hidden;box-shadow:0 12px 40px #0008}
video{display:block;width:100%;max-height:70vh;background:#000;outline:none}
.fallback{position:absolute;inset:0;display:none;align-items:center;justify-content:center;text-align:center;padding:24px;background:#000d;color:#e6edf3;font-size:16px;line-height:1.8}
.err{display:none;margin:12px 0 0;padding:10px 14px;border-radius:10px;background:#3b1d1d;color:#ffb4b4;font-size:14px}
.bar{display:flex;flex-wrap:wrap;gap:10px;margin-top:16px}
button,.btn{appearance:none;border:1px solid #30363d;background:#21262d;color:#f2f4f8;padding:10px 20px;border-radius:10px;font-size:15px;cursor:pointer;text-decoration:none;line-height:1.4}
button:hover,.btn:hover{background:#30363d}
button.primary{background:#1f6feb;border-color:#1f6feb}
button.primary:hover{background:#388bfd}
.tip,.addr,.foot{color:#9aa4b2;font-size:13px;line-height:1.7;margin:14px 0 0;word-break:break-all}
.foot{margin-top:24px;text-align:center;color:#6e7681}
</style>
</head>
<body>
<div class="wrap">
  <div class="tag">网页投屏</div>
  <h1>__TITLE__</h1>
  <p class="sub">在同一局域网内用浏览器打开本页即可播放</p>
  <div class="player">
    <video id="v" controls playsinline webkit-playsinline preload="metadata"></video>
    <div id="fallback" class="fallback">当前浏览器无法直接播放该视频流，请点击下方「用系统播放器打开」。</div>
  </div>
  <div id="err" class="err">播放失败，请检查网络或改用系统播放器打开。</div>
  <div class="bar">
    <button id="play" class="primary">播放</button>
    <button id="full">全屏</button>
    <a id="open" class="btn" href="#" target="_blank" rel="noopener">用系统播放器打开</a>
  </div>
  <p class="tip">__NOTE__</p>
  <p class="addr">页面地址：__ADDR__</p>
  <p class="foot">本页 30 分钟后自动失效 · 阿圈短剧</p>
</div>
<script>
(function(){
  var v=document.getElementById('v');
  var src=__SRC__;
  var isHls=__IS_HLS__;
  document.getElementById('open').href=src;
  var nativeHls=v.canPlayType('application/vnd.apple.mpegurl')!==''||
      v.canPlayType('application/x-mpegURL')!==''||
      v.canPlayType('vnd.apple.mpegurl')!=='';
  if(!isHls||nativeHls){v.src=src;}
  else{document.getElementById('fallback').style.display='flex';}
  document.getElementById('play').addEventListener('click',function(){
    if(!v.src){v.src=src;document.getElementById('fallback').style.display='none';}
    var p=v.play();if(p&&p.catch){p.catch(function(){});}
  });
  document.getElementById('full').addEventListener('click',function(){
    if(v.requestFullscreen){v.requestFullscreen();}
    else if(v.webkitEnterFullscreen){v.webkitEnterFullscreen();}
    else if(v.webkitRequestFullscreen){v.webkitRequestFullscreen();}
  });
  v.addEventListener('error',function(){document.getElementById('err').style.display='block';});
})();
</script>
</body>
</html>
''';
}
