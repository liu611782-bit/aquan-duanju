import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import 'wbi.dart';

/// B 站登录会话：web 扫码登录 + Cookie 持久化 + buvid3/bili_ticket 风控参数。
///
/// Cookie 文件存应用支持目录（凭据敏感，**不进备份白名单**）。
class BiliSession {
  BiliSession({http.Client? client})
      : _client = client ?? http.Client(),
        _wbiCache = WbiKeyCache();

  final http.Client _client;
  final WbiKeyCache _wbiCache;

  String? _sessdata;
  String? _biliJct;
  String? _dedeUserId;
  String? _buvid3;
  String? _buvid4;
  String? _biliTicket;
  DateTime _ticketAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isLoggedIn => (_sessdata ?? '').isNotEmpty;
  String? get sessdata => _sessdata;
  String? get biliJct => _biliJct;
  String? get buvid3 => _buvid3;
  String? get userId => _dedeUserId;

  static const _base = 'https://api.bilibili.com';
  static const _passport = 'https://passport.bilibili.com';

  /// 统一请求头：Cookie + 分域 Referer/UA（NativeWasmTv BlApi 同策略）。
  Map<String, String> headers({required String url}) {
    final isApi = url.startsWith(_passport);
    return {
      'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
              '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36',
      'Accept': 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      'Origin': 'https://www.bilibili.com',
      'Referer': isApi
          ? 'https://passport.bilibili.com/'
          : url.contains('/pgc/')
              ? 'https://www.bilibili.com/bangumi/'
              : 'https://www.bilibili.com/',
      if (isLoggedIn) 'Cookie': cookieHeader,
    };
  }

  String get cookieHeader => [
        if (_dedeUserId != null) 'DedeUserID=$_dedeUserId',
        if (_sessdata != null) 'SESSDATA=${Uri.encodeComponent(_sessdata!)}',
        if (_biliJct != null) 'bili_jct=${Uri.encodeComponent(_biliJct!)}',
        if (_buvid3 != null) 'buvid3=${Uri.encodeComponent(_buvid3!)}',
        if (_buvid4 != null) 'buvid4=${Uri.encodeComponent(_buvid4!)}',
        if (_biliTicket != null) 'bili_ticket=${Uri.encodeComponent(_biliTicket!)}',
      ].join('; ');

  // ---------- 持久化 ----------

  File? _file;

  Future<File> get _sessionFile async {
    if (_file != null) return _file!;
    final dir = await getApplicationSupportDirectory();
    _file = File(
        '${dir.path}${Platform.pathSeparator}aquan_bili_session.json');
    return _file!;
  }

  Future<void> load() async {
    try {
      final f = await _sessionFile;
      if (!await f.exists()) return;
      final json = jsonDecode(await f.readAsString());
      if (json is! Map) return;
      _sessdata = json['sessdata'] as String?;
      _biliJct = json['bili_jct'] as String?;
      _dedeUserId = json['dede_user_id'] as String?;
      _buvid3 = json['buvid3'] as String?;
      _buvid4 = json['buvid4'] as String?;
    } catch (_) {}
  }

  Future<void> _persist() async {
    try {
      final f = await _sessionFile;
      await f.writeAsString(jsonEncode({
        'sessdata': _sessdata,
        'bili_jct': _biliJct,
        'dede_user_id': _dedeUserId,
        'buvid3': _buvid3,
      }), flush: true);
    } catch (_) {}
  }

  // ---------- 扫码登录 ----------

