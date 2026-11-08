import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/cast/cast_profile.dart';
import '../core/cast/cast_recipe.dart';
import '../core/cast/cast_target.dart';
import '../core/castd/receiver_descriptions.dart' show uuidV4;
import '../core/reader/reader_settings.dart';
import '../core/reader/reader_theme.dart';
import '../core/player/playback_health.dart';
import '../core/reader/reader_annotations.dart';
import '../core/reader/replace_rules.dart';
import '../core/sources/merged_source.dart';
import '../core/sources/source_adapter.dart';
import '../core/sources/source_discovery.dart';
import '../core/sources/source_health.dart';
import '../core/sources/source_probe.dart';
import '../core/sources/source_import.dart';
import '../core/sources/source_seed.dart';
import '../models/models.dart';
import '../models/play_skip.dart';

/// 设置项（shared_preferences 持久化）。
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

  // 主题：system / light / dark
  String get themeMode => _prefs.getString('theme.mode') ?? 'system';
  set themeMode(String v) {
    _prefs.setString('theme.mode', v);
    notifyListeners();
  }

  // 默认清晰度：best / worst / 720p / 1080p …
  String get defaultQuality => _prefs.getString('player.quality') ?? 'best';
  set defaultQuality(String v) {
    _prefs.setString('player.quality', v);
    notifyListeners();
  }

  /// 播放音量（0-100），退出播放器时保存、启动时恢复。
  double get volume => _prefs.getDouble('player.volume') ?? 100.0;
  set volume(double v) {
    _prefs.setDouble('player.volume', v);
  }

  /// 离线缓存清晰度：默认 540p 省空间（全剧缓存体积约为 1080p 的一半）。
  /// Venera 漫画源 JS 地址（发现页漫画源入口）。
  String get veneraSourceUrl => _prefs.getString('venera.sourceUrl') ?? '';

  set veneraSourceUrl(String v) => _prefs.setString('venera.sourceUrl', v);

  /// 源市场扫描并发度（种子级 worker 池宽）。默认 12：IO 密集，
  /// 顺序扫十几分钟的活并发下缩到一分多钟；源站不稳时可调低。
  int get scanConcurrency => _prefs.getInt('market.scanConcurrency') ?? 12;

  set scanConcurrency(int v) =>
      _prefs.setInt('market.scanConcurrency', v.clamp(1, 64));

  String get cacheQuality => _prefs.getString('download.quality') ?? '540p';
  set cacheQuality(String v) {
    _prefs.setString('download.quality', v);
    notifyListeners();
  }

  // 默认倍速（字符串存，便于 UI 下拉）。
  String get defaultSpeed => _prefs.getString('player.speed') ?? '1.0';
  set defaultSpeed(String v) {
    _prefs.setString('player.speed', v);
    notifyListeners();
  }

  // 自动连播下一集。
  bool get autoNext => _prefs.getBool('player.autoNext') ?? true;
  set autoNext(bool v) {
    _prefs.setBool('player.autoNext', v);
    notifyListeners();
  }

  /// 电视模式：`auto`（检测）/ `on`（强制）/ `off`（关闭）。
  ///
  /// 运行形态只在启动时解析一次，改完需要重启应用才生效（避免运行中布局跳变）。
  String get tvMode => _prefs.getString('ui.tvMode') ?? 'auto';
  set tvMode(String v) {
    _prefs.setString('ui.tvMode', v);
    notifyListeners();
  }

  /// 听书：朗读推进时自动跟随高亮段（翻页跳转 / 滚动跟随）。
  bool get listenFollow => _prefs.getBool('listen.follow') ?? true;
  set listenFollow(bool v) {
    _prefs.setBool('listen.follow', v);
    notifyListeners();
  }

  /// 听书：显示当前朗读段落的高亮。
  bool get listenHighlight => _prefs.getBool('listen.highlight') ?? true;
  set listenHighlight(bool v) {
    _prefs.setBool('listen.highlight', v);
    notifyListeners();
  }

  // 随机播放：从第 1 集开始（红果随机看的语义）。
  bool get randomFromFirst => _prefs.getBool('random.fromFirst') ?? true;
  set randomFromFirst(bool v) {
    _prefs.setBool('random.fromFirst', v);
    notifyListeners();
  }

  // 桌面端：打开视频时把窗口调成片源比例（竖屏剧竖着看）。
  bool get autoFitWindow => _prefs.getBool('player.autoFitWindow') ?? true;
  set autoFitWindow(bool v) {
    _prefs.setBool('player.autoFitWindow', v);
    notifyListeners();
  }

  // 桌面端：播放器处于迷你置顶小窗时，窗口尺寸变化不落盘（还原后再记）。
  bool get miniWindowActive => _prefs.getBool('win.mini') ?? false;
  set miniWindowActive(bool v) {
    _prefs.setBool('win.mini', v);
  }

  // Windows 窗口记忆（仅桌面端使用）。
  String? get windowBounds => _prefs.getString('win.bounds');
  set windowBounds(String? v) {
    if (v == null) {
      _prefs.remove('win.bounds');
    } else {
      _prefs.setString('win.bounds', v);
    }
  }

  // ---------- 第三方影视源（TVBox / CMS） ----------

  /// 聚合搜索并发源数（1–8，默认 4）。
  int get searchParallelism =>
      (_prefs.getInt('search.parallelism') ?? 4).clamp(1, 8);
  set searchParallelism(int v) {
    _prefs.setInt('search.parallelism', v.clamp(1, 8));
    notifyListeners();
  }

  /// 聚合搜索单源超时（3000–10000ms，默认 5000）。
  int get searchTimeoutMs =>
      (_prefs.getInt('search.timeoutMs') ?? 5000).clamp(3000, 10000);
  set searchTimeoutMs(int v) {
    _prefs.setInt('search.timeoutMs', v.clamp(3000, 10000));
    notifyListeners();
  }

  /// CMS 源播放走本地去广告代理（默认关）。
  ///
  /// 默认直链最稳：部分源的加密 HLS 密钥分片、带时效 query 的分片经本地
  /// 代理重写后会 403。需要剔除广告时由用户显式开启，播放失败会自动回退直链。
  bool get sourcesAdFilter => _prefs.getBool('sources.adFilter') ?? false;
  set sourcesAdFilter(bool v) {
    _prefs.setBool('sources.adFilter', v);
    notifyListeners();
  }

  /// 源测速单源超时（默认 8000ms）。
  int get sourcesProbeTimeoutMs =>
      _prefs.getInt('sources.probeTimeoutMs') ?? 8000;
  set sourcesProbeTimeoutMs(int v) {
    _prefs.setInt('sources.probeTimeoutMs', v.clamp(3000, 30000));
    notifyListeners();
  }

  /// 「内容由第三方提供」免责提示不再显示。
  bool get sourcesDisclaimerDismissed =>
      _prefs.getBool('sources.disclaimerDismissed') ?? false;
  set sourcesDisclaimerDismissed(bool v) {
    _prefs.setBool('sources.disclaimerDismissed', v);
    notifyListeners();
  }

  /// 自动找源：后台从 GitHub / GitLab / Gitee 发现并验证配置。
  bool get autoDiscovery => _prefs.getBool('sources.autoDiscovery') ?? true;
  set autoDiscovery(bool v) {
    _prefs.setBool('sources.autoDiscovery', v);
    notifyListeners();
  }

  /// GitHub Token（可选）：留空按匿名调用，限流更早但可用。
  String get githubToken => _prefs.getString('sources.githubToken') ?? '';
  set githubToken(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) {
      _prefs.remove('sources.githubToken');
    } else {
      _prefs.setString('sources.githubToken', trimmed);
    }
    notifyListeners();
  }

  /// 自动找源间隔（分钟，15–360，默认 60）：成功后的下一轮等待时间。
  int get autoSourceIntervalMinutes =>
      (_prefs.getInt('sources.autoDiscoveryIntervalMin') ?? 60).clamp(15, 360);
  set autoSourceIntervalMinutes(int v) {
    _prefs.setInt('sources.autoDiscoveryIntervalMin', v.clamp(15, 360));
    notifyListeners();
  }

  /// 找源成功后自动重建本地合并源（默认开）。
  bool get autoMergeSources => _prefs.getBool('sources.autoMerge') ?? true;
  set autoMergeSources(bool v) {
    _prefs.setBool('sources.autoMerge', v);
    notifyListeners();
  }

  /// 进入影视聚合时随机选一个直连源（默认开）。
  bool get randomHomeSource => _prefs.getBool('sources.randomHome') ?? true;
  set randomHomeSource(bool v) {
    _prefs.setBool('sources.randomHome', v);
    notifyListeners();
  }

  /// 聚合/快速搜索按「后端」去重（默认开）。
  bool get dedupeBackendSearch =>
      _prefs.getBool('sources.dedupeBackend') ?? true;
  set dedupeBackendSearch(bool v) {
    _prefs.setBool('sources.dedupeBackend', v);
    notifyListeners();
  }

  /// 详情页显示「换源」入口（默认开）。
  bool get detailSourceSwitch =>
      _prefs.getBool('sources.detailSwitch') ?? true;
  set detailSourceSwitch(bool v) {
    _prefs.setBool('sources.detailSwitch', v);
    notifyListeners();
  }

  /// 启动后自动检查更新（默认开；仍受运维急停约束）。
  bool get autoCheckUpdate => _prefs.getBool('update.autoCheck') ?? true;
  set autoCheckUpdate(bool v) {
    _prefs.setBool('update.autoCheck', v);
    notifyListeners();
  }

  /// 更新清单地址（英文逗号分隔，依次尝试）。空 = 用内置默认地址。
  String get updateUrls => _prefs.getString('update.urls') ?? '';
  set updateUrls(String v) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) {
      _prefs.remove('update.urls');
    } else {
      _prefs.setString('update.urls', trimmed);
    }
    notifyListeners();
  }

  List<String> get updateUrlList => updateUrls
      .split(',')
      .map((u) => u.trim())
      .where((u) => u.isNotEmpty)
      .toList(growable: false);

  // ---------- 语音输入（桌面云 API） ----------

  /// OpenAI 兼容 transcriptions 端点（如 https://api.groq.com/openai/v1）。
  String? get voiceBaseUrl => _prefs.getString('voice.baseUrl');
  set voiceBaseUrl(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('voice.baseUrl');
    } else {
      _prefs.setString('voice.baseUrl', v);
    }
    notifyListeners();
  }

  String? get voiceApiKey => _prefs.getString('voice.apiKey');
  set voiceApiKey(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('voice.apiKey');
    } else {
      _prefs.setString('voice.apiKey', v);
    }
    notifyListeners();
  }

  /// 模型留空用端点默认。
  String? get voiceModel => _prefs.getString('voice.model');
  set voiceModel(String? v) {
    if (v == null || v.isEmpty) {
      _prefs.remove('voice.model');
    } else {
      _prefs.setString('voice.model', v);
    }
    notifyListeners();
  }

  bool get voiceDesktopConfigured =>
      (voiceBaseUrl ?? '').isNotEmpty && (voiceApiKey ?? '').isNotEmpty;

  // ---------- B 站弹幕 ----------

  /// 弹幕屏蔽词（逗号分隔，包含匹配）。
  String get biliDanmakuBlock => _prefs.getString('bili.danmakuBlock') ?? '';
  set biliDanmakuBlock(String v) {
    _prefs.setString('bili.danmakuBlock', v);
    notifyListeners();
  }

  Set<String> get biliDanmakuBlockWords => biliDanmakuBlock
      .split(RegExp(r'[,，]'))
      .map((w) => w.trim())
      .where((w) => w.isNotEmpty)
      .toSet();

  // ---------- 投屏（DLNA） ----------

  /// 断开投屏后的行为：resumeLocal（回本地续播，默认）/ stopOnly（仅停止）。
  String get castDisconnectBehavior =>
      _prefs.getString('cast.disconnectBehavior') ?? 'resumeLocal';
  set castDisconnectBehavior(String v) {
    _prefs.setString('cast.disconnectBehavior', v);
    notifyListeners();
  }

  /// 接收端开关（「允许其他设备投到本机」，默认关；仅桌面暴露）。
  bool get castReceiverEnabled => _prefs.getBool('cast.receiverEnabled') ?? false;
  set castReceiverEnabled(bool v) {
    _prefs.setBool('cast.receiverEnabled', v);
    notifyListeners();
  }

  /// 接收端名称（空 = 默认「<主机名>（aquan 接收）」）。
  String get castReceiverName => _prefs.getString('cast.receiverName') ?? '';
  set castReceiverName(String v) {
    _prefs.setString('cast.receiverName', v);
    notifyListeners();
  }

  /// 接收端准入模式三值（11-07-cast-receiver-advanced R1.1）：anyone（默认，
  /// 现状）/ ask（每次询问）/ whitelist（仅允许列表）。文案单一来源在
  /// receiver_admission.dart 的 `receiverAdmissionModeLabel`。
  static const List<String> castReceiverAdmissionValues = [
    'anyone',
    'ask',
    'whitelist',
  ];

  String get castReceiverAdmissionMode {
    final v = _prefs.getString('cast.receiverAdmissionMode') ?? 'anyone';
    return castReceiverAdmissionValues.contains(v) ? v : 'anyone';
  }

  set castReceiverAdmissionMode(String v) {
    _prefs.setString('cast.receiverAdmissionMode',
        castReceiverAdmissionValues.contains(v) ? v : 'anyone');
    notifyListeners();
  }

  /// 记住的允许设备名单（JSON 数组 `[{ip,ua,at}]`；空串 = 无）。运行态由
  /// 准入策略管理，这里只做落盘/读出（进备份白名单，随备份走）。
  String get castReceiverAllowIps =>
      _prefs.getString('cast.receiverAllowIps') ?? '';

  set castReceiverAllowIps(String v) {
    if (v.isEmpty) {
      _prefs.remove('cast.receiverAllowIps');
    } else {
      _prefs.setString('cast.receiverAllowIps', v);
    }
    notifyListeners();
  }

  /// 记住的拒绝设备名单（「每次询问」勾了记住的拒绝，JSON 同上）。
  String get castReceiverDenyIps =>
      _prefs.getString('cast.receiverDenyIps') ?? '';

  set castReceiverDenyIps(String v) {
    if (v.isEmpty) {
      _prefs.remove('cast.receiverDenyIps');
    } else {
      _prefs.setString('cast.receiverDenyIps', v);
    }
    notifyListeners();
  }

  /// 中继转码画质档位（R2 画质三档）：high（高清）/ balanced（均衡，现状
  /// 参数）/ compact（省流）。全局记忆，随备份走；非法值回落 balanced
  /// （与 Go 侧空/未知值缺省口径一致）。
  static const List<String> castRelayQualityValues = [
    'high',
    'balanced',
    'compact',
  ];

  /// 面板三选的固定文案（下标与 [castRelayQualityValues] 对齐）。
  static const Map<String, String> castRelayQualityLabels = {
    'high': '高清',
    'balanced': '均衡',
    'compact': '省流',
  };

  String get castRelayQuality {
    final v = _prefs.getString('cast.relayQuality') ?? 'balanced';
    return castRelayQualityValues.contains(v) ? v : 'balanced';
  }

  set castRelayQuality(String v) {
    _prefs.setString('cast.relayQuality',
        castRelayQualityValues.contains(v) ? v : 'balanced');
    notifyListeners();
  }

  // ---------- 播放器高级设置（带白名单 / 范围校验） ----------

  /// 默认硬解方式：拷回（copy）路径。
  ///
  /// 零拷贝直通（旧默认 `auto-safe` / `d3d11va`）在 Windows + ANGLE 下，解码纹理
  /// 按 16 像素对齐（1080 → 1088），多出的列/行不会被裁掉，YUV 未写入区域经色彩
  /// 转换后是绿色：竖屏片源在画面右侧留一条绿竖条，横屏片源在底部留一条绿横条。
  /// 拷回模式拿到的已是裁剪后的帧，因此作为默认值。
  static const String defaultHwdecMode = 'auto-copy';

  static const List<String> hwdecValues = [
    'auto-copy',
    'd3d11va-copy',
    'd3d11va',
    'dxva2',
    'nvdec',
    'cuda',
    'no',
  ];

  static const Map<String, String> hwdecLabels = {
    'auto-copy': '自动（推荐）',
    'd3d11va-copy': 'D3D11VA 拷回模式',
    'd3d11va': 'D3D11VA 直通（可能绿边）',
    'dxva2': 'DXVA2（旧显卡）',
    'nvdec': 'NVIDIA NVDEC',
    'cuda': 'NVIDIA CUDA',
    'no': '软件解码',
  };

  static const List<String> scaleValues = ['fit', 'fill', '16:9', '4:3'];
  static const Map<String, String> scaleLabels = {
    'fit': '适应窗口',
    'fill': '填充',
    '16:9': '强制 16:9',
    '4:3': '强制 4:3',
  };

  static const List<int> historyLimitOptions = [50, 100, 150, 200, 300, 500];

  static const int minHistoryLimit = 10;
  static const int maxHistoryLimit = 9999;
  static const int minCacheSecs = 5;
  static const int maxCacheSecs = 300;
  static const int minAudioDelayMs = -5000;
  static const int maxAudioDelayMs = 5000;

  static int normalizeHistoryLimit(int v) =>
      (v < minHistoryLimit || v > maxHistoryLimit) ? 150 : v;

  /// 硬解方式：Windows/macOS/Linux 可调；Android 固定 mediacodec（见播放器）。
  ///
  /// 旧版本的 `auto-safe`（零拷贝直通）已从可选值中移除：读到它时回落到
  /// [defaultHwdecMode]，让存量配置（含旧备份恢复）不再出现画面绿边。
  String get hwdecMode {
    final v = _prefs.getString('player.hwdec') ?? defaultHwdecMode;
    return hwdecValues.contains(v) ? v : defaultHwdecMode;
  }

  set hwdecMode(String v) {
    _prefs.setString(
        'player.hwdec', hwdecValues.contains(v) ? v : defaultHwdecMode);
    notifyListeners();
  }

  /// 网络缓冲时长（秒），写入 mpv 的 cache-secs。
  int get cacheSecs =>
      (_prefs.getInt('player.cacheSecs') ?? 30).clamp(minCacheSecs, maxCacheSecs);

  set cacheSecs(int v) {
    _prefs.setInt('player.cacheSecs', v.clamp(minCacheSecs, maxCacheSecs));
    notifyListeners();
  }

  /// 音画同步偏置（毫秒，正值表示音频延后）。
  int get audioDelayMs => (_prefs.getInt('player.audioDelayMs') ?? 0)
      .clamp(minAudioDelayMs, maxAudioDelayMs);

  set audioDelayMs(int v) {
    _prefs.setInt(
        'player.audioDelayMs', v.clamp(minAudioDelayMs, maxAudioDelayMs));
    notifyListeners();
  }

  String get scale {
    final v = _prefs.getString('player.scale') ?? 'fit';
    return scaleValues.contains(v) ? v : 'fit';
  }

  set scale(String v) {
    _prefs.setString('player.scale', scaleValues.contains(v) ? v : 'fit');
    notifyListeners();
  }

  /// 离线下载目录（空 = 应用数据目录下的 downloads）。
  /// 机器相关路径，不进入备份。
  String? get downloadDir {
    final v = _prefs.getString('download.dir')?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  set downloadDir(String? v) {
    final text = v?.trim() ?? '';
    if (text.isEmpty) {
      _prefs.remove('download.dir');
    } else {
      _prefs.setString('download.dir', text);
    }
    notifyListeners();
  }

  /// 下载限速（KB/s，0 = 不限速）。
  static const List<int> downloadSpeedOptions = [0, 256, 512, 1024, 2048, 5120];

  /// 同时下载数（1–3）。
  static const List<int> downloadConcurrencyOptions = [1, 2, 3];

  int get downloadConcurrency =>
      (_prefs.getInt('download.concurrency') ?? 1).clamp(1, 3);

  set downloadConcurrency(int v) {
    _prefs.setInt('download.concurrency', v.clamp(1, 3));
    notifyListeners();
  }

  /// 失败自动重试次数（0–3）。
  static const List<int> downloadRetryOptions = [0, 1, 2, 3];

  int get downloadRetries =>
      (_prefs.getInt('download.retries') ?? 0).clamp(0, 3);

  set downloadRetries(int v) {
    _prefs.setInt('download.retries', v.clamp(0, 3));
    notifyListeners();
  }

  int get downloadSpeedKbps =>
      (_prefs.getInt('download.speedKbps') ?? 0).clamp(0, 102400);

  set downloadSpeedKbps(int v) {
    _prefs.setInt('download.speedKbps', v.clamp(0, 102400));
    notifyListeners();
  }

  /// 字幕字号（mpv sub-font-size）。
  static const List<int> subtitleFontSizeOptions = [36, 42, 48, 56, 64];

  int get subtitleFontSize =>
      (_prefs.getInt('subtitle.fontSize') ?? 48).clamp(24, 96);

  set subtitleFontSize(int v) {
    _prefs.setInt('subtitle.fontSize', v.clamp(24, 96));
    notifyListeners();
  }

  bool get subtitleBorder => _prefs.getBool('subtitle.border') ?? true;
  set subtitleBorder(bool v) {
    _prefs.setBool('subtitle.border', v);
    notifyListeners();
  }

  bool get subtitleBackground =>
      _prefs.getBool('subtitle.background') ?? false;
  set subtitleBackground(bool v) {
    _prefs.setBool('subtitle.background', v);
    notifyListeners();
  }

  /// 片头片尾跳过总开关。
  bool get skipIntroOutro => _prefs.getBool('player.skipIntroOutro') ?? true;
  set skipIntroOutro(bool v) {
    _prefs.setBool('player.skipIntroOutro', v);
    notifyListeners();
  }

  /// 历史记录保留条数。
  int get historyLimit =>
      normalizeHistoryLimit(_prefs.getInt('history.limit') ?? 150);

  set historyLimit(int v) {
    _prefs.setInt('history.limit', normalizeHistoryLimit(v));
    notifyListeners();
  }

  /// 可携带到其它设备的设置（备份用）；窗口位置 / 迷你窗状态等本机状态除外。
  Map<String, dynamic> exportBackup() => {
        'theme.mode': themeMode,
        'player.quality': defaultQuality,
        'player.speed': defaultSpeed,
        'player.volume': volume,
        'player.autoNext': autoNext,
        'ui.tvMode': tvMode,
        'random.fromFirst': randomFromFirst,
        'player.autoFitWindow': autoFitWindow,
        'download.quality': cacheQuality,
        'download.speedKbps': downloadSpeedKbps,
        'download.concurrency': downloadConcurrency,
        'download.retries': downloadRetries,
        'history.limit': historyLimit,
        'player.hwdec': hwdecMode,
        'player.cacheSecs': cacheSecs,
        'player.audioDelayMs': audioDelayMs,
        'player.scale': scale,
        'player.skipIntroOutro': skipIntroOutro,
        'subtitle.fontSize': subtitleFontSize,
        'subtitle.border': subtitleBorder,
        'subtitle.background': subtitleBackground,
        // 影视聚合的「效果开关」：随备份走，避免换设备后行为不一致。
        'sources.autoDiscovery': autoDiscovery,
        'sources.autoDiscoveryIntervalMin': autoSourceIntervalMinutes,
        'sources.autoMerge': autoMergeSources,
        'sources.randomHome': randomHomeSource,
        'sources.dedupeBackend': dedupeBackendSearch,
        'sources.detailSwitch': detailSourceSwitch,
        'update.urls': updateUrls,
        'update.autoCheck': autoCheckUpdate,
        // 投屏中继画质三档（R2）：随备份走，换设备后行为一致。
        'cast.relayQuality': castRelayQuality,
        // 接收端准入（11-07-cast-receiver-advanced）：模式 + 记住的名单
        // 随备份走，换设备后准入行为一致。
        'cast.receiverAdmissionMode': castReceiverAdmissionMode,
        'cast.receiverAllowIps': castReceiverAllowIps,
        'cast.receiverDenyIps': castReceiverDenyIps,
      };

  /// 从备份恢复设置：未知键忽略、非法值回落默认，返回实际写入的键数。
  int importBackup(Map<String, dynamic> data) {
    var applied = 0;
    void apply(String key, void Function() write) {
      if (!data.containsKey(key)) return;
      write();
      applied++;
    }

    apply('theme.mode', () {
      final v = data['theme.mode'];
      if (v is String && const ['system', 'light', 'dark'].contains(v)) {
        themeMode = v;
      }
    });
    apply('player.quality', () {
      final v = data['player.quality'];
      if (v is String && v.isNotEmpty) defaultQuality = v;
    });
    apply('player.speed', () {
      final v = data['player.speed'];
      if (v is String && double.tryParse(v) != null) defaultSpeed = v;
    });
    apply('player.volume', () {
      final v = data['player.volume'];
      if (v is num) volume = v.toDouble().clamp(0, 100);
    });
    apply('player.autoNext', () {
      final v = data['player.autoNext'];
      if (v is bool) autoNext = v;
    });
    apply('ui.tvMode', () {
      final v = data['ui.tvMode'];
      if (v is String && const {'auto', 'on', 'off'}.contains(v)) tvMode = v;
    });
    apply('random.fromFirst', () {
      final v = data['random.fromFirst'];
      if (v is bool) randomFromFirst = v;
    });
    apply('player.autoFitWindow', () {
      final v = data['player.autoFitWindow'];
      if (v is bool) autoFitWindow = v;
    });
    apply('download.quality', () {
      final v = data['download.quality'];
      if (v is String && v.isNotEmpty) cacheQuality = v;
    });
    apply('download.speedKbps', () {
      final v = data['download.speedKbps'];
      if (v is num) downloadSpeedKbps = v.toInt();
    });
    apply('download.concurrency', () {
      final v = data['download.concurrency'];
      if (v is num) downloadConcurrency = v.toInt();
    });
    apply('download.retries', () {
      final v = data['download.retries'];
      if (v is num) downloadRetries = v.toInt();
    });
    apply('history.limit', () {
      final v = data['history.limit'];
      if (v is num) historyLimit = v.toInt();
    });
    apply('player.hwdec', () {
      final v = data['player.hwdec'];
      if (v is String && hwdecValues.contains(v)) hwdecMode = v;
    });
    apply('player.cacheSecs', () {
      final v = data['player.cacheSecs'];
      if (v is num) cacheSecs = v.toInt();
    });
    apply('player.audioDelayMs', () {
      final v = data['player.audioDelayMs'];
      if (v is num) audioDelayMs = v.toInt();
    });
    apply('player.scale', () {
      final v = data['player.scale'];
      if (v is String && scaleValues.contains(v)) scale = v;
    });
    apply('player.skipIntroOutro', () {
      final v = data['player.skipIntroOutro'];
      if (v is bool) skipIntroOutro = v;
    });
    apply('subtitle.fontSize', () {
      final v = data['subtitle.fontSize'];
      if (v is num) subtitleFontSize = v.toInt();
    });
    apply('subtitle.border', () {
      final v = data['subtitle.border'];
      if (v is bool) subtitleBorder = v;
    });
    apply('subtitle.background', () {
      final v = data['subtitle.background'];
      if (v is bool) subtitleBackground = v;
    });
    apply('sources.autoDiscovery', () {
      final v = data['sources.autoDiscovery'];
      if (v is bool) autoDiscovery = v;
    });
    apply('sources.autoDiscoveryIntervalMin', () {
      final v = data['sources.autoDiscoveryIntervalMin'];
      if (v is num) autoSourceIntervalMinutes = v.toInt();
    });
    apply('sources.autoMerge', () {
      final v = data['sources.autoMerge'];
      if (v is bool) autoMergeSources = v;
    });
    apply('sources.randomHome', () {
      final v = data['sources.randomHome'];
      if (v is bool) randomHomeSource = v;
    });
    apply('sources.dedupeBackend', () {
      final v = data['sources.dedupeBackend'];
      if (v is bool) dedupeBackendSearch = v;
    });
    apply('sources.detailSwitch', () {
      final v = data['sources.detailSwitch'];
      if (v is bool) detailSourceSwitch = v;
    });
    apply('update.urls', () {
      final v = data['update.urls'];
      if (v is String) updateUrls = v;
    });
    apply('update.autoCheck', () {
      final v = data['update.autoCheck'];
      if (v is bool) autoCheckUpdate = v;
    });
    apply('cast.relayQuality', () {
      final v = data['cast.relayQuality'];
      if (v is String && castRelayQualityValues.contains(v)) {
        castRelayQuality = v;
      }
    });
    apply('cast.receiverAdmissionMode', () {
      final v = data['cast.receiverAdmissionMode'];
      if (v is String && castReceiverAdmissionValues.contains(v)) {
        castReceiverAdmissionMode = v;
      }
    });
    apply('cast.receiverAllowIps', () {
      final v = data['cast.receiverAllowIps'];
      if (v is String) castReceiverAllowIps = v;
    });
    apply('cast.receiverDenyIps', () {
      final v = data['cast.receiverDenyIps'];
      if (v is String) castReceiverDenyIps = v;
    });
    return applied;
  }
}

