import '../error_log.dart';
import 'player_engine.dart';

/// mpv 请求头注入。
///
/// `Media(httpHeaders:)` 在部分平台/版本不会真正落到 libmpv 的 HTTP 请求上
/// （防盗链源表现为全源 403）。这里按三层补：
/// 1. mpv 原生 `http-header-fields` / `user-agent`；
/// 2. FFmpeg 层的 `demuxer-lavf-o`（HLS 分片与 `#EXT-X-KEY` 密钥请求由
///    libavformat 发起，不总读 mpv 的头）——与 `player_screen._prepareLavf`
///    同款写法；
/// 3. 一组经过项目验证的缓冲/重试参数。
///
/// 任何属性不被支持都静默忽略，绝不让「设属性失败」阻断播放；但会留一条
/// 诊断日志，避免「平台落空导致头注入完全失效」变成无法解释的黑洞。
abstract final class MpvHeaders {
  /// `--http-header-fields` 的值：`Name: Value` 用逗号分隔。
  ///
  /// 值内的逗号必须转义为 `\,`（mpv string-list 语法），不能改成 `%2C`——
  /// 默认 UA 里就有 `(KHTML, like Gecko)`，百分号编码会让源站收到畸形 UA。
  /// CR/LF 会破坏 HTTP 头，直接剔除；键里的冒号/逗号也去掉，避免注入额外字段。
  static String formatHttpHeaderFields(Map<String, String> headers) {
    if (headers.isEmpty) return '';
    final fields = <String>[];
    headers.forEach((name, value) {
      final key = name.replaceAll(RegExp(r'[\r\n:,]'), '').trim();
      final cleaned = value
          .replaceAll('\r\n', ' ')
          .replaceAll(RegExp(r'[\r\n]'), ' ')
          .replaceAll(',', r'\,')
          .trim();
      if (key.isEmpty || cleaned.isEmpty) return;
      fields.add('$key: $cleaned');
    });
    return fields.join(',');
  }

  /// 在 `open()` 之前调用；失败不影响后续播放。
  static Future<void> install(
    PlayerEngine engine,
    Map<String, String> headers,
  ) async {
    if (headers.isEmpty) return;
    final ua = _lookup(headers, 'user-agent');
    final referer = _lookup(headers, 'referer');

    final fields = formatHttpHeaderFields(headers);
    if (fields.isNotEmpty) {
      await _set(engine, 'http-header-fields', fields);
    }
    if (ua != null && ua.isNotEmpty) {
      await _set(engine, 'user-agent', ua);
    }

    // FFmpeg libavformat 拉 HLS 分片 / AES-128 密钥时读的是这里的 option，
    // 与 mpv 的 http-header-fields 是两条独立通路。只在确有防盗链头时设置，
    // 避免给不需要的源叠加一层无关 lavf 选项（会多出可忽略但扰人的错误）。
    final hasAntiLeech =
        (ua != null && ua.isNotEmpty) || (referer != null && referer.isNotEmpty);
    if (hasAntiLeech) {
      final lavf = <String>[
        'seg_max_retry=3',
        'strict=experimental',
        'allowed_extensions=ALL',
        'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
        if (ua != null && ua.isNotEmpty) 'user_agent=${_lavfValue(ua)}',
        if (referer != null && referer.isNotEmpty)
          'referer=${_lavfValue(referer)}',
      ];
      await _set(engine, 'demuxer-lavf-o', lavf.join(','));
    }

    // 与 player_screen._installMpvOptions 一致：慢源不至于秒退、HLS 可 seek。
    await _set(engine, 'network-timeout', '20');
    await _set(engine, 'cache', 'yes');
    await _set(engine, 'demuxer-max-bytes', '64MiB');
    await _set(engine, 'force-seekable', 'yes');

    await _verify(engine, fields);
  }

  static Future<void> _set(PlayerEngine engine, String name, String value) async {
    try {
      await engine.setProperty(name, value);
    } catch (_) {
      // 属性不可用时 Media(httpHeaders:) 仍是第一层保障。
    }
  }

  /// `setProperty` 在 platform 不是 NativePlayer 时静默什么都不做。回读一次，
  /// 让这种「 injections 全失效」的情况至少留一条可取证日志（只写一次）。
  static bool _warnedNoNative = false;

  static Future<void> _verify(PlayerEngine engine, String fields) async {
    if (fields.isEmpty || _warnedNoNative) return;
    try {
      final readBack = await engine.getProperty('http-header-fields');
      if (readBack == null) {
        _warnedNoNative = true;
        ErrorLog.instance.record(
          'mpv 头注入不可用',
          'Player.platform 不是 NativePlayer，Media(httpHeaders:) 为唯一保障',
          StackTrace.current,
        );
      }
    } catch (_) {}
  }

  /// lavf option 值里的逗号会截断 option 解析，反斜杠/换行同理。
  static String _lavfValue(String raw) => raw
      .replaceAll(RegExp(r'[\r\n]'), ' ')
      .replaceAll(',', '')
      .replaceAll('\\', '')
      .trim();

  /// 大小写不敏感取值：源配置里 `referer` / `REFERER` 同样生效。
  static String? _lookup(Map<String, String> headers, String wanted) {
    for (final entry in headers.entries) {
      if (entry.key.toLowerCase() == wanted) return entry.value;
    }
    return null;
  }
}