  /// 生成登录二维码：返回 (二维码内容 url, qrcode_key)。
  Future<(String, String)> createQrLogin() async {
    final res = await _client
        .get(Uri.parse('$_passport/x/passport-login/web/qrcode/generate'),
            headers: headers(url: _passport))
        .timeout(const Duration(seconds: 10));
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map || json['data'] is! Map) {
      throw BiliException('二维码生成失败', detail: '${json['code']}');
    }
    final data = json['data'] as Map;
    return (data['url'] as String, data['qrcode_key'] as String);
  }

  /// 轮询扫码状态。
  ///
  /// 响应里有**两层** `code`：外层只表示接口是否成功（正常恒为 `0`），
  /// 真正的扫码状态在 `data.code`：
  /// `0`=登录成功（Cookies 在响应头/回调 url 里）、`86101`=未扫、
  /// `86090`=已扫未确认、`86038`=已过期。
  ///
  /// 早期版本读外层 `code`，第一次轮询（2 秒）就命中 0 被当成「登录成功」，
  /// 表现为二维码弹窗刚打开就自己消失。
  Future<BiliQrPoll> pollQrLogin(String qrcodeKey) async {
    final uri = Uri.parse(
        '$_passport/x/passport-login/web/qrcode/poll?qrcode_key=$qrcodeKey');
    final res = await _client.get(uri, headers: headers(url: _passport));
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map) return const BiliQrPoll(state: BiliQrState.failed);
    // 外层 code：接口层错误（风控 / 签名 / 参数），不是扫码状态。
    if ((json['code'] as int? ?? -1) != 0) {
      return const BiliQrPoll(state: BiliQrState.failed);
    }
    final data = json['data'];
    if (data is! Map) return const BiliQrPoll(state: BiliQrState.failed);
    switch (data['code'] as int? ?? -1) {
      case 0:
        final url = data['url'] as String? ?? '';
        // Cookie 三件套优先取响应头，其次从回调 url 的 query 兜底。
        final cookies = _extractCookies(res.headers['set-cookie']);
        _sessdata = cookies['SESSDATA'] ?? _cookieFromUrl(url, 'SESSDATA');
        _biliJct = cookies['bili_jct'] ?? _cookieFromUrl(url, 'bili_jct');
        _dedeUserId =
            cookies['DedeUserID'] ?? _cookieFromUrl(url, 'DedeUserID');
        await _persist();
        try {
          await fetchAccount(); // 顺带拉 nav 刷新 WBI key 与昵称。
        } catch (_) {}
        return BiliQrPoll(
          state: BiliQrState.confirmed,
          username: data['message']?.toString(),
        );
      case 86090:
        return const BiliQrPoll(state: BiliQrState.scanned);
      case 86038:
        return const BiliQrPoll(state: BiliQrState.expired);
      default:
        // 86101（未扫码）与其它未知状态都保持等待，不误判成功/过期。
        return const BiliQrPoll(state: BiliQrState.waiting);
    }
  }

  static Map<String, String> _extractCookies(String? setCookieHeader) {
    final out = <String, String>{};
    if (setCookieHeader == null) return out;
    // http 包把多个 set-cookie 合并成一行（逗号分隔），按 ; 分段再配对。
    for (final part in setCookieHeader.split(',')) {
      final seg = part.split(';').first.trim();
      final eq = seg.indexOf('=');
      if (eq <= 0) continue;
      final name = seg.substring(0, eq).trim();
      final value = seg.substring(eq + 1).trim();
      if (['SESSDATA', 'bili_jct', 'DedeUserID'].contains(name)) {
        out[name] = value;
      }
    }
    return out;
  }

  /// 兜底：部分实现把 Cookie 放进 redirect url 的 query。
  static String? _cookieFromUrl(String url, String name) {
    final uri = Uri.tryParse(url);
    return uri?.queryParameters[name];
  }

  /// 退出登录：调撤销接口并清本地。
  Future<void> logout() async {
    try {
      await _client.get(Uri.parse('$_passport/x/passport-login/web/cookie/revoke'),
          headers: headers(url: _passport));
    } catch (_) {}
    _sessdata = null;
    _biliJct = null;
    _dedeUserId = null;
    _biliTicket = null;
    await _persist();
  }

  // ---------- 用户信息 / 风控参数 ----------

  /// nav：昵称/头像/大会员状态 + WBI key（每日轮换）。
  Future<BiliAccount?> fetchAccount() async {
    final res = await _client
        .get(Uri.parse('$_base/x/web-interface/nav'), headers: headers(url: _base))
        .timeout(const Duration(seconds: 10));
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map) return null;
    final data = json['data'];
    if (data is Map) {
      final wbi = data['wbi_img'];
      if (wbi is Map &&
          wbi['img_url'] is String &&
          wbi['sub_url'] is String) {
        _wbiCache.update(
            WbiSigner.rawMixinKey(wbi['img_url'] as String, wbi['sub_url'] as String));
      }
      if (data['isLogin'] == true) {
        return BiliAccount(
          username: data['uname']?.toString() ?? '',
          avatarUrl: data['face']?.toString() ?? '',
          isVip: data['vipStatus'] == 1,
        );
      }
    }
    return null;
  }

  WbiKeyCache get wbiCache => _wbiCache;

  /// buvid3：未登录时也必须带（否则搜索/playurl 易 -352）。
  Future<void> ensureRiskParams() async {
    if ((_buvid3 ?? '').isEmpty) {
      try {
        final res = await _client
            .get(Uri.parse('$_base/x/frontend/finger/spi'),
                headers: headers(url: _base))
            .timeout(const Duration(seconds: 10));
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is Map && json['data'] is Map) {
          _buvid3 = (json['data']['b_3'] as String?) ?? _buvid3;
          _buvid4 = (json['data']['b_4'] as String?) ?? _buvid4;
        }
      } catch (_) {}
    }
    // bili_ticket：约 3 天有效，过期重取。
    final now = DateTime.now();
    if ((_biliTicket ?? '').isEmpty ||
        now.difference(_ticketAt) > const Duration(hours: 48)) {
      try {
        final ts = now.millisecondsSinceEpoch ~/ 1000;
        final hmac = Hmac(sha256, utf8.encode('XgwSnGZ1p'));
        final hexsign =
            hmac.convert(utf8.encode('ts$ts')).toString();
        final res = await _client
            .post(Uri.parse('$_base/x/bili-ticket/ticket/gen'),
                headers: {
                  ...headers(url: _base),
                  'Content-Type': 'application/x-www-form-urlencoded',
                },
                body: {
                  'key_id': 'ec02',
                  'hexsign': hexsign,
                  'csrf': _biliJct ?? '',
                  'ts': '$ts',
                })
            .timeout(const Duration(seconds: 10));
        final json = jsonDecode(utf8.decode(res.bodyBytes));
        if (json is Map && json['data'] is Map) {
          _biliTicket = json['data']['ticket'] as String?;
          _ticketAt = now;
        }
      } catch (_) {}
    }
    if ((_buvid3 ?? '').isNotEmpty || (_biliTicket ?? '').isNotEmpty) {
      await _persist();
    }
  }

  /// API 层共用出口：带 Cookie/csrf 的表单 POST（弹幕发送等写操作）。
  Future<Map<String, dynamic>> postForm(String path, Map<String, String> form) async {
    final uri = Uri.parse('https://api.bilibili.com$path');
    final res = await _client.post(uri,
        headers: {
          ...headers(url: 'https://www.bilibili.com/'),
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: form)
        .timeout(const Duration(seconds: 15));
    final json = jsonDecode(utf8.decode(res.bodyBytes));
    if (json is! Map) {
      throw BiliException('响应结构异常', detail: path);
    }
    return json.cast<String, dynamic>();
  }

  /// API 层共用出口：带 Cookie/Referer/UA 的 GET，返回原始字节。
  Future<Uint8List> request(Uri uri) async {
    final res = await _client
        .get(uri, headers: headers(url: uri.toString()))
        .timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      throw BiliException('网络错误 HTTP ${res.statusCode}', detail: uri.path);
    }
    return res.bodyBytes;
  }

  void close() => _client.close();
}

class BiliAccount {
  const BiliAccount({
    required this.username,
    required this.avatarUrl,
    this.isVip = false,
  });
  final String username;
  final String avatarUrl;
  final bool isVip;
}

enum BiliQrState { waiting, scanned, confirmed, expired, failed }

class BiliQrPoll {
  const BiliQrPoll({required this.state, this.username});
  final BiliQrState state;
  final String? username;
}

class BiliException implements Exception {
  BiliException(this.message, {this.code = 0, this.detail = ''});
  final String message;
  final int code;
  final String detail;

  @override
  String toString() => detail.isEmpty ? message : '$message ($detail)';
}