/// 观看历史的一条记录（语义对齐 openhongguo internal/history.Entry）。
class HistoryEntry {
  HistoryEntry({
    required this.seriesId,
    this.title = '',
    this.coverUrl = '',
    this.episode = 1,
    this.episodes = 0,
    this.finished = false,
    this.position = 0,
    this.episodeId = '',
    this.playUrl = '',
    this.speed = 0,
    this.quality = '',
    this.sourceKey = '',
    this.subtitleDelayMs,
    this.audioTrackIndex,
    this.subtitleTrackIndex,
    this.audioTrackKey = '',
    this.subtitleTrackKey = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String seriesId;
  final String title;
  final String coverUrl;
  final int episode;
  final int episodes;
  final bool finished;
  final double position;
  final String episodeId;

  /// 上次实际播放的直链：详情接口挂掉时用它兜底「继续播放」。
  final String playUrl;

  /// 这部剧的播放偏好：speed 为 0 表示没改过倍速；quality 为空表示用全局默认。
  final double speed;
  final String quality;

  /// 字幕时差按剧记忆（毫秒；null = 未设置）。mpv sub-delay 语义。
  final int? subtitleDelayMs;

  /// 轨道选择按剧记忆（Pathfin ContinuousTrackSelection）：
  /// 面板展示序的同类下标；字幕 -1 = 关闭字幕；null = 未设置。
  final int? audioTrackIndex;
  final int? subtitleTrackIndex;

  /// 轨道稳定身份键（language|title 归一化；空 = 无名轨/未设置）。
  /// 参考实现教训：轨道编号跨集不稳定，键唯一命中才自动套用。
  final String audioTrackKey;
  final String subtitleTrackKey;

  /// 内容来源：空 = 红果（旧数据兼容）；否则为源 id 或 'bili'。
  final String sourceKey;
  DateTime updatedAt;

  /// 正片进度达到该比例即视为「看完」，不再提示继续播放。
  static const double finishedThreshold = 0.95;

  /// 可续播的最小进度（秒）：看几秒就退出不该出现在「继续观看」里。
  static const double resumableMinSeconds = 15;

  /// 是否值得提示「继续观看」。
  bool get resumable => !finished && position >= resumableMinSeconds;

  /// 按进度比例判定是否看完；时长未知（<=0）时返回 false，交给调用方决定。
  static bool shouldMarkFinished(
    double positionSeconds,
    double durationSeconds,
  ) =>
      durationSeconds > 0 &&
      positionSeconds / durationSeconds >= finishedThreshold;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'title': title,
        'cover_url': coverUrl,
        'episode': episode,
        'episodes': episodes,
        'finished': finished,
        'position': position,
        'episode_id': episodeId,
        if (playUrl.isNotEmpty) 'play_url': playUrl,
        if (speed > 0) 'speed': speed,
        if (quality.isNotEmpty) 'quality': quality,
        if (sourceKey.isNotEmpty) 'source_key': sourceKey,
        if (subtitleDelayMs != null) 'subtitle_delay_ms': subtitleDelayMs,
        if (audioTrackIndex != null) 'audio_track_index': audioTrackIndex,
        if (subtitleTrackIndex != null) 'subtitle_track_index': subtitleTrackIndex,
        if (audioTrackKey.isNotEmpty) 'audio_track_key': audioTrackKey,
        if (subtitleTrackKey.isNotEmpty) 'subtitle_track_key': subtitleTrackKey,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory HistoryEntry.fromJson(Map<String, dynamic> json) => HistoryEntry(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episode: json['episode'] as int? ?? 1,
        episodes: json['episodes'] as int? ?? 0,
        finished: json['finished'] as bool? ?? false,
        position: (json['position'] as num?)?.toDouble() ?? 0,
        episodeId: json['episode_id'] as String? ?? '',
        playUrl: json['play_url'] as String? ?? '',
        speed: (json['speed'] as num?)?.toDouble() ?? 0,
        quality: json['quality'] as String? ?? '',
        sourceKey: json['source_key'] as String? ?? '',
        subtitleDelayMs: (json['subtitle_delay_ms'] as num?)?.toInt(),
        audioTrackIndex: (json['audio_track_index'] as num?)?.toInt(),
        subtitleTrackIndex: (json['subtitle_track_index'] as num?)?.toInt(),
        audioTrackKey: json['audio_track_key'] as String? ?? '',
        subtitleTrackKey: json['subtitle_track_key'] as String? ?? '',
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 追剧状态。
enum FollowState { want, watching, watched }

/// 追剧的一条记录。
class FollowEntry {
  FollowEntry({
    required this.seriesId,
    this.title = '',
    this.coverUrl = '',
    this.episodeCount = 0,
    int? latestEpisodeCount,
    this.state = FollowState.watching,
    DateTime? updatedAt,
  })  : latestEpisodeCount = latestEpisodeCount ?? episodeCount,
        updatedAt = updatedAt ?? DateTime.now();

  final String seriesId;
  final String title;
  final String coverUrl;
  final int episodeCount;

  /// 最近一次从服务端看到的集数；大于 [episodeCount] 即有更新。
  final int latestEpisodeCount;
  final FollowState state;
  DateTime updatedAt;

  /// 追剧的剧有新集（服务端集数多于追剧时的记录）。
  bool get hasUpdate => latestEpisodeCount > episodeCount;

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'title': title,
        'cover_url': coverUrl,
        'episode_count': episodeCount,
        'latest_episode_count': latestEpisodeCount,
        'state': state.name,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory FollowEntry.fromJson(Map<String, dynamic> json) => FollowEntry(
        seriesId: json['series_id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeCount: json['episode_count'] as int? ?? 0,
        latestEpisodeCount: json['latest_episode_count'] as int?,
        state: FollowState.values.firstWhere(
          (s) => s.name == json['state'],
          orElse: () => FollowState.watching,
        ),
        updatedAt:
            DateTime.tryParse(json['updated_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 本地 JSON 文件存储的基类：原子写（tmp+rename），读失败当空。
abstract class _JsonFileStore extends ChangeNotifier {
  _JsonFileStore(this._fileName, {this.testDirectory});

  /// 测试注入点：不给就落到应用支持目录（生产路径不变）。
  final Directory? testDirectory;

  final String _fileName;
  File? _file;
  bool _loaded = false;

  /// 写盘串行队列：播放进度、退出保存、备份恢复可能并发触发写盘，
  /// 共用同一个 `.tmp` 路径时并发写会互相覆盖；在这里统一排队。
  Future<void> _writeQueue = Future<void>.value();

  Future<File> get _fileFuture async {
    if (_file != null) return _file!;
    final dir = testDirectory ?? await getApplicationSupportDirectory();
    _file = File('${dir.path}${Platform.pathSeparator}$_fileName');
    return _file!;
  }

  Future<Map<String, dynamic>> _readJson() async {
    try {
      final f = await _fileFuture;
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      if (raw.isEmpty) return {};
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _writeJson(Map<String, dynamic> json) {
    final encoded = jsonEncode(json);
    final task = _writeQueue.then((_) async {
      final f = await _fileFuture;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(f.path);
    });
    _writeQueue = task.catchError((_) {});
    return task;
  }

  /// 读改写一体串行（R3，11-07-cast-reliability）：把「读现有键 → [update]
  /// 合并 → 原子写」整体放进 [_writeQueue] 执行。此前只有写入本身入队，
  /// 读在队列外——并发混合写（轮询进度落盘 × 面板改配方/画像/接收端 UDN
  /// 等）时各写者的 `existing` 都是旧磁盘快照，后落盘者会把中间写入的键
  /// 抹掉（真实丢键，cast_store_concurrency_test 复现）。读入队后，顺序
  /// 行为与旧版逐字节一致，并发不再丢键。[update] 在任务执行时调用，
  /// 读到的内存状态也是最新值；返回 null = 无变化不写盘（保持旧语义）。
  Future<void> _updateJson(
    Map<String, dynamic>? Function(Map<String, dynamic> existing) update,
  ) {
    final task = _writeQueue.then((_) async {
      final existing = await _readJson();
      final next = update(existing);
      if (next == null) return;
      final encoded = jsonEncode(next);
      final f = await _fileFuture;
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      await tmp.rename(f.path);
    });
    _writeQueue = task.catchError((_) {});
    return task;
  }

  Future<void>? _loadingFuture;

  Future<void> ensureLoaded() {
    if (_loaded) return Future<void>.value();
    // 单飞：并发 record/import 时只加载一次，避免两个 loadFromDisk
    // 互相 clear，把刚写入的条目覆盖掉。
    return _loadingFuture ??= loadFromDisk().whenComplete(() {
      _loadingFuture = null;
    });
  }

  @protected
  Future<void> loadFromDisk();

  @protected
  Future<void> persist(Map<String, dynamic> json);

  /// 备份导出用的原始数据。
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return _readJson();
  }

  /// 从备份 JSON 合并恢复：按 series_id，updatedAt 较新者胜。
  /// 返回合并进来的条数。
  Future<int> importData(Map<String, dynamic> incoming) async => 0;
}

/// 观看历史：series_id → 记录，最近更新在前。
class HistoryStore extends _JsonFileStore {
  HistoryStore({super.testDirectory}) : super('aquan_history.json');

  static const int defaultLimit = 150;
  static const int minLimit = 1;
  static const int maxLimit = 9999;

  final Map<String, HistoryEntry> _entries = {};
  int _limit = defaultLimit;

  /// 保留条数（超出后淘汰最旧记录）。
  int get limit => _limit;

  set limit(int v) {
    _limit = (v < minLimit || v > maxLimit) ? defaultLimit : v;
  }

  /// 单部剧的记录（没有返回 null）。
  HistoryEntry? entry(String seriesId) => _entries[seriesId];

  List<HistoryEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  HistoryEntry? get(String seriesId) => _entries[seriesId];

  /// 调整上限并立即裁剪 / 落盘。
  Future<void> applyLimit(int v) async {
    limit = v;
    await ensureLoaded();
    if (_prune() > 0) await _flush();
  }

  /// 超出上限时淘汰最旧记录，返回删除条数。
  int _prune() {
    if (_entries.length <= _limit) return 0;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final keep = ordered.take(_limit).map((e) => e.key).toSet();
    final before = _entries.length;
    _entries.removeWhere((k, _) => !keep.contains(k));
    return before - _entries.length;
  }

  /// 全量写盘（历史条目整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：文档仍由内存态构建，入队后与其它
  /// 写者串行，并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        _entries[k] = HistoryEntry.fromJson(v);
      }
    });
    final pruned = _prune();
    _loaded = true;
    if (pruned > 0) {
      await _writeJson({
        for (final e in _entries.entries) e.key: e.value.toJson(),
      });
    }
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 播放器每 5 秒/暂停/退出时调用。
  Future<void> record({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episode,
    required int episodes,
    required String episodeId,
    required double position,
    bool? finished,
    double durationSeconds = 0,
    double speed = 0,
    String quality = '',
    String sourceKey = '',
    String playUrl = '',
  }) async {
    await ensureLoaded();
    final existing = _entries[seriesId];
    // 没显式给 finished 时按进度比例判定；时长未知则沿用旧值。
    final resolvedFinished = finished ??
        (durationSeconds > 0
            ? HistoryEntry.shouldMarkFinished(position, durationSeconds)
            : (existing?.finished ?? false));
    _entries[seriesId] = HistoryEntry(
      seriesId: seriesId,
      title: title,
      coverUrl: coverUrl,
      episode: episode,
      episodes: episodes,
      episodeId: episodeId,
      position: position,
      finished: resolvedFinished,
      // 进度回写不携带偏好时，保留用户此前手动选择的倍速/清晰度；
      // 否则自动换线选到的低清晰度会把「最高」偏好覆盖掉。
      speed: speed > 0 ? speed : (existing?.speed ?? 0),
      quality: quality.isNotEmpty ? quality : (existing?.quality ?? ''),
      subtitleDelayMs: existing?.subtitleDelayMs,
      audioTrackIndex: existing?.audioTrackIndex,
      subtitleTrackIndex: existing?.subtitleTrackIndex,
      audioTrackKey: existing?.audioTrackKey ?? '',
      subtitleTrackKey: existing?.subtitleTrackKey ?? '',
      sourceKey: sourceKey.isNotEmpty ? sourceKey : (existing?.sourceKey ?? ''),
      playUrl: playUrl.isNotEmpty ? playUrl : (existing?.playUrl ?? ''),
    );
    _prune();
    // 读改写整体入队（[_updateJson]）：高频写者（每 5s/暂停/退出），与偏好
    // 刷新/封面刷新并发时不再互相覆盖，顺序行为不变。
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  /// 只写这部剧的播放偏好（倍速/清晰度），保留记录其余字段；
  /// 没有历史记录时建一条占位（不上进度）。
  Future<void> setPlaybackPrefs({
    required String seriesId,
    double? speed,
    String? quality,
    int? subtitleDelayMs,
    int? audioTrackIndex,
    int? subtitleTrackIndex,
    String audioTrackKey = '',
    String subtitleTrackKey = '',
  }) async {
    await ensureLoaded();
    final e = _entries[seriesId];
    _entries[seriesId] = HistoryEntry(
      seriesId: seriesId,
      title: e?.title ?? '',
      coverUrl: e?.coverUrl ?? '',
      episode: e?.episode ?? 1,
      episodes: e?.episodes ?? 0,
      episodeId: e?.episodeId ?? '',
      position: e?.position ?? 0,
      finished: e?.finished ?? false,
      speed: speed ?? e?.speed ?? 0,
      quality: quality ?? e?.quality ?? '',
      subtitleDelayMs: subtitleDelayMs ?? e?.subtitleDelayMs,
      audioTrackIndex: audioTrackIndex ?? e?.audioTrackIndex,
      subtitleTrackIndex: subtitleTrackIndex ?? e?.subtitleTrackIndex,
      audioTrackKey: audioTrackKey.isNotEmpty
          ? audioTrackKey
          : (e?.audioTrackKey ?? ''),
      subtitleTrackKey: subtitleTrackKey.isNotEmpty
          ? subtitleTrackKey
          : (e?.subtitleTrackKey ?? ''),
      // 偏好写入不能顺手丢掉「来源 / 上次直链」：续播兜底要靠它们。
      sourceKey: e?.sourceKey ?? '',
      playUrl: e?.playUrl ?? '',
      updatedAt: e?.updatedAt,
    );
    // 读改写整体入队（[_updateJson]）。
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }


  /// 用最新详情批量刷新封面（URL 变了才落盘一次）；返回更新的条数。
  Future<int> refreshCovers(Map<String, String> covers) async {
    await ensureLoaded();
    var changed = 0;
    covers.forEach((id, url) {
      if (url.isEmpty) return;
      final e = _entries[id];
      if (e != null && e.coverUrl != url) {
        _entries[id] = HistoryEntry(
          seriesId: e.seriesId,
          title: e.title,
          coverUrl: url,
          episode: e.episode,
          episodes: e.episodes,
          finished: e.finished,
          position: e.position,
          episodeId: e.episodeId,
          speed: e.speed,
          quality: e.quality,
          updatedAt: e.updatedAt,
        );
        changed++;
      }
    });
    if (changed > 0) {
      // 读改写整体入队（[_updateJson]）；无变化时保持旧语义不写盘。
      await _updateJson((existing) => <String, dynamic>{
            for (final e in _entries.entries) e.key: e.value.toJson(),
          });
      notifyListeners();
    }
    return changed;
  }


  Future<void> clear() async {
    _entries.clear();
    // 必须落空文档（不能返回 null），与旧版 `_writeJson({})` 一致。
    await _updateJson((existing) => <String, dynamic>{});
    notifyListeners();
  }

  Future<void> remove(String seriesId) async {
    _entries.remove(seriesId);
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {for (final e in _entries.entries) e.key: e.value.toJson()};
  }

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((key, value) {
      if (value is! Map<String, dynamic>) return;
      final entry = HistoryEntry.fromJson(value);
      if (key.isEmpty || entry.seriesId.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      _prune();
      // 读改写整体入队（[_updateJson]）。
      await _updateJson((existing) => <String, dynamic>{
            for (final e in _entries.entries) e.key: e.value.toJson(),
          });
      notifyListeners();
    }
    return merged;
  }
}

/// 追剧收藏：series_id → 记录。
class FollowStore extends _JsonFileStore {
  FollowStore({super.testDirectory}) : super('aquan_follows.json');

  final Map<String, FollowEntry> _entries = {};

  List<FollowEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  bool isFollowing(String seriesId) => _entries.containsKey(seriesId);

  FollowEntry? get(String seriesId) => _entries[seriesId];

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) {
        _entries[k] = FollowEntry.fromJson(v);
      }
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  Future<void> toggle({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episodeCount,
  }) async {
    await ensureLoaded();
    if (_entries.remove(seriesId) != null) {
      notifyListeners();
    } else {
      await follow(
        seriesId: seriesId,
        title: title,
        coverUrl: coverUrl,
        episodeCount: episodeCount,
      );
    }
    await _flush();
  }

  Future<void> follow({
    required String seriesId,
    required String title,
    required String coverUrl,
    required int episodeCount,
    FollowState state = FollowState.watching,
  }) async {
    _entries[seriesId] = FollowEntry(
      seriesId: seriesId,
      title: title,
      coverUrl: coverUrl,
      episodeCount: episodeCount,
      state: state,
    );
    await _flush();
  }

  /// 设置追剧状态（想看/在看/已看）；没追过的剧先按追剧处理。
  /// 返回 true 表示该剧在追（无论状态是什么）。
  Future<bool> setStateOf({
    required String seriesId,
    required FollowState state,
    String title = '',
    String coverUrl = '',
    int episodeCount = 0,
  }) async {
    await ensureLoaded();
    final existing = _entries[seriesId];
    if (existing == null) {
      if (title.isEmpty) return false;
      await follow(
        seriesId: seriesId,
        title: title,
        coverUrl: coverUrl,
        episodeCount: episodeCount,
        state: state,
      );
      return true;
    }
    if (existing.state != state) {
      _entries[seriesId] = FollowEntry(
        seriesId: existing.seriesId,
        title: existing.title,
        coverUrl: existing.coverUrl,
        episodeCount: existing.episodeCount,
        state: state,
        updatedAt: existing.updatedAt,
      );
      await _flush();
    }
    return true;
  }

  /// 全量写盘（追剧条目整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  /// 用批量详情刷新封面与服务端集数（有变化才落盘一次）；返回更新的条数。
  Future<int> refreshFromDetails(List<Series> details) async {
    await ensureLoaded();
    var changed = 0;
    for (final d in details) {
      final e = _entries[d.id];
      if (e == null) continue;
      final cover = d.coverUrl;
      final latest = d.episodeCount;
      final coverChanged = cover.isNotEmpty && cover != e.coverUrl;
      final countChanged =
          latest > 0 && latest != e.latestEpisodeCount;
      if (!coverChanged && !countChanged) continue;
      _entries[d.id] = FollowEntry(
        seriesId: e.seriesId,
        title: e.title,
        coverUrl: coverChanged ? cover : e.coverUrl,
        episodeCount: e.episodeCount,
        latestEpisodeCount:
            countChanged ? latest : e.latestEpisodeCount,
        state: e.state,
        updatedAt: e.updatedAt,
      );
      changed++;
    }
    if (changed > 0) {
      // 读改写整体入队（[_updateJson]）；无变化时保持旧语义不写盘。
      await _updateJson((existing) => <String, dynamic>{
            for (final e in _entries.entries) e.key: e.value.toJson(),
          });
      notifyListeners();
    }
    return changed;
  }

  /// 用户已看过更新（打开详情/继续观看）后，把记录追平并清除更新标记。
  Future<void> ackUpdate(String seriesId, int latestCount) async {
    await ensureLoaded();
    final e = _entries[seriesId];
    if (e == null || !e.hasUpdate) return;
    final seen = latestCount > 0 ? latestCount : e.latestEpisodeCount;
    _entries[seriesId] = FollowEntry(
      seriesId: e.seriesId,
      title: e.title,
      coverUrl: e.coverUrl,
      episodeCount: seen,
      state: e.state,
      updatedAt: e.updatedAt,
    );
    // 读改写整体入队（[_updateJson]）。
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {for (final e in _entries.entries) e.key: e.value.toJson()};
  }

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((key, value) {
      if (value is! Map<String, dynamic>) return;
      final entry = FollowEntry.fromJson(value);
      if (key.isEmpty || entry.seriesId.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt.isAfter(existing.updatedAt)) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      // 读改写整体入队（[_updateJson]）。
      await _updateJson((existing) => <String, dynamic>{
            for (final e in _entries.entries) e.key: e.value.toJson(),
          });
      notifyListeners();
    }
    return merged;
  }
}

/// 片头片尾跳过：series_id → 时间点，跨集继承、按剧记忆。
///
/// 文件格式：`{"version": 1, "items": {series_id: {opening_ms, ending_ms, updated_at}}}`。
/// 版本不符时保留原文件但按空处理（读取侧不因为半坏文件拖垮播放）。
class PlaySkipStore extends _JsonFileStore {
  PlaySkipStore() : super('aquan_play_skip.json');

  static const int formatVersion = 1;
  static const int maxEntries = 500;
  static const String _itemsKey = 'items';

  final Map<String, PlaySkipEntry> _entries = {};

  PlaySkipEntry? entryFor(String seriesId) => _entries[seriesId];

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    final rawItems = json[_itemsKey];
    if (json['version'] == formatVersion && rawItems is Map) {
      rawItems.forEach((key, value) {
        if (key is! String || value is! Map) return;
        final entry = PlaySkipEntry.tryFromJson(value);
        if (entry != null && !entry.isEmpty) _entries[key] = entry;
      });
      _prune();
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 写入 / 覆盖某剧的时间点；空值等同于移除。
  Future<void> upsert(String seriesId, PlaySkipEntry entry) async {
    await ensureLoaded();
    if (entry.isEmpty) {
      _entries.remove(seriesId);
    } else {
      _entries[seriesId] = entry.copyWith(
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      );
    }
    _prune();
    await _save();
  }

  Future<void> remove(String seriesId) =>
      upsert(seriesId, const PlaySkipEntry());

  Future<void> clear() async {
    await ensureLoaded();
    if (_entries.isEmpty) return;
    _entries.clear();
    await _save();
  }

  int _prune() {
    if (_entries.length <= maxEntries) return 0;
    final ordered = _entries.entries.toList()
      ..sort((a, b) => b.value.updatedAt.compareTo(a.value.updatedAt));
    final keep = ordered.take(maxEntries).map((e) => e.key).toSet();
    final before = _entries.length;
    _entries.removeWhere((k, _) => !keep.contains(k));
    return before - _entries.length;
  }

  /// 全量写盘（version + items 整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：顺序行为与旧版逐字节一致。
  Future<void> _save() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': formatVersion,
          _itemsKey: {
            for (final e in _entries.entries) e.key: e.value.toJson(),
          },
        });
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {
      _itemsKey: {
        for (final e in _entries.entries) e.key: e.value.toJson(),
      },
    };
  }

  /// 合并恢复：同一条目取 updatedAt 较新者；返回合并进来的条数。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final rawItems = incoming[_itemsKey];
    if (rawItems is! Map) return 0;
    var merged = 0;
    rawItems.forEach((key, value) {
      if (key is! String || value is! Map) return;
      final entry = PlaySkipEntry.tryFromJson(value);
      if (entry == null || entry.isEmpty) return;
      final existing = _entries[key];
      if (existing == null || entry.updatedAt >= existing.updatedAt) {
        _entries[key] = entry;
        merged++;
      }
    });
    if (merged > 0) {
      _prune();
      await _save();
    }
    return merged;
  }
}

/// 搜索历史：最近提交过的关键词，新词置顶、去重、上限 20 条。
class SearchHistoryStore extends _JsonFileStore {
  SearchHistoryStore() : super('aquan_search_history.json');

  /// UI 显示与持久化的上限；超出时淘汰最旧的。
  static const maxEntries = 20;

  static const _key = 'queries';

  List<String> _queries = [];

  /// 最新在前；只读视图。
  List<String> get queries => List.unmodifiable(_queries);

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    final raw = json[_key];
    _queries = [
      if (raw is List<Object?>)
        for (final q in raw)
          if (q is String && q.trim().isNotEmpty) q,
    ];
    if (_queries.length > maxEntries) {
      _queries = _queries.sublist(0, maxEntries);
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 记录一次搜索：已存在的词移到最前，其余顺移，超限淘汰最旧的。
  Future<void> record(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    await ensureLoaded();
    _queries
      ..remove(q)
      ..insert(0, q);
    if (_queries.length > maxEntries) {
      _queries = _queries.sublist(0, maxEntries);
    }
    await _save();
  }

  Future<void> remove(String query) async {
    await ensureLoaded();
    if (_queries.remove(query)) await _save();
  }

  Future<void> clear() async {
    await ensureLoaded();
    if (_queries.isEmpty) return;
    _queries = [];
    await _save();
  }

  /// 全量写盘（queries 整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：顺序行为与旧版逐字节一致。
  Future<void> _save() async {
    await _updateJson((existing) => <String, dynamic>{
          _key: _queries,
        });
    notifyListeners();
  }

  @override
  Future<Map<String, dynamic>> exportData() async {
    await ensureLoaded();
    return {
      _key: List<String>.from(_queries),
    };
  }

  /// 合并恢复：保留现有顺序，把备份里的新词追加到末尾并去重。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final raw = incoming[_key];
    if (raw is! List) return 0;
    var added = 0;
    for (final q in raw) {
      if (q is! String) continue;
      final text = q.trim();
      if (text.isEmpty || _queries.contains(text)) continue;
      _queries.add(text);
      added++;
    }
    if (added > 0) {
      if (_queries.length > maxEntries) {
        _queries = _queries.sublist(0, maxEntries);
      }
      await _save();
    }
    return added;
  }
}

/// 一条离线下载记录：加密 MP4 的落盘位置 + 播放所需的 CENC 密钥。
/// 密钥按集稳定（2026-10-29 实测：同一集重复解析结果一致），随文件缓存后
/// 本地播放不再需要网络；未加密剧集 keyHex 为空。
class DownloadEntry {
  const DownloadEntry({
    required this.seriesId,
    required this.seriesTitle,
    required this.coverUrl,
    required this.episodeId,
    required this.number,
    required this.title,
    required this.filePath,
    required this.sizeBytes,
    required this.keyHex,
    required this.quality,
    required this.downloadedAt,
  });

  final String seriesId;
  final String seriesTitle;
  final String coverUrl;
  final String episodeId;
  final int number;
  final String title;
  final String filePath;
  final int sizeBytes;
  final String keyHex;
  final String quality;
  final DateTime downloadedAt;

  DownloadEntry copyWith({String? filePath}) => DownloadEntry(
        seriesId: seriesId,
        seriesTitle: seriesTitle,
        coverUrl: coverUrl,
        episodeId: episodeId,
        number: number,
        title: title,
        filePath: filePath ?? this.filePath,
        sizeBytes: sizeBytes,
        keyHex: keyHex,
        quality: quality,
        downloadedAt: downloadedAt,
      );

  Map<String, dynamic> toJson() => {
        'series_id': seriesId,
        'series_title': seriesTitle,
        'cover_url': coverUrl,
        'episode_id': episodeId,
        'number': number,
        'title': title,
        'file_path': filePath,
        'size_bytes': sizeBytes,
        'key_hex': keyHex,
        'quality': quality,
        'downloaded_at': downloadedAt.toIso8601String(),
      };

  factory DownloadEntry.fromJson(Map<String, dynamic> json) => DownloadEntry(
        seriesId: json['series_id'] as String? ?? '',
        seriesTitle: json['series_title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        episodeId: json['episode_id'] as String? ?? '',
        number: json['number'] as int? ?? 0,
        title: json['title'] as String? ?? '',
        filePath: json['file_path'] as String? ?? '',
        sizeBytes: json['size_bytes'] as int? ?? 0,
        keyHex: json['key_hex'] as String? ?? '',
        quality: json['quality'] as String? ?? '',
        downloadedAt:
            DateTime.tryParse(json['downloaded_at'] as String? ?? '') ??
                DateTime.now(),
      );
}

/// 一部已缓存剧的聚合视图（下载管理页用）。
class DownloadedSeries {
  const DownloadedSeries({
    required this.seriesId,
    required this.title,
    required this.coverUrl,
    required this.episodes,
    required this.totalBytes,
  });

  final String seriesId;
  final String title;
  final String coverUrl;
  final List<DownloadEntry> episodes;
  final int totalBytes;
}

/// 离线下载清单：seriesId → episodeId → 记录。
class DownloadStore extends _JsonFileStore {
  DownloadStore() : super('aquan_downloads.json');

  final Map<String, Map<String, DownloadEntry>> _series = {};

  /// 某一集的记录；未缓存返回 null。
  DownloadEntry? entryOf(String episodeId) {
    for (final eps in _series.values) {
      final e = eps[episodeId];
      if (e != null) return e;
    }
    return null;
  }

  bool has(String episodeId) => entryOf(episodeId) != null;

  /// 一部剧已缓存的集（按集数排序）。
  List<DownloadEntry> episodesOf(String seriesId) {
    final eps = _series[seriesId]?.values.toList() ?? const <DownloadEntry>[];
    eps.sort((a, b) => a.number.compareTo(b.number));
    return eps;
  }

  /// 全部已缓存剧（按最近下载时间排序，供管理页）。
  List<DownloadedSeries> get seriesList {
    final list = <DownloadedSeries>[];
    for (final entry in _series.values.expand((m) => m.values)) {
      final existing = list.where((s) => s.seriesId == entry.seriesId).toList();
      if (existing.isEmpty) {
        list.add(DownloadedSeries(
          seriesId: entry.seriesId,
          title: entry.seriesTitle,
          coverUrl: entry.coverUrl,
          episodes: episodesOf(entry.seriesId),
          totalBytes: episodesOf(entry.seriesId)
              .fold<int>(0, (sum, e) => sum + e.sizeBytes),
        ));
      }
    }
    // 「最近下载」= 该剧所有集里最新的下载时间，不是最大集号那一集的时间。
    list.sort((a, b) => _latestDownloadAt(b).compareTo(_latestDownloadAt(a)));
    return list;
  }

  static DateTime _latestDownloadAt(DownloadedSeries s) => s.episodes
      .map((e) => e.downloadedAt)
      .reduce((a, b) => a.isAfter(b) ? a : b);

  int get totalBytes => _series.values
      .expand((m) => m.values)
      .fold<int>(0, (sum, e) => sum + e.sizeBytes);

  /// 记录一条；同集重复下载以新记录为准。
  Future<void> record(DownloadEntry e) async {
    await ensureLoaded();
    (_series[e.seriesId] ??= {})[e.episodeId] = e;
    // 读改写整体入队（[_updateJson]，11-07-store-write-race-migration）：
    // 多任务并行下载各自完成时并发触发，串行化后整表覆写不再互相覆盖。
    await _updateJson((existing) => <String, dynamic>{
          for (final s in _series.entries)
            s.key: {for (final x in s.value.entries) x.key: x.value.toJson()},
        });
    notifyListeners();
  }

  Future<void> removeEpisode(String episodeId) async {
    await ensureLoaded();
    for (final eps in _series.values) {
      if (eps.remove(episodeId) != null) break;
    }
    _series.removeWhere((_, eps) => eps.isEmpty);
    await _save();
  }

  Future<void> removeSeries(String seriesId) async {
    await ensureLoaded();
    if (_series.remove(seriesId) == null) return;
    await _save();
  }

  /// 更新某集的落盘路径（下载目录迁移用）。
  Future<void> updateFilePath(String episodeId, String newPath) async {
    await ensureLoaded();
    for (final eps in _series.values) {
      final entry = eps[episodeId];
      if (entry == null) continue;
      eps[episodeId] = entry.copyWith(filePath: newPath);
      await _save();
      return;
    }
  }

  /// 全量写盘（下载清单整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：与 record() 并发时不再互相覆盖。
  Future<void> _save() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final s in _series.entries)
            s.key: {for (final x in s.value.entries) x.key: x.value.toJson()},
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _series.clear();
    json.forEach((seriesId, eps) {
      if (eps is! Map<String, dynamic>) return;
      final map = <String, DownloadEntry>{};
      eps.forEach((episodeId, v) {
        if (v is Map<String, dynamic>) {
          map[episodeId] = DownloadEntry.fromJson(v);
        }
      });
      if (map.isNotEmpty) _series[seriesId] = map;
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

/// 阅读进度：一本书一条，与短剧观看历史分开存。
class ReadingEntry {
  ReadingEntry({
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.chapterIndex = 0,
    this.chapters = 0,
    this.offset = 0,
    this.charOffset = -1,
    this.revision = 0,
    this.manga = false,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String bookId;
  final String title;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final int chapterIndex;
  final int chapters;

  /// 漫画与小说共用这份记录：决定点开时进阅读器还是图片阅读器。
  final bool manga;

  /// 章节内的滚动位置（0..1），续读时用来还原。
  final double offset;

  /// 章内字符偏移；`-1` 表示旧记录没有这个字段。
  ///
  /// 比 [offset] 精确：改字号后仍能落回同一句，[offset] 只能落到大概位置。
  final int charOffset;

  /// 写入序号：只接受更大的序号，避免「旧快照后写」把新进度盖回去。
  final int revision;
  final DateTime updatedAt;

  /// 整本进度（按章数粗算），用于「继续阅读」的进度条。
  double get percent =>
      chapters <= 0 ? 0 : ((chapterIndex + 1) / chapters).clamp(0.0, 1.0);

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_index': chapterIndex,
        'chapters': chapters,
        'offset': offset,
        'char_offset': charOffset,
        'revision': revision,
        'manga': manga,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ReadingEntry.fromJson(String bookId, Map<String, dynamic> json) =>
      ReadingEntry(
        bookId: bookId,
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterTitle: json['chapter_title'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as num?)?.toInt() ?? 0,
        offset: (json['offset'] as num?)?.toDouble() ?? 0,
        charOffset: (json['char_offset'] as num?)?.toInt() ?? -1,
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        manga: json['manga'] as bool? ?? false,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 小说阅读进度存储（`aquan_reading.json`）。
class ReadingProgressStore extends _JsonFileStore {
  ReadingProgressStore({super.testDirectory}) : super('aquan_reading.json');

  final Map<String, ReadingEntry> _entries = {};

  /// 最近在读在前。
  List<ReadingEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  ReadingEntry? entry(String bookId) => _entries[bookId];

  /// 记录进度。
  ///
  /// [revision] 为 null 表示调用方不做版本控制，由 store 用「墙钟微秒 + 已存序号」
  /// 生成跨会话单调的序号（漫画等没有防抖快照的调用方用这个）；传具体值时按
  /// 「小于等于已存序号即丢弃」处理，供有 900ms 防抖的阅读器压制旧快照。
  /// 需要跨会话续号的调用方先用 [revisionOf] 取当前序号再加一。
  /// [charOffset] 为章内字符偏移，`-1` 表示未知。
  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required double offset,
    int charOffset = -1,
    int? revision,
    bool manga = false,
  }) async {
    await ensureLoaded();
    final existing = _entries[bookId];
    final int nextRevision;
    if (revision == null) {
      final now = DateTime.now().microsecondsSinceEpoch;
      nextRevision = existing == null
          ? now
          : (now > existing.revision ? now : existing.revision + 1);
    } else {
      if (existing != null && revision <= existing.revision) return;
      nextRevision = revision;
    }
    _entries[bookId] = ReadingEntry(
      bookId: bookId,
      title: title,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      chapters: chapters,
      offset: offset.clamp(0.0, 1.0),
      charOffset: charOffset,
      revision: nextRevision,
      manga: manga,
    );
    await _flush();
  }

  /// 补齐封面：只补「已有记录且封面为空」的情况。
  ///
  /// 第三方书源的书籍进阅读器时还拿不到封面，历史记录里就是空串；等详情页
  /// 拿到封面后回填一次。**不动进度、序号与更新时间** —— 它只是补字段，
  /// 不能把自己当成一次新的阅读而把书顶到列表最前、也不能压制进度写入。
  Future<bool> fillCover(String bookId, String coverUrl) async {
    final cover = coverUrl.trim();
    if (cover.isEmpty) return false;
    await ensureLoaded();
    final existing = _entries[bookId];
    if (existing == null || existing.coverUrl.trim().isNotEmpty) return false;
    _entries[bookId] = ReadingEntry(
      bookId: bookId,
      title: existing.title,
      coverUrl: cover,
      chapterId: existing.chapterId,
      chapterTitle: existing.chapterTitle,
      chapterIndex: existing.chapterIndex,
      chapters: existing.chapters,
      offset: existing.offset,
      charOffset: existing.charOffset,
      revision: existing.revision,
      manga: existing.manga,
      updatedAt: existing.updatedAt,
    );
    await _flush();
    return true;
  }

  /// 已存记录的写入序号；调用方据此续号，避免每次打开页面都从 0 重来。
  Future<int> revisionOf(String bookId) async {
    await ensureLoaded();
    return _entries[bookId]?.revision ?? 0;
  }

  Future<void> remove(String bookId) async {
    await ensureLoaded();
    if (_entries.remove(bookId) == null) return;
    await _flush();
  }

  /// 全量写盘（阅读进度整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：高频进度写与封面回填/删除并发时
  /// 不再互相覆盖；仍维持「每次全量读文件」的现状模式，无增量缓存。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _entries[k] = ReadingEntry.fromJson(k, v);
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

class _CachedChapter {
  _CachedChapter(this.text, this.savedAt, this.signature);

  final String text;
  final DateTime savedAt;

  /// 正文 FNV-1a 签名；空串表示旧版本写入、无法校验。
  final String signature;

  Map<String, dynamic> toJson() => {
        'text': text,
        'saved_at': savedAt.toIso8601String(),
        'sig': signature,
      };

  factory _CachedChapter.fromJson(Map<String, dynamic> json) =>
      _CachedChapter(
        json['text'] as String? ?? '',
        DateTime.tryParse(json['saved_at'] as String? ?? '') ?? DateTime.now(),
        json['sig'] as String? ?? '',
      );
}

/// 章节正文缓存（`aquan_book_cache.json`）：断网也能读已看过的章节，
/// 超出上限按保存时间淘汰最旧的。
class BookChapterCache extends _JsonFileStore {
  BookChapterCache({super.testDirectory}) : super('aquan_book_cache.json');

  static const int defaultLimit = 200;

  /// 磁盘/内存占用上限：200 个 1.5 万字章节约 60MB，光按条数淘汰会撑爆。
  static const int defaultMaxBytes = 32 * 1024 * 1024;

  final Map<String, _CachedChapter> _items = {};
  int _limit = defaultLimit;
  int _maxBytes = defaultMaxBytes;

  int get limit => _limit;

  set limit(int v) => _limit = v < 1 ? defaultLimit : v;

  int get maxBytes => _maxBytes;

  set maxBytes(int v) =>
      _maxBytes = v < 1024 * 1024 ? defaultMaxBytes : v;

  /// 当前占用（UTF-16 估算：`text.length * 2`）。
  int get totalBytes {
    var sum = 0;
    for (final item in _items.values) {
      sum += item.text.length * 2;
    }
    return sum;
  }

  /// 取缓存正文。
  ///
  /// 传了 [expectSignature] 且与落盘签名不一致时返回 null：说明源站改过正文，
  /// 继续用旧文本会让分页与进度对不上。
  String? text(String itemId, {String? expectSignature}) {
    final item = _items[itemId];
    if (item == null) return null;
    if (expectSignature != null &&
        item.signature.isNotEmpty &&
        item.signature != expectSignature) {
      return null;
    }
    return item.text;
  }

  /// 已存正文的签名（无缓存返回 null）。
  String? signatureOf(String itemId) => _items[itemId]?.signature;

  Future<void> put(String itemId, String text, {String signature = ''}) async {
    await ensureLoaded();
    _items[itemId] = _CachedChapter(text, DateTime.now(), signature);
    await _flush();
  }

  Future<void> remove(String itemId) async {
    await ensureLoaded();
    if (_items.remove(itemId) == null) return;
    await _flush();
  }

  Future<void> clear() async {
    await ensureLoaded();
    if (_items.isEmpty) return;
    _items.clear();
    await _flush();
  }

  /// 全量写盘（章节缓存整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：高频 put 与 remove/clear 并发时
  /// 不再互相覆盖；仍维持「每次全量读文件」的现状模式，无增量缓存。
  Future<void> _flush() async {
    _prune();
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _items.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  /// 双阈值淘汰：先满足条数上限，再按最旧淘汰直到总字节不超限。
  ///
  /// 至少保留一条（单章本身超上限时也要能读）。
  void _prune() {
    if (_items.length <= _limit && totalBytes <= _maxBytes) return;
    final ordered = _items.entries.toList()
      ..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
    final keep = <String>{};
    var bytes = 0;
    for (final entry in ordered) {
      if (keep.length >= _limit) break;
      final size = entry.value.text.length * 2;
      if (bytes + size > _maxBytes && keep.isNotEmpty) break;
      bytes += size;
      keep.add(entry.key);
    }
    _items.removeWhere((k, _) => !keep.contains(k));
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _items.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _items[k] = _CachedChapter.fromJson(v);
    });
    _loaded = true;
    _prune();
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

// ---------- 详情快照缓存 ----------

/// 详情快照缓存（详情页秒开）：`aquan_detail_snapshot.json`。
///
/// 键约定：`aqua:detail:<bookId>` / `aqua:dir:<bookId>`（自家书籍详情与目录）、
/// `src:<sourceKey>:<itemId>`（书源详情 UnifiedSeries）。
/// 值为模型 toJson 的原始 Map（含 Map 字段的模型必须存原始 JSON，
/// 二次转模型会丢字段——VenHM 教训）。快照可再生，不进备份白名单。
/// 双阈值淘汰（条数 + 字节）参照 [BookChapterCache]；损坏条目跳过不抛。
class DetailSnapshotStore extends _JsonFileStore {
  DetailSnapshotStore({super.testDirectory}) : super('aquan_detail_snapshot.json');

  static const int defaultLimit = 200;
  static const int defaultMaxBytes = 4 * 1024 * 1024;

  final Map<String, _CachedSnapshot> _items = {};
  int _limit = defaultLimit;
  int _maxBytes = defaultMaxBytes;

  int get limit => _limit;

  set limit(int v) => _limit = v < 1 ? defaultLimit : v;

  int get maxBytes => _maxBytes;

  set maxBytes(int v) =>
      _maxBytes = v < 64 * 1024 ? defaultMaxBytes : v;

  /// 当前占用（UTF-16 估算：`json.length * 2`，与 BookChapterCache 同口径）。
  int get totalBytes {
    var sum = 0;
    for (final item in _items.values) {
      sum += item.bytes;
    }
    return sum;
  }

  int get length => _items.length;

  /// 取快照原始 JSON（未命中/已淘汰返回 null）。
  Map<String, dynamic>? get(String key) => _items[key]?.data;

  /// 快照保存时间（用于调试/展示「缓存于…」）。
  DateTime? savedAtOf(String key) => _items[key]?.savedAt;

  Future<void> put(String key, Map<String, dynamic> data) async {
    await ensureLoaded();
    _items[key] = _CachedSnapshot(
      data: Map<String, dynamic>.of(data),
      savedAt: DateTime.now(),
      bytes: jsonEncode(data).length * 2,
    );
    await _flush();
  }

  Future<void> remove(String key) async {
    await ensureLoaded();
    if (_items.remove(key) == null) return;
    await _flush();
  }

  Future<void> clear() async {
    await ensureLoaded();
    if (_items.isEmpty) return;
    _items.clear();
    await _flush();
  }

  /// 全量写盘（快照缓存整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：与 BookChapterCache 同构。
  Future<void> _flush() async {
    _prune();
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _items.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  /// 双阈值淘汰：超条数或超字节时按最旧淘汰，至少保留一条。
  void _prune() {
    if (_items.length <= _limit && totalBytes <= _maxBytes) return;
    final ordered = _items.entries.toList()
      ..sort((a, b) => b.value.savedAt.compareTo(a.value.savedAt));
    final keep = <String>{};
    var bytes = 0;
    for (final entry in ordered) {
      if (keep.length >= _limit) break;
      if (bytes + entry.value.bytes > _maxBytes && keep.isNotEmpty) break;
      bytes += entry.value.bytes;
      keep.add(entry.key);
    }
    _items.removeWhere((k, _) => !keep.contains(k));
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _items.clear();
    json.forEach((k, v) {
      final snap = _CachedSnapshot.tryFromJson(v);
      if (snap != null) _items[k] = snap;
    });
    _loaded = true;
    _prune();
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

class _CachedSnapshot {
  const _CachedSnapshot({
    required this.data,
    required this.savedAt,
    required this.bytes,
  });

  final Map<String, dynamic> data;
  final DateTime savedAt;

  /// 估算占用（jsonEncode 长度 ×2），put 时算好，淘汰时不重复编码。
  final int bytes;

  Map<String, dynamic> toJson() => {
        'data': data,
        'saved_at': savedAt.millisecondsSinceEpoch,
      };

  static _CachedSnapshot? tryFromJson(Object? raw) {
    if (raw is! Map) return null;
    final data = raw['data'];
    final savedAt = (raw['saved_at'] as num?)?.toInt();
    if (data is! Map<String, dynamic> || savedAt == null) return null;
    return _CachedSnapshot(
      data: data,
      savedAt: DateTime.fromMillisecondsSinceEpoch(savedAt),
      bytes: jsonEncode(data).length * 2,
    );
  }
}

// ---------- 播放线路健康度 ----------

/// 播放线路健康度（`aquan_playback_health.json`）。
///
/// 键为 `源|影片|集|线路`，与 `SourceHealthStore`（按源）互补。
/// Venera 源数据/设置的落盘 KV（`aquan_venera.json`）。
///
/// 键形如 `data/<sourceKey>/<dataKey>`、`setting/<sourceKey>/<settingKey>`；
/// 值动态（字符串/对象均可——save_data 语义）。不进备份白名单（源数据可重取）。
class VeneraStore extends _JsonFileStore {
  VeneraStore({super.testDirectory}) : super('aquan_venera.json');

  final Map<String, dynamic> _kv = {};

  dynamic value(String key) => _kv[key];

  bool has(String key) => _kv.containsKey(key);

  Future<void> setValue(String key, dynamic v) async {
    await ensureLoaded();
    _kv[key] = v;
    await _flush();
  }

  Future<void> remove(String key) async {
    await ensureLoaded();
    if (_kv.remove(key) == null) return;
    await _flush();
  }

  /// 整库覆写型写者（KV 表全量）。读改写整体入队（[_updateJson]，
  /// 11-07-store-write-race-migration）：合并逻辑 = 返回内存态新整文档，
  /// 入队串行化；顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => Map<String, dynamic>.of(_kv));
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _kv
      ..clear()
      ..addAll(json);
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}

class PlaybackHealthStore extends _JsonFileStore {
  PlaybackHealthStore({super.testDirectory})
      : super('aquan_playback_health.json');

  final PlaybackHealthRegistry registry = PlaybackHealthRegistry();

  PlaybackHealthRegistry get health => registry;

  Future<void> record(String key, PlaybackHealthEvent event) async {
    await ensureLoaded();
    registry.record(key, event);
    // 读改写整体入队（[_updateJson]，11-08-store-race-final）：文档仍由内存态
    // （registry）构建，入队后与其它写者串行，并发混合写不再互相覆盖。
    await _updateJson((existing) => registry.toJson());
    notifyListeners();
  }

  Future<void> clear() async {
    registry.clear();
    // 必须落空文档（不能返回 null），与旧版 `_writeJson({})` 一致。
    await _updateJson((existing) => <String, dynamic>{});
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    registry.loadFromJson(json);
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final before = registry.records.length;
    for (final entry in incoming.entries) {
      final value = entry.value;
      if (value is! Map<String, dynamic>) continue;
      registry.record(
        entry.key,
        (value['fail'] as num?)?.toInt() != null &&
                (value['fail'] as num).toInt() > 0
            ? PlaybackHealthEvent.failed
            : PlaybackHealthEvent.success,
      );
    }
    await _updateJson((existing) => registry.toJson());
    return registry.records.length - before;
  }
}

// ---------- 阅读书签 ----------

/// 书签存储（`aquan_bookmarks.json`），按书归档。
class BookmarkStore extends _JsonFileStore {
  BookmarkStore({super.testDirectory}) : super('aquan_bookmarks.json');

  final Map<String, List<ReaderBookmark>> _byBook =
      <String, List<ReaderBookmark>>{};

  /// 某本书的书签，按章号 + 章内偏移升序。
  List<ReaderBookmark> of(String bookId) {
    final list = List<ReaderBookmark>.of(_byBook[bookId] ?? const []);
    list.sort((a, b) {
      final byChapter = a.chapterIndex.compareTo(b.chapterIndex);
      return byChapter != 0 ? byChapter : a.charOffset.compareTo(b.charOffset);
    });
    return list;
  }

  int countOf(String bookId) => _byBook[bookId]?.length ?? 0;

  /// 新增书签；同一章同一字符位置已存在时直接返回已有项。
  Future<ReaderBookmark> add({
    required String bookId,
    required String chapterId,
    required int chapterIndex,
    required int charOffset,
    String chapterTitle = '',
    String excerpt = '',
  }) async {
    await ensureLoaded();
    final list = _byBook.putIfAbsent(bookId, () => <ReaderBookmark>[]);
    for (final item in list) {
      if (item.chapterId == chapterId && item.charOffset == charOffset) {
        return item;
      }
    }
    final bookmark = ReaderBookmark(
      id: 'bm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      bookId: bookId,
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      charOffset: charOffset,
      chapterTitle: chapterTitle,
      excerpt: excerpt,
      createdAt: DateTime.now(),
    );
    list.add(bookmark);
    await _flush();
    return bookmark;
  }

  Future<void> updateNote(String bookId, String id, String note) async {
    await ensureLoaded();
    final list = _byBook[bookId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == id) {
        list[i] = list[i].copyWith(note: note);
        await _flush();
        return;
      }
    }
  }

  Future<void> remove(String bookId, String id) async {
    await ensureLoaded();
    final list = _byBook[bookId];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((item) => item.id == id);
    if (list.length == before) return;
    if (list.isEmpty) _byBook.remove(bookId);
    await _flush();
  }

  Future<void> clearBook(String bookId) async {
    await ensureLoaded();
    if (_byBook.remove(bookId) == null) return;
    await _flush();
  }

  /// 全量写盘（整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final entry in _byBook.entries)
            entry.key: <Map<String, dynamic>>[
              for (final item in entry.value) item.toJson(),
            ],
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _byBook.clear();
    json.forEach((bookId, value) {
      if (value is! List) return;
      final list = <ReaderBookmark>[];
      for (final item in value) {
        if (item is Map<String, dynamic>) {
          final bookmark = ReaderBookmark.fromJson(item);
          if (bookmark.id.isNotEmpty) list.add(bookmark);
        }
      }
      if (list.isNotEmpty) _byBook[bookId] = list;
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((bookId, value) {
      if (value is! List) return;
      final list = _byBook.putIfAbsent(bookId, () => <ReaderBookmark>[]);
      for (final item in value) {
        if (item is! Map<String, dynamic>) continue;
        final bookmark = ReaderBookmark.fromJson(item);
        if (bookmark.id.isEmpty) continue;
        if (list.any((existing) => existing.id == bookmark.id)) continue;
        list.add(bookmark);
        merged++;
      }
    });
    if (merged > 0) await _flush();
    return merged;
  }
}

// ---------- 阅读划线 ----------

/// 划线/批注存储（`aquan_markings.json`），按书归档。
class MarkingStore extends _JsonFileStore {
  MarkingStore({super.testDirectory}) : super('aquan_markings.json');

  final Map<String, List<ReaderMarking>> _byBook =
      <String, List<ReaderMarking>>{};

  /// 某本书的全部划线，按章号 + 起点升序。
  List<ReaderMarking> of(String bookId) {
    final list = List<ReaderMarking>.of(_byBook[bookId] ?? const []);
    list.sort((a, b) {
      final byChapter = a.chapterIndex.compareTo(b.chapterIndex);
      return byChapter != 0 ? byChapter : a.charStart.compareTo(b.charStart);
    });
    return list;
  }

  /// 某一章的划线（渲染时按行区间查交集）。
  List<ReaderMarking> inChapter(String bookId, String chapterId) => [
        for (final item in _byBook[bookId] ?? const <ReaderMarking>[])
          if (item.chapterId == chapterId) item,
      ];

  int countOf(String bookId) => _byBook[bookId]?.length ?? 0;

  Future<ReaderMarking?> add({
    required String bookId,
    required String chapterId,
    required int chapterIndex,
    required int charStart,
    required int charEnd,
    required String text,
    String chapterTitle = '',
    String note = '',
    MarkingColor color = MarkingColor.yellow,
  }) async {
    await ensureLoaded();
    if (charEnd <= charStart) return null;
    final list = _byBook.putIfAbsent(bookId, () => <ReaderMarking>[]);
    final marking = ReaderMarking(
      id: 'mk_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      bookId: bookId,
      chapterId: chapterId,
      chapterIndex: chapterIndex,
      charStart: charStart,
      charEnd: charEnd,
      text: text,
      chapterTitle: chapterTitle,
      note: note,
      color: color,
      createdAt: DateTime.now(),
    );
    list.add(marking);
    await _flush();
    return marking;
  }

  Future<void> updateNote(String bookId, String id, String note) async {
    await ensureLoaded();
    final list = _byBook[bookId];
    if (list == null) return;
    for (var i = 0; i < list.length; i++) {
      if (list[i].id == id) {
        list[i] = list[i].copyWith(note: note);
        await _flush();
        return;
      }
    }
  }

  Future<void> remove(String bookId, String id) async {
    await ensureLoaded();
    final list = _byBook[bookId];
    if (list == null) return;
    final before = list.length;
    list.removeWhere((item) => item.id == id);
    if (list.length == before) return;
    if (list.isEmpty) _byBook.remove(bookId);
    await _flush();
  }

  Future<void> clearBook(String bookId) async {
    await ensureLoaded();
    if (_byBook.remove(bookId) == null) return;
    await _flush();
  }

  /// 全量写盘（整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final entry in _byBook.entries)
            entry.key: <Map<String, dynamic>>[
              for (final item in entry.value) item.toJson(),
            ],
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _byBook.clear();
    json.forEach((bookId, value) {
      if (value is! List) return;
      final list = <ReaderMarking>[];
      for (final item in value) {
        if (item is Map<String, dynamic>) {
          final marking = ReaderMarking.fromJson(item);
          if (marking.id.isNotEmpty && marking.charEnd > marking.charStart) {
            list.add(marking);
          }
        }
      }
      if (list.isNotEmpty) _byBook[bookId] = list;
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    var merged = 0;
    incoming.forEach((bookId, value) {
      if (value is! List) return;
      final list = _byBook.putIfAbsent(bookId, () => <ReaderMarking>[]);
      for (final item in value) {
        if (item is! Map<String, dynamic>) continue;
        final marking = ReaderMarking.fromJson(item);
        if (marking.id.isEmpty || marking.charEnd <= marking.charStart) continue;
        if (list.any((existing) => existing.id == marking.id)) continue;
        list.add(marking);
        merged++;
      }
    });
    if (merged > 0) await _flush();
    return merged;
  }
}

// ---------- 正文替换规则 ----------

/// 替换规则存储（`aquan_replace_rules.json`）。
///
/// 内置规则随版本更新补入；用户删除内置项记为 disabled，可「恢复内置」找回。
class ReplaceRuleStore extends _JsonFileStore {
  ReplaceRuleStore({super.testDirectory})
      : super('aquan_replace_rules.json');

  final List<ReplaceRule> _custom = <ReplaceRule>[];
  final Set<String> _hiddenBuiltin = <String>{};
  final Map<String, bool> _builtinEnabled = <String, bool>{};

  /// 全部规则：内置（未隐藏）+ 自定义。
  List<ReplaceRule> get rules => <ReplaceRule>[
        for (final rule in kBuiltinReplaceRules)
          if (!_hiddenBuiltin.contains(rule.id))
            rule.copyWith(enabled: _builtinEnabled[rule.id] ?? rule.enabled),
        ..._custom,
      ];

  List<ReplaceRule> get enabled => rulesForBook(rules, '');

  /// 某本书实际生效的规则（含 book 作用域）。
  List<ReplaceRule> forBook(String bookId) => rulesForBook(rules, bookId);

  Future<void> setEnabled(String id, bool enabled) async {
    await ensureLoaded();
    if (kBuiltinReplaceRules.any((rule) => rule.id == id)) {
      _builtinEnabled[id] = enabled;
      if (enabled) _hiddenBuiltin.remove(id);
    } else {
      final index = _custom.indexWhere((rule) => rule.id == id);
      if (index >= 0) _custom[index] = _custom[index].copyWith(enabled: enabled);
    }
    await _flush();
  }

  Future<ReplaceRule> add({
    required String name,
    required String pattern,
    String replacement = '',
    bool isRegex = true,
    ReplaceScope scope = ReplaceScope.global,
    String bookId = '',
  }) async {
    await ensureLoaded();
    final rule = ReplaceRule(
      id: 'rr_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name.trim().isEmpty ? pattern : name.trim(),
      pattern: pattern,
      replacement: replacement,
      isRegex: isRegex,
      scope: scope,
      bookId: scope == ReplaceScope.book ? bookId : '',
    );
    _custom.add(rule);
    await _flush();
    return rule;
  }

  Future<void> update(ReplaceRule rule) async {
    await ensureLoaded();
    final index = _custom.indexWhere((item) => item.id == rule.id);
    if (index >= 0) _custom[index] = rule;
    await _flush();
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _custom.removeWhere((rule) => rule.id == id);
    if (kBuiltinReplaceRules.any((rule) => rule.id == id)) {
      _hiddenBuiltin.add(id);
    }
    await _flush();
  }

  Future<void> restoreBuiltin() async {
    await ensureLoaded();
    _hiddenBuiltin.clear();
    _builtinEnabled.clear();
    await _flush();
  }

  /// 全量写盘（规则整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'rules': <Map<String, dynamic>>[
            for (final rule in _custom) rule.toJson(),
          ],
          'hidden_builtin': _hiddenBuiltin.toList(),
          'builtin_enabled': _builtinEnabled,
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _custom.clear();
    _hiddenBuiltin.clear();
    _builtinEnabled.clear();
    final raw = json['rules'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final rule = ReplaceRule.fromJson(item);
          if (rule.id.isNotEmpty) {
            _custom.add(rule.copyWith(scope: rule.scope));
          }
        }
      }
    }
    final hidden = json['hidden_builtin'];
    if (hidden is List) {
      for (final item in hidden) {
        if (item is String) _hiddenBuiltin.add(item);
      }
    }
    final enabledMap = json['builtin_enabled'];
    if (enabledMap is Map) {
      enabledMap.forEach((key, value) {
        if (key is String && value is bool) _builtinEnabled[key] = value;
      });
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final raw = incoming['rules'] ?? incoming['replace_rules'];
    var merged = 0;
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final rule = ReplaceRule.fromJson(item);
        if (rule.id.isEmpty || rule.pattern.isEmpty) continue;
        if (_custom.any((existing) => existing.id == rule.id)) continue;
        _custom.add(rule);
        merged++;
      }
    }
    if (merged > 0) await _flush();
    return merged;
  }
}

/// 听书进度：与阅读进度**分开存**（`aquan_listen.json`），避免互相覆盖。
class ListenEntry {
  ListenEntry({
    required this.bookId,
    this.title = '',
    this.coverUrl = '',
    this.chapterId = '',
    this.chapterTitle = '',
    this.chapterIndex = 0,
    this.chapters = 0,
    this.toneId = 0,
    this.positionMs = 0,
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  final String bookId;
  final String title;
  final String coverUrl;
  final String chapterId;
  final String chapterTitle;
  final int chapterIndex;
  final int chapters;

  /// 用的音色 id（换音色会重新从头播，这里只记最后使用的）。
  final int toneId;

  /// 章内播放位置（毫秒）。
  final int positionMs;
  final DateTime updatedAt;

  Map<String, dynamic> toJson() => {
        'title': title,
        'cover_url': coverUrl,
        'chapter_id': chapterId,
        'chapter_title': chapterTitle,
        'chapter_index': chapterIndex,
        'chapters': chapters,
        'tone_id': toneId,
        'position_ms': positionMs,
        'updated_at': updatedAt.toIso8601String(),
      };

  factory ListenEntry.fromJson(String bookId, Map<String, dynamic> json) =>
      ListenEntry(
        bookId: bookId,
        title: json['title'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        chapterId: json['chapter_id'] as String? ?? '',
        chapterTitle: json['chapter_title'] as String? ?? '',
        chapterIndex: (json['chapter_index'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as num?)?.toInt() ?? 0,
        toneId: (json['tone_id'] as num?)?.toInt() ?? 0,
        positionMs: (json['position_ms'] as num?)?.toInt() ?? 0,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 听书进度存储（`aquan_listen.json`）。
class ListenProgressStore extends _JsonFileStore {
  ListenProgressStore({super.testDirectory}) : super('aquan_listen.json');

  final Map<String, ListenEntry> _entries = {};

  /// 最近在听的在前。
  List<ListenEntry> get entries {
    final list = _entries.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  ListenEntry? entry(String bookId) => _entries[bookId];

  Future<void> record({
    required String bookId,
    required String title,
    required String coverUrl,
    required String chapterId,
    required String chapterTitle,
    required int chapterIndex,
    required int chapters,
    required int toneId,
    required int positionMs,
  }) async {
    await ensureLoaded();
    _entries[bookId] = ListenEntry(
      bookId: bookId,
      title: title,
      coverUrl: coverUrl,
      chapterId: chapterId,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      chapters: chapters,
      toneId: toneId,
      positionMs: positionMs < 0 ? 0 : positionMs,
    );
    await _flush();
  }

  Future<void> remove(String bookId) async {
    await ensureLoaded();
    if (_entries.remove(bookId) == null) return;
    await _flush();
  }

  /// 全量写盘（听书进度整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          for (final e in _entries.entries) e.key: e.value.toJson(),
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    json.forEach((k, v) {
      if (v is Map<String, dynamic>) _entries[k] = ListenEntry.fromJson(k, v);
    });
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);
}
// ---------- 第三方影视源（TVBox / CMS）存储 ----------

/// 源注册表（`aquan_sources.json`）：id → 源配置，数组顺序即用户排序。
class SourcesStore extends _JsonFileStore {
  SourcesStore({super.testDirectory}) : super('aquan_sources.json');

  final Map<String, SourceConfig> _sources = {};

  List<SourceConfig> get all => List.of(_sources.values);
  List<SourceConfig> get enabled =>
      _sources.values.where((s) => s.enabled).toList();
  SourceConfig? byId(String id) => _sources[id];

  /// 按归一化 api 查（导入去重用）。
  SourceConfig? byApi(String api) {
    final norm = _normApi(api);
    for (final s in _sources.values) {
      for (final a in s.apis) {
        if (_normApi(a) == norm) return s;
      }
    }
    return null;
  }

  /// 批量入库候选源（按 api 归一化去重）；不可用候选（spider 等）跳过。
  /// 返回实际新增数。
  Future<int> addCandidates(List<SourceCandidate> candidates) async {
    await ensureLoaded();
    var added = 0;
    for (final c in candidates) {
      if (!c.usable) continue;
      if (byApi(c.api) != null) continue;
      final id = 's_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
          '_$added';
      _sources[id] = SourceConfig(
        id: id,
        name: c.name,
        apis: [c.api],
        kind: c.kind,
        spiderKey: c.spiderKey,
        headers: c.headers,
        note: c.note,
        ext: c.ext,
      );
      added++;
    }
    if (added > 0) await _flush();
    return added;
  }

  /// 手动添加单源（源管理页 / 导入 URL）。
  Future<SourceConfig> addManual({
    required String name,
    required String api,
    SourceKind kind = SourceKind.cmsJson,
    Map<String, String> headers = const {},
    String note = '',
  }) async {
    await ensureLoaded();
    final existing = byApi(api);
    if (existing != null) return existing;
    final id =
        's_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    final config = SourceConfig(
      id: id,
      name: name,
      apis: [api],
      kind: kind,
      headers: headers,
      note: note,
    );
    _sources[id] = config;
    await _flush();
    return config;
  }

  Future<void> remove(String id) async {
    if (_sources.remove(id) == null) return;
    await _flush();
  }

  Future<void> setEnabled(String id, bool value) async {
    final s = _sources[id];
    if (s == null || s.enabled == value) return;
    s.enabled = value;
    await _flush();
  }

  Future<void> togglePinned(String id) async {
    final s = _sources[id];
    if (s == null) return;
    s.pinned = !s.pinned;
    await _flush();
  }

  /// 重新排序：按 [orderedIds] 的顺序重建（缺失的排后面）。
  Future<void> reorder(Iterable<String> orderedIds) async {
    final next = <String, SourceConfig>{};
    for (final id in orderedIds) {
      final s = _sources.remove(id);
      if (s != null) next[id] = s;
    }
    _sources.addAll(next); // 剩余的按原顺序补在后面。
    await _flush();
  }

  String _normApi(String api) =>
      api.endsWith('/') ? api.substring(0, api.length - 1) : api;

  /// 全量写盘（源清单整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': 1,
          'sources': [for (final s in _sources.values) s.toJson()],
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _sources.clear();
    final list = json['sources'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final s = SourceConfig.fromJson(item);
        if (s.id.isNotEmpty) _sources[s.id] = s;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 备份恢复：按 id 合并（备份优先），本地独有的保留。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final list = incoming['sources'];
    if (list is! List) return 0;
    var merged = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final s = SourceConfig.fromJson(item);
      if (s.id.isEmpty) continue;
      _sources[s.id] = s;
      merged++;
    }
    if (merged > 0) await _flush();
    return merged;
  }
}

/// 源健康记录（`aquan_source_health.json`）：id → 记录；独立文件避免搜索期写放大。
class SourceHealthStore extends _JsonFileStore {
  SourceHealthStore({super.testDirectory}) : super('aquan_source_health.json');

  final Map<String, SourceHealthRecord> _health = {};

  /// 本次会话内最近一次主动测速结论（不落盘）：源管理与影视聚合共用同一
  /// 排序口径——测完 back 回影视聚合，「好源在前」仍然成立。
  final Map<String, ProbeOutcome> _probes = {};

  SourceHealthRecord recordOf(String sourceId) =>
      _health.putIfAbsent(sourceId, SourceHealthRecord.new);

  int scoreOf(String sourceId) => recordOf(sourceId).score;
  int latencyOf(String sourceId) => recordOf(sourceId).avgLatencyMs.round();
  bool coolingDown(String sourceId) => recordOf(sourceId).isCoolingDown();

  /// 最近一次主动测速结论；没测过返回 null（排序里排最后）。
  ProbeOutcome? probeOf(String sourceId) => _probes[sourceId];

  /// 记住一次主动测速结论。爬虫源的「恒失败」由调用方过滤，不进这里。
  void rememberProbe(ProbeOutcome outcome) {
    _probes[outcome.sourceId] = outcome;
  }

  Future<void> recordSuccess(String sourceId, int latencyMs) async {
    recordOf(sourceId).recordSuccess(latencyMs);
    await _flush();
  }

  Future<void> recordFailure(String sourceId, String reason,
      {bool playFailure = false}) async {
    recordOf(sourceId).recordFailure(reason, playFailure: playFailure);
    await _flush();
  }

  /// 全量写盘（健康记录整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  /// `_probes`（会话内主动测速记忆）依旧不落盘。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': 1,
          'health': {
            for (final e in _health.entries) e.key: e.value.toJson(),
          },
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _health.clear();
    final map = json['health'];
    if (map is Map) {
      map.forEach((k, v) {
        if (v is Map<String, dynamic>) {
          _health[k] = SourceHealthRecord.fromJson(v);
        }
      });
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final map = incoming['health'];
    if (map is! Map) return 0;
    var merged = 0;
    map.forEach((k, v) {
      if (v is! Map<String, dynamic>) return;
      final incomingRecord = SourceHealthRecord.fromJson(v);
      final current = _health[k.toString()];
      if (current == null ||
          incomingRecord.lastUsedAt >= current.lastUsedAt) {
        _health[k.toString()] = incomingRecord;
        merged++;
      }
    });
    if (merged > 0) await _flush();
    return merged;
  }
}

/// 自动找源的一条验证记录（按配置 URL 归一化键存储）。
///
/// 这是一份「历史结论」，不是站点列表：真正可用的配置会以自定义种子的形式
/// 写进 `SeedStore`，这里只负责判断「这个地址上次验证是什么结果」「该不该剔」。
class DiscoveryEntry {
  DiscoveryEntry({
    required this.name,
    required this.url,
    required this.origin,
    this.auto = true,
    this.usable = false,
    this.siteCount = 0,
    this.verifiedSites = 0,
    this.latencyMs = 0,
    this.checkedAt,
    this.message = '',
  });

  final String name;
  final String url;
  final DiscoveryOrigin origin;

  /// 由自动找源写入/维护。只有 `auto=true` 的条目允许被自动剔除。
  final bool auto;

  bool usable;
  int siteCount;
  int verifiedSites;
  int latencyMs;
  DateTime? checkedAt;
  String message;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'url': url,
        'origin': origin.name,
        'auto': auto,
        'usable': usable,
        'site_count': siteCount,
        'verified_sites': verifiedSites,
        'latency_ms': latencyMs,
        if (checkedAt != null)
          'checked_at': checkedAt!.millisecondsSinceEpoch,
        if (message.isNotEmpty) 'message': message,
      };

  factory DiscoveryEntry.fromJson(Map<String, dynamic> json) => DiscoveryEntry(
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        origin: DiscoveryOrigin.fromName(json['origin']),
        auto: json['auto'] as bool? ?? false,
        usable: json['usable'] as bool? ?? false,
        siteCount: (json['site_count'] as num?)?.toInt() ?? 0,
        verifiedSites: (json['verified_sites'] as num?)?.toInt() ?? 0,
        latencyMs: (json['latency_ms'] as num?)?.toInt() ?? 0,
        checkedAt: json['checked_at'] is num
            ? DateTime.fromMillisecondsSinceEpoch(
                (json['checked_at'] as num).toInt())
            : null,
        message: json['message'] as String? ?? '',
      );
}

/// 在线发现与合并快照的元数据（`aquan_source_discovery.json`）。
class SourceDiscoveryStore extends _JsonFileStore {
  SourceDiscoveryStore({super.testDirectory})
      : super('aquan_source_discovery.json');

  final Map<String, DiscoveryEntry> _entries = <String, DiscoveryEntry>{};

  DateTime? lastRunAt;
  DateTime? lastOkAt;
  String lastError = '';
  int failStreak = 0;

  /// 合并快照元信息（真身由 MergedSourceStore 读写）。
  int mergedSiteCount = 0;
  DateTime? mergedBuiltAt;

  Map<String, DiscoveryEntry> get entries => Map.unmodifiable(_entries);

  List<DiscoveryEntry> get all => List<DiscoveryEntry>.of(_entries.values);

  List<DiscoveryEntry> get autoEntries =>
      _entries.values.where((e) => e.auto).toList();

  DiscoveryEntry? entryOf(String url) => _entries[normalizeSeedUrl(url)];

  /// 最近一次运行的结果摘要（配置管理页展示）。
  String get statusText {
    if (lastRunAt == null) return '尚未运行';
    if (lastOkAt != null && lastError.isEmpty) {
      return '上次成功：${_timeText(lastOkAt!)}';
    }
    return lastError.isEmpty ? '上次运行：${_timeText(lastRunAt!)}' : lastError;
  }

  static String _timeText(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  Future<void> upsert(DiscoveryEntry entry) async {
    await ensureLoaded();
    _entries[normalizeSeedUrl(entry.url)] = entry;
    await _flush();
  }

  Future<void> upsertAll(Iterable<DiscoveryEntry> entries) async {
    await ensureLoaded();
    for (final entry in entries) {
      _entries[normalizeSeedUrl(entry.url)] = entry;
    }
    await _flush();
  }

  Future<void> removeUrl(String url) async {
    await ensureLoaded();
    if (_entries.remove(normalizeSeedUrl(url)) == null) return;
    await _flush();
  }

  Future<void> markRun({required bool ok, String error = ''}) async {
    await ensureLoaded();
    lastRunAt = DateTime.now();
    if (ok) {
      lastOkAt = lastRunAt;
      lastError = '';
      failStreak = 0;
    } else {
      lastError = error;
      failStreak++;
    }
    await _flush();
  }

  Future<void> markMerged(int siteCount) async {
    await ensureLoaded();
    mergedSiteCount = siteCount;
    mergedBuiltAt = DateTime.now();
    await _flush();
  }

  /// 全量写盘（找源记录整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': 1,
          if (lastRunAt != null) 'last_run_at': lastRunAt!.millisecondsSinceEpoch,
          if (lastOkAt != null) 'last_ok_at': lastOkAt!.millisecondsSinceEpoch,
          if (lastError.isNotEmpty) 'last_error': lastError,
          'fail_streak': failStreak,
          'merged': <String, dynamic>{
            'sites': mergedSiteCount,
            if (mergedBuiltAt != null)
              'built_at': mergedBuiltAt!.millisecondsSinceEpoch,
            'url': mergedSourceUrl,
          },
          'entries': <String, dynamic>{
            for (final e in _entries.entries) e.key: e.value.toJson(),
          },
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    final entries = json['entries'];
    if (entries is Map) {
      entries.forEach((key, value) {
        if (value is Map<String, dynamic>) {
          final entry = DiscoveryEntry.fromJson(value);
          if (entry.url.isNotEmpty) {
            _entries[normalizeSeedUrl(entry.url)] = entry;
          }
        }
      });
    }
    final lastRun = json['last_run_at'];
    lastRunAt = lastRun is num
        ? DateTime.fromMillisecondsSinceEpoch(lastRun.toInt())
        : null;
    final lastOk = json['last_ok_at'];
    lastOkAt = lastOk is num
        ? DateTime.fromMillisecondsSinceEpoch(lastOk.toInt())
        : null;
    lastError = json['last_error'] as String? ?? '';
    failStreak = (json['fail_streak'] as num?)?.toInt() ?? 0;
    final merged = json['merged'];
    if (merged is Map) {
      mergedSiteCount = (merged['sites'] as num?)?.toInt() ?? 0;
      final built = merged['built_at'];
      mergedBuiltAt = built is num
          ? DateTime.fromMillisecondsSinceEpoch(built.toInt())
          : null;
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final entries = incoming['entries'];
    if (entries is! Map) return 0;
    var merged = 0;
    entries.forEach((key, value) {
      if (value is! Map<String, dynamic>) return;
      final entry = DiscoveryEntry.fromJson(value);
      if (entry.url.isEmpty) return;
      _entries[normalizeSeedUrl(entry.url)] = entry;
      merged++;
    });
    if (merged > 0) await _flush();
    return merged;
  }
}

/// 源市场索引站与解析接口配置（`aquan_source_market.json`）。
class MarketSitesStore extends _JsonFileStore {
  MarketSitesStore({super.testDirectory})
      : super('aquan_source_market.json');

  final List<MarketSite> _sites = [];
  final List<ParseApi> _parses = [];

  List<MarketSite> get sites => List.of(_sites);
  List<MarketSite> get enabledSites =>
      _sites.where((s) => s.enabled).toList();
  List<ParseApi> get parses => List.of(_parses);

  Future<void> addSite(String name, String url) async {
    await ensureLoaded();
    final exists = _sites.any((s) => s.url == url);
    if (exists) return;
    _sites.add(MarketSite(
      id: 'm_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      url: url,
    ));
    await _flush();
  }

  Future<void> removeSite(String id) async {
    final before = _sites.length;
    _sites.removeWhere((s) => s.id == id);
    if (_sites.length != before) await _flush();
  }

  Future<void> setSiteEnabled(String id, bool value) async {
    final site = _sites.where((s) => s.id == id).firstOrNull;
    if (site == null || site.enabled == value) return;
    site.enabled = value;
    await _flush();
  }

  /// 预置索引站被删后可一键恢复。
  Future<void> resetBuiltin() async {
    await ensureLoaded();
    var changed = false;
    for (final builtin in builtinMarketSites) {
      if (_sites.any((s) => s.url == builtin.url)) continue;
      _sites.add(MarketSite(
        id: builtin.id,
        name: builtin.name,
        url: builtin.url,
        builtin: true,
      ));
      changed = true;
    }
    if (changed) await _flush();
  }

  Future<void> setParses(List<ParseApi> parses) async {
    _parses
      ..clear()
      ..addAll(parses);
    await _flush();
  }

  /// 导入配置时追加 parses：按 url 去重，不覆盖「源市场扫描」已得到的结果。
  Future<void> addParses(List<ParseApi> items) async {
    var changed = false;
    for (final p in items) {
      if (_parses.any((x) => x.url == p.url)) continue;
      _parses.add(p);
      changed = true;
    }
    if (changed) await _flush();
  }

  /// 全量写盘（索引站/解析接口整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  /// `loadFromDisk` 首次使用的内置站落盘也经此入队（不改读路径代码）。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': 1,
          'sites': [for (final s in _sites) s.toJson()],
          'parses': [
            for (final p in _parses)
              {'name': p.name, 'url': p.url, 'ext': p.ext},
          ],
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _sites.clear();
    _parses.clear();
    final sites = json['sites'];
    if (sites is List) {
      for (final item in sites) {
        if (item is! Map<String, dynamic>) continue;
        final site = MarketSite.fromJson(item);
        if (site.url.isNotEmpty) _sites.add(site);
      }
    }
    final parses = json['parses'];
    if (parses is List) {
      for (final item in parses) {
        if (item is! Map<String, dynamic>) continue;
        final url = item['url'];
        if (url is String && url.isNotEmpty) {
          _parses.add(ParseApi(
            name: item['name']?.toString() ?? '解析',
            url: url,
            ext: item['ext']?.toString() ?? '',
          ));
        }
      }
    }
    // 首次使用：种子内置索引站。
    if (_sites.isEmpty && json.isEmpty) {
      _sites.addAll(builtinMarketSites);
      await _flush();
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final sites = incoming['sites'];
    if (sites is! List) return 0;
    var merged = 0;
    for (final item in sites) {
      if (item is! Map<String, dynamic>) continue;
      final site = MarketSite.fromJson(item);
      if (site.url.isEmpty) continue;
      if (_sites.any((s) => s.url == site.url)) continue;
      _sites.add(site);
      merged++;
    }
    if (merged > 0) await _flush();
    return merged;
  }
}

/// 投屏设备记忆（`aquan_cast.json`）：最近设备 + 钉选设备 + 设备成功配方 +
/// 设备画像（v4）+ 会话恢复记录（`lastSession`，v4 加键）。
///
/// v4 配方为双层键：`udn:<udn>` 精确 + `model:<model|manufacturer>:<sinkHash>`
/// 共享；`profiles` 按设备记录能力画像。v1/v2/v3 旧文件读入兼容：
/// 旧三段式配方键与新查找语义不同，按设计视为空表并升 v4 回写
/// （`lastDevice` / `pinned` 原样保留；备份白名单仍只有 `cast` 键）。
/// `lastSession` 是设备相关的本机会话（代理 token / 路由源 IP 换机即失效），
/// **不进备份导出**（[exportData] 剥离该键）。
class CastStore extends _JsonFileStore implements CastSessionRecorder {
  CastStore({
    super.testDirectory,
    this.sessionPositionThrottle = const Duration(seconds: 10),
  }) : super('aquan_cast.json') {
    _recipes = CastRecipeStore(onChanged: _persistRecipes);
    _profiles = CastProfileStore(onChanged: _persistProfiles);
  }

  static const int formatVersion = 4;

  CastTarget? _lastDevice;
  final List<CastTarget> _pinned = [];
  late final CastRecipeStore _recipes;
  late final CastProfileStore _profiles;
  String? _receiverUdn;

  /// 会话恢复记录（R1）：控制器在投送成功/轮询/会话收尾写入；
  /// 损坏记录在 [loadFromDisk] 里静默清理。
  CastSessionRecord? _lastSession;

  /// 进度节流时钟：全量记录时重置，10s 窗口内的进度更新直接忽略。
  DateTime? _lastPositionWriteAt;

  /// 轮询进度落盘的最小间隔（R1.1：10s 节流）；测试可注入短窗口。
  final Duration sessionPositionThrottle;

  CastTarget? get lastDevice => _lastDevice;
  List<CastTarget> get pinned => List.of(_pinned);
  Set<String> get pinnedIds => _pinned.map((d) => d.id).toSet();

  /// 最近一次可恢复投屏会话（`aquan_cast.json` 的 `lastSession` 键）。
  /// null = 无记录或已清理（损坏/手动断开不删，只有清理才删）。
  @override
  CastSessionRecord? get lastSession => _lastSession;

  /// 投送成功：写全量恢复记录（镜像/本地文件会话由控制器排除）。
  /// [now] 仅供测试注入时钟。
  @override
  Future<void> recordSession({
    required CastTarget target,
    required String title,
    required String mediaUrl,
    int positionMs = 0,
    DateTime? now,
  }) async {
    await ensureLoaded();
    final at = now ?? DateTime.now();
    _lastSession = CastSessionRecord(
      targetPersistJson: target.toPersistJson(),
      title: title,
      mediaUrl: mediaUrl,
      positionMs: positionMs,
      endedAt: at,
    );
    _lastPositionWriteAt = at;
    await _persistLastSession();
  }

  /// 轮询进度：10s 节流（窗口内直接忽略），只改 positionMs 不动 endedAt
  /// （R1.1：endedAt 只在会话收尾更新）。无记录时 no-op。
  /// [now] 仅供测试注入时钟。
  @override
  Future<void> updateSessionPosition(int positionMs, {DateTime? now}) async {
    final record = _lastSession;
    if (record == null) return;
    final at = now ?? DateTime.now();
    final last = _lastPositionWriteAt;
    if (last != null && at.difference(last) < sessionPositionThrottle) return;
    _lastPositionWriteAt = at;
    _lastSession = CastSessionRecord(
      targetPersistJson: record.targetPersistJson,
      title: record.title,
      mediaUrl: record.mediaUrl,
      positionMs: positionMs,
      endedAt: record.endedAt,
    );
    await _persistLastSession();
  }

  /// 会话结束（手动断开/电视端停止）：只更新 endedAt，不删记录——重启后
  /// 仍可一键恢复（R1.2）。无记录时 no-op。镜像会话不会到达这里（控制器
  /// 按会话是否记录过守卫，不会误改上一条记录）。[now] 仅供测试注入时钟。
  @override
  Future<void> markSessionEnded({DateTime? now}) async {
    final record = _lastSession;
    if (record == null) return;
    _lastSession = CastSessionRecord(
      targetPersistJson: record.targetPersistJson,
      title: record.title,
      mediaUrl: record.mediaUrl,
      positionMs: record.positionMs,
      endedAt: now ?? DateTime.now(),
    );
    await _persistLastSession();
  }

  /// 静默清理（记录损坏时面板/载入侧调用）：删内存 + 落盘键；无键不写盘。
  @override
  Future<void> clearLastSession() async {
    _lastSession = null;
    _lastPositionWriteAt = null;
    var removed = false;
    await _updateJson((existing) {
      if (!existing.containsKey('lastSession')) return null;
      removed = true;
      final next = <String, dynamic>{...existing, 'version': formatVersion};
      next.remove('lastSession');
      return next;
    });
    if (!removed) return;
    notifyListeners();
  }

  /// 只更新 `lastSession` 字段：保留文件里的其它键（含未知字段），
  /// 不触碰设备记忆，也不要求先 `loadFromDisk()`。读改写整体入队
  ///（[_updateJson]，R3 并发回归锁）。
  Future<void> _persistLastSession() async {
    await _updateJson((existing) => <String, dynamic>{
          ...existing,
          'version': formatVersion,
          'lastSession': _lastSession?.toJson(),
        });
    notifyListeners();
  }

  /// 备份导出剥离 `lastSession`（R1 约束：设备相关，恢复只在本机有意义）。
  /// 白名单现状是 `cast` 键导出整个 `aquan_cast.json` 裸内容，所以在这里
  /// 剥键；导入侧 [importData] 本来就不读该键，双向都不出本机。
  @override
  Future<Map<String, dynamic>> exportData() async {
    final data = await super.exportData();
    data.remove('lastSession');
    return data;
  }

  /// 设备 → 成功配方（供 `CastController.recipes` 注入，跨启动生效）。
  CastRecipeStore get recipes => _recipes;

  /// 设备画像（供 `CastController.profiles` 注入；投屏成功后同步更新）。
  CastProfileStore get profiles => _profiles;

  /// 接收端 UDN（uuid；`aquan_cast.json` 的 `receiverUdn` 字段）。
  /// 缺省 null = 尚未开启过接收端。
  String? get receiverUdn => _receiverUdn;

  /// 取接收端 UDN，首次生成并持久化（v4 内新增字段：`...existing` 保留
  /// 未知键，旧备份恢复/旧版本读侧完全兼容）。
  Future<String> ensureReceiverUdn() async {
    await ensureLoaded();
    final existing = _receiverUdn;
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = uuidV4();
    _receiverUdn = generated;
    await _persistReceiverUdn();
    return generated;
  }

  /// 只更新 `receiverUdn` 字段：保留文件里的其它键，不触碰设备记忆。
  /// 读改写整体入队（[_updateJson]，R3 并发回归锁）。
  Future<void> _persistReceiverUdn() async {
    await _updateJson((existing) => <String, dynamic>{
          ...existing,
          'version': formatVersion,
          'receiverUdn': _receiverUdn,
        });
    notifyListeners();
  }

  /// 投到某设备时刷新「最近使用」。
  Future<void> touchLast(CastTarget device) async {
    _lastDevice = device;
    await _flush();
  }

  Future<void> togglePin(CastTarget device) async {
    final i = _pinned.indexWhere((d) => d.id == device.id);
    if (i >= 0) {
      _pinned.removeAt(i);
    } else {
      _pinned.add(device);
    }
    await _flush();
  }

  bool isPinned(String id) => _pinned.any((d) => d.id == id);

  Future<void> removePinned(String id) async {
    _pinned.removeWhere((d) => d.id == id);
    await _flush();
  }

  /// 只更新 `recipes` 字段：保留文件里的其它键（含未知字段），
  /// 不触碰设备记忆，也不要求先 `loadFromDisk()`。
  /// 读改写整体入队（[_updateJson]，R3 并发回归锁）。
  Future<void> _persistRecipes() async {
    await _updateJson((existing) => <String, dynamic>{
          ...existing,
          'version': formatVersion,
          'recipes': _recipes.toJson(),
        });
    notifyListeners();
  }

  /// 只更新 `profiles` 字段（投屏成功后画像同步落盘，与配方写入互不覆盖）。
  /// 读改写整体入队（[_updateJson]，R3 并发回归锁）。
  Future<void> _persistProfiles() async {
    await _updateJson((existing) => <String, dynamic>{
          ...existing,
          'version': formatVersion,
          'profiles': _profiles.toJson(),
        });
    notifyListeners();
  }

  /// v4 写入：`...existing` 保留未知字段与旧备份带回来的键；
  /// 版本号升到 4，v1/v2/v3 读侧完全兼容。
  /// 读改写整体入队（[_updateJson]，R3 并发回归锁）。
  Future<void> _flush() async {
    await _updateJson((existing) {
      final next = <String, dynamic>{...existing, 'version': formatVersion};
      if (_lastDevice != null) {
        next['lastDevice'] = _lastDevice!.toPersistJson();
      } else {
        next.remove('lastDevice');
      }
      next['pinned'] = [for (final d in _pinned) d.toPersistJson()];
      next['recipes'] = _recipes.toJson();
      next['profiles'] = _profiles.toJson();
      return next;
    });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    // 会话恢复记录（R1.4）：结构损坏 / 目标无法重建（旧 JSON/未知形态）→
    // 内存置空并静默清理落盘键（卡片不显示）。正常记录原样读回。
    var sessionKeyBroken = false;
    final sessionJson = json['lastSession'];
    if (sessionJson == null) {
      _lastSession = null;
    } else if (sessionJson is Map<String, dynamic>) {
      final record = CastSessionRecord.tryFromJson(sessionJson);
      _lastSession = record?.resolveTarget() != null ? record : null;
      if (_lastSession == null) sessionKeyBroken = true;
    } else {
      _lastSession = null;
      sessionKeyBroken = true;
    }
    _pinned.clear();
    final last = json['lastDevice'];
    if (last is Map<String, dynamic>) {
      _lastDevice = CastTarget.fromPersistJson(last);
    }
    final pinned = json['pinned'];
    if (pinned is List) {
      for (final item in pinned) {
        if (item is! Map<String, dynamic>) continue;
        // v1 条目无 protocol 字段，fromPersistJson 按 dlna 解析——完全兼容。
        final t = CastTarget.fromPersistJson(item);
        if (t != null) _pinned.add(t);
      }
    }
    // v4 读侧：recipes/profiles 只认 `udn:` / `model:` 前缀键。
    // v1/v2/v3（含缺 version 的更早文件）旧配方按设计视为空表——旧键与新
    // 查找语义不同，且旧版配方表从未接线落盘；读入后升 v4 回写。
    final version = json['version'] is int ? json['version'] as int : 0;
    final legacy = version < formatVersion;
    final recipes = json['recipes'];
    if (!legacy && recipes is Map) {
      _recipes.replaceAll(recipes.cast<String, dynamic>());
    } else {
      _recipes.clear();
    }
    final profiles = json['profiles'];
    if (!legacy && profiles is Map) {
      _profiles.replaceAll(profiles.cast<String, dynamic>());
    } else {
      _profiles.clear();
    }
    // 接收端 UDN：读侧直接认字段（首次生成走 ensureReceiverUdn）。
    final receiverUdn = json['receiverUdn'];
    if (receiverUdn is String && receiverUdn.isNotEmpty) {
      _receiverUdn = receiverUdn;
    }
    _loaded = true;
    if (legacy) {
      await _flush();
    }
    // 损坏键清理放在 legacy 回写之后：_flush 的 `...existing` 会把坏键带回
    // 文件，这里再定向删除，保证最终落盘状态干净。
    if (sessionKeyBroken) {
      await clearLastSession();
    }
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final last = incoming['lastDevice'];
    if (last is Map<String, dynamic>) {
      _lastDevice = CastTarget.fromPersistJson(last);
    }
    final pinned = incoming['pinned'];
    var merged = 0;
    if (pinned is List) {
      for (final item in pinned) {
        if (item is! Map<String, dynamic>) continue;
        final t = CastTarget.fromPersistJson(item);
        if (t == null) continue;
        if (_pinned.any((x) => x.id == t.id)) continue;
        _pinned.add(t);
        merged++;
      }
    }
    // 备份导入：只补本机没有的配方/画像，不覆盖已验证的成功策略；
    // 非 v4 前缀键（旧版三段式键）在 absorb 内被忽略。
    // 不并入 merged（它统计的是设备条目数，改变口径会破坏既有备份断言）。
    final recipes = incoming['recipes'];
    if (recipes is Map) {
      _recipes.absorb(recipes.cast<String, dynamic>());
    }
    final profiles = incoming['profiles'];
    if (profiles is Map) {
      _profiles.absorb(profiles.cast<String, dynamic>());
    }
    await _flush();
    return merged;
  }
}

/// 直播配置（`aquan_lives.json`）：频道清单 URL 列表 + 上次观看记忆。
class LiveEntry {
  LiveEntry({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.epg = '',
    DateTime? addedAt,
  }) : addedAt = addedAt ?? DateTime.now();

  factory LiveEntry.fromJson(Map<String, dynamic> json) => LiveEntry(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        url: json['url'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        epg: json['epg'] as String? ?? '',
        addedAt: DateTime.tryParse(json['added_at'] as String? ?? ''),
      );

  final String id;
  final String name;
  final String url;
  bool enabled;

  /// EPG 节目单地址（XMLTV/xml.gz，可空）。
  final String epg;
  final DateTime addedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        if (epg.isNotEmpty) 'epg': epg,
        'added_at': addedAt.toIso8601String(),
      };
}

class LivesStore extends _JsonFileStore {
  LivesStore({super.testDirectory}) : super('aquan_lives.json');

  final List<LiveEntry> _entries = <LiveEntry>[];
  String? _lastLiveId;
  String? _lastChannelName;

  List<LiveEntry> get all => List.of(_entries);
  List<LiveEntry> get enabled =>
      _entries.where((e) => e.enabled).toList();
  LiveEntry? byId(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  String? get lastLiveId => _lastLiveId;
  String? get lastChannelName => _lastChannelName;

  Future<void> setLastWatched(String liveId, String channelName) async {
    _lastLiveId = liveId;
    _lastChannelName = channelName;
    await _flush();
  }

  Future<int> addCandidates(List<LiveConfig> configs) async {
    await ensureLoaded();
    var added = 0;
    for (final c in configs) {
      if (_entries.any((e) => e.url == c.url)) continue;
      _entries.add(LiveEntry(
        id: 'l_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}_$added',
        name: c.name,
        url: c.url,
        epg: c.epg,
      ));
      added++;
    }
    if (added > 0) await _flush();
    return added;
  }

  Future<void> addManual({required String name, required String url}) async {
    await ensureLoaded();
    if (_entries.any((e) => e.url == url)) return;
    _entries.add(LiveEntry(
      id: 'l_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name,
      url: url,
    ));
    await _flush();
  }

  Future<void> remove(String id) async {
    _entries.removeWhere((e) => e.id == id);
    await _flush();
  }

  Future<void> setEnabled(String id, bool value) async {
    for (final e in _entries) {
      if (e.id == id && e.enabled != value) {
        e.enabled = value;
        await _flush();
        return;
      }
    }
  }

  /// 全量写盘（直播源整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'version': 1,
          'lives': [for (final e in _entries) e.toJson()],
          if (_lastLiveId != null) 'last_live_id': _lastLiveId,
          if (_lastChannelName != null) 'last_channel': _lastChannelName,
        });
    notifyListeners();
  }

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _entries.clear();
    final list = json['lives'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final e = LiveEntry.fromJson(item);
        if (e.id.isNotEmpty && e.url.isNotEmpty) _entries.add(e);
      }
    }
    _lastLiveId = json['last_live_id'] as String?;
    _lastChannelName = json['last_channel'] as String?;
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final list = incoming['lives'];
    var merged = 0;
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final e = LiveEntry.fromJson(item);
        if (e.url.isEmpty || _entries.any((x) => x.url == e.url)) continue;
        _entries.add(e);
        merged++;
      }
    }
    if (merged > 0) await _flush();
    return merged;
  }
}

// ---------- 源扫描种子 ----------

/// 源扫描种子清单（`aquan_source_seeds.json`）。
///
/// 内置项来自 `kBuiltinSeeds`（随版本更新自动补入）；用户可禁用、删除
/// （内置项记为 hidden，可在「恢复预置」后重新出现）、新增自定义项。
class SeedStore extends _JsonFileStore {
  SeedStore({super.testDirectory}) : super('aquan_source_seeds.json');

  final List<SourceSeed> _custom = <SourceSeed>[];
  final Set<String> _disabled = <String>{};
  final Set<String> _hidden = <String>{};

  /// 全部种子：内置（未被隐藏）+ 自定义。
  List<SourceSeed> get seeds {
    final out = <SourceSeed>[];
    for (final builtin in kBuiltinSeeds) {
      if (_hidden.contains(builtin.id)) continue;
      out.add(builtin);
    }
    for (final custom in _custom) {
      if (_hidden.contains(custom.id)) continue;
      out.add(custom);
    }
    return out;
  }

  List<SourceSeed> get enabled =>
      seeds.where((seed) => !_disabled.contains(seed.id)).toList();

  bool isEnabled(String id) => !_disabled.contains(id);

  int get builtinCount => kBuiltinSeeds.length;

  int get hiddenCount => _hidden.length;

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    _custom.clear();
    _disabled.clear();
    _hidden.clear();
    final raw = json['seeds'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final seed = SourceSeed.fromJson(item);
          if (seed.url.isNotEmpty) _custom.add(seed);
        }
      }
    }
    for (final key in <String>['disabled', 'hidden']) {
      final list = json[key];
      if (list is List) {
        for (final item in list) {
          if (item is String && item.isNotEmpty) {
            (key == 'disabled' ? _disabled : _hidden).add(item);
          }
        }
      }
    }
    _loaded = true;
    notifyListeners();
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 全量写盘（种子清单整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  /// 通知时机不变：`_flush` 不 notifyListeners，由各写者显式通知。
  Future<void> _flush() => _updateJson((existing) => <String, dynamic>{
        'seeds': <Map<String, dynamic>>[
          for (final seed in _custom) seed.toJson(),
        ],
        'disabled': _disabled.toList(),
        'hidden': _hidden.toList(),
      });

  Future<void> setEnabled(String id, bool enabled) async {
    await ensureLoaded();
    if (enabled) {
      _disabled.remove(id);
    } else {
      _disabled.add(id);
    }
    await _flush();
    notifyListeners();
  }

  Future<SourceSeed> add(String name, String url, SeedKind kind) async {
    await ensureLoaded();
    final seed = SourceSeed(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      name: name.trim().isEmpty ? url.trim() : name.trim(),
      url: url.trim(),
      kind: kind,
      builtin: false,
    );
    _custom.add(seed);
    await _flush();
    notifyListeners();
    return seed;
  }

  Future<void> remove(String id) async {
    await ensureLoaded();
    _custom.removeWhere((seed) => seed.id == id);
    if (kBuiltinSeedById.containsKey(id)) {
      _hidden.add(id);
    }
    await _flush();
    notifyListeners();
  }

  /// 恢复预置：清掉 hidden 与 disabled，并把内置项重新补回。
  Future<void> restoreBuiltin() async {
    await ensureLoaded();
    _hidden.clear();
    _disabled.clear();
    await _flush();
    notifyListeners();
  }

  /// 按分类取种子（种子管理界面用）。
  List<SourceSeed> byKind(SeedKind kind) =>
      seeds.where((seed) => seed.kind == kind).toList();

  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final raw = incoming['seeds'];
    var merged = 0;
    if (raw is List) {
      for (final item in raw) {
        if (item is! Map<String, dynamic>) continue;
        final seed = SourceSeed.fromJson(item);
        if (seed.url.isEmpty) continue;
        if (_custom.any((s) => s.url == seed.url)) continue;
        _custom.add(seed);
        merged++;
      }
    }
    if (merged > 0) {
      await _flush();
      notifyListeners();
    }
    return merged;
  }
}

// ---------- 小说阅读器设置 ----------

/// 阅读器全量设置（`aquan_reader_settings.json`）。
///
/// 旧版本把字号/行距/主题散落在 SharedPreferences 的 `reader.*` 键上；
/// 这里首次加载时做一次迁移，之后只读写本文件。
class ReaderSettingsStore extends _JsonFileStore {
  ReaderSettingsStore({super.testDirectory})
      : super('aquan_reader_settings.json');

  ReaderSettings _value = const ReaderSettings();

  ReaderSettings get value => _value;

  @override
  Future<void> loadFromDisk() async {
    final json = await _readJson();
    final raw = json['settings'];
    if (raw is Map<String, dynamic>) {
      _value = ReaderSettings.fromJson(raw);
    } else if (raw is Map) {
      _value = ReaderSettings.fromJson(raw.map((k, v) => MapEntry('$k', v)));
    } else {
      _value = await _migrateLegacy();
    }
    _loaded = true;
    notifyListeners();
  }

  /// 旧版 `reader.*` 偏好 → v2 设置。读到什么算什么，读不到用默认。
  Future<ReaderSettings> _migrateLegacy() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final hasLegacy = prefs.containsKey('reader.fontSize') ||
          prefs.containsKey('reader.lineHeight') ||
          prefs.containsKey('reader.theme') ||
          prefs.containsKey('reader.mode') ||
          prefs.containsKey('reader.pageAnim') ||
          prefs.containsKey('reader.autoTurn');
      if (!hasLegacy) return const ReaderSettings();

      final themes = List<ReaderThemeConfig>.of(defaultReaderThemes());
      final index =
          (prefs.getInt('reader.theme') ?? 0).clamp(0, themes.length - 1);
      final theme = themes[index];
      themes[index] = theme.copyWith(
        typography: theme.typography.copyWith(
          fontSize: (prefs.getDouble('reader.fontSize') ?? 19).clamp(14.0, 34.0),
          lineHeight:
              (prefs.getDouble('reader.lineHeight') ?? 1.8).clamp(1.2, 2.6),
        ),
      );
      return ReaderSettings(
        themes: themes,
        activeTheme: index,
        mode: (prefs.getInt('reader.mode') ?? 0) == 1
            ? ReaderMode.paged
            : ReaderMode.scroll,
        anim: switch (prefs.getInt('reader.pageAnim') ?? 0) {
          1 => ReaderPageAnim.cover,
          2 => ReaderPageAnim.curl,
          _ => ReaderPageAnim.slide,
        },
        autoTurn: prefs.getBool('reader.autoTurn') ?? false,
        autoIntervalSec:
            (prefs.getInt('reader.autoInterval') ?? 60).clamp(15, 300),
        nightMode: index == 2,
      );
    } catch (_) {
      return const ReaderSettings();
    }
  }

  @override
  Future<void> persist(Map<String, dynamic> json) => _writeJson(json);

  /// 整体替换并落盘。调用方负责只在真正变化时调用。
  Future<void> update(ReaderSettings next) async {
    _value = next;
    notifyListeners();
    await _flush();
  }

  /// 按书覆盖（VenHM 分层设置）：value=null 清除该字段回跟随全局。
  /// 字段取值见 [ReaderSettings.bookField*] 常量。
  Future<void> setBookOverride(
      String bookId, String field, Object? value) async {
    await ensureLoaded();
    await update(_value.withBookOverride(bookId, field, value));
  }

  /// 全量写盘（阅读设置整表覆写）。读改写整体入队（[_updateJson]，
  /// 11-08-store-race-final）：文档仍由内存态构建，入队后与其它写者串行，
  /// 并发混合写不再互相覆盖。顺序行为与旧版逐字节一致。
  /// 通知时机不变：[update] 仍是先 notifyListeners 再落盘。
  Future<void> _flush() async {
    await _updateJson((existing) => <String, dynamic>{
          'settings': _value.toJson(),
        });
  }

  /// 备份/还原用。
  @override
  Future<int> importData(Map<String, dynamic> incoming) async {
    await ensureLoaded();
    final raw = incoming['settings'];
    final map = raw is Map ? raw.map((k, v) => MapEntry('$k', v)) : null;
    if (map == null) return 0;
    _value = ReaderSettings.fromJson(map);
    await _flush();
    notifyListeners();
    return 1;
  }
}
