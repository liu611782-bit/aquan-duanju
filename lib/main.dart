import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'cli/command_bus.dart';
import 'cli/instance_server.dart';
import 'cli/launch_command.dart';
import 'cli/player_bus.dart';
import 'cli/search_cli.dart';
import 'core/aqua_api.dart';
import 'core/reader/reader_font_registrar.dart';
import 'core/reader/reader_speech_controller.dart';
import 'core/reader/speech/listen_media_bridge.dart';
import 'core/aqua_client.dart';
import 'core/aqua_error.dart';
import 'core/cast/cast_service.dart';
import 'core/cast/default_relay_resolver.dart';
import 'core/cast/default_resume_provider.dart';
import 'core/castd/receiver_admission.dart';
import 'core/castd/receiver_service.dart';
import 'core/download_service.dart';
import 'core/error_log.dart';
import 'models/models.dart';
import 'screens/detail_screen.dart';
import 'screens/home_screen.dart';
import 'screens/receiver_player_screen.dart';
import 'core/books/book_source_store.dart';
import 'core/ops_switches.dart';
import 'core/sources/auto_source_manager.dart';
import 'core/tv/tv_mode.dart';
import 'core/tv/tv_platform.dart';
import 'update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'store/stores.dart';
import 'theme/app_theme.dart';
import 'widgets/common.dart';
import 'widgets/receiver_admission_dialog.dart';
import 'widgets/tv_focus_scope.dart';
import 'widgets/tv_scope.dart';

/// 全局根导航：单实例转交过来的命令（AI 让「搜某部剧并播放」）需要
/// 从 App 顶层直接推详情页。
final rootNavigatorKey = GlobalKey<NavigatorState>();

bool get _isDesktop =>
    Platform.isWindows || Platform.isMacOS || Platform.isLinux;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 图片解码缓存上限 48MB（xiugou-tv 同策略）：默认 100MB 在低配机上长期跑会吃满内存。
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;
  _installErrorHandlers();
  try {
    await _start(args);
  } catch (error, stack) {
    ErrorLog.instance.record('启动', error, stack);
    runApp(_StartupFailureApp(message: '$error'));
  }
}

/// 真正的启动流程；任何异常都由 [main] 兜底成可见的错误页，避免白屏。
Future<void> _start(List<String> args) async {
  final command = LaunchCommand.parse(args);
  if (command.kind == 'help') {
    stdout.write(kCliHelp);
    exit(0);
  }
  if (command.kind == 'version') {
    stdout.writeln(AquaClient.coreVersion());
    exit(0);
  }

  final dir = await getApplicationSupportDirectory();
  final sep = Platform.pathSeparator;
  // 运维急停（app_ops.yaml）：只放「出事要立刻停」的开关，功能开关在应用内设置。
  await OpsSwitches.load(supportDirectory: dir);

  // 已有窗口在跑：把命令转交过去并带回回包，不再开第二个窗口。
  // --search 例外：它始终就地查询（转交过去反而拿不到列表输出）。
  final instanceFile = File('${dir.path}${sep}aquan_instance.json');
  if (!command.isEmpty && command.kind != 'search') {
    final reply = await SingleInstance.forward(instanceFile, command);
    if (reply != null) {
      if (command.json || LaunchCommand.isPlayerKind(command.kind)) {
        stdout.writeln(jsonEncode(reply));
      }
      exit(reply['ok'] == false ? 1 : 0);
    }
  }

  // 只查列表：不启动 UI，打印后退出（AI 助手取列表用）。
  if (command.kind == 'search') {
    await runSearchCli(command, '${dir.path}${sep}aquan_device.json');
  }

  MediaKit.ensureInitialized();
  // window_manager 的 native 句柄只在 ensureInitialized 后才绑定：
  // 缺了它 setFullScreen/setBounds/show 全部静默失效（窗口 API 全线失灵的根因）。
  if (_isDesktop) {
    try {
      await windowManager.ensureInitialized();
    } catch (e, stack) {
      ErrorLog.instance.record('窗口初始化', e, stack);
    }
  }
  final settings = await SettingsStore.load();
  // 运行形态只在启动时判定一次：TV 锁横屏，后续所有布局都读同一个结果。
  final formFactor = resolveFormFactor(
    isAndroid: Platform.isAndroid,
    isDesktop: _isDesktop,
    probe: await probeTvPlatform(),
    override: parseTvOverride(settings.tvMode),
  );
  if (formFactor == AppFormFactor.tv) {
    // 电视恒横屏；手机/桌面不动。
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    // 低端电视盒子内存/带宽都紧：图片缓存与并发降级一次，运行期不再变。
    AquaImageCache.instance.tvProfile = true;
  }
  SingleInstance? instance;
  // 单实例转交 / aquan-cli 只用于桌面端；Android 由系统 singleTop 管理，
  // 不需要绑定回环端口（也避免 release 权限问题拖垮启动）。
  if (_isDesktop) {
    try {
      instance = await SingleInstance.listen(
        instanceFile,
        (c) async {
          // 播放控制不依赖 App 状态（PlayerBus 是全局的），直接回包；
          // 开播类命令交给 App 导航，回包只表示已受理。
          if (LaunchCommand.isPlayerKind(c.kind)) {
            return PlayerBus.instance.dispatch(c);
          }
          CommandBus.instance.emit(c);
          return {'ok': true};
        },
        locatorDir: SingleInstance.locatorDir(),
      );
    } catch (error, stack) {
      // 某些系统 / 权限环境下回环端口不可用：降级为单窗口运行，
      // 不能因为「不能做单实例转交」就整页白屏。
      ErrorLog.instance.record('单实例', error, stack);
    }
  }
  if (!command.isEmpty) CommandBus.instance.emit(command);
  runApp(AquaApp(
    settings: settings,
    instance: instance,
    formFactor: formFactor,
  ));
}

/// 下载目录：优先用户自定义目录；不可写时回退到应用数据目录/downloads。
Future<Directory> _resolveDownloadDir(
    SettingsStore settings, Directory support) async {
  final custom = settings.downloadDir;
  if (custom != null) {
    final dir = Directory(custom);
    if (await DownloadService.ensureWritable(dir)) return dir;
  }
  final fallback =
      Directory('${support.path}${Platform.pathSeparator}downloads');
  await fallback.create(recursive: true);
  return fallback;
}

/// 全局错误收集：界面异常 / 未捕获异常都进内存错误日志（关于页可查看），
/// 但不改变原有的控制台输出与崩溃行为。
void _installErrorHandlers() {
  FlutterError.onError = (details) {
    ErrorLog.instance.record('界面', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    ErrorLog.instance.record('未捕获', error, stack);
    return true;
  };
}

/// 启动前失败时的兜底页：确保任何异常都可见，而不是停在白屏。
class _StartupFailureApp extends StatelessWidget {
  const _StartupFailureApp({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '阿圈短剧',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline_rounded,
                      size: 56, color: Colors.orangeAccent),
                  const SizedBox(height: 14),
                  const Text('阿圈短剧启动失败',
                      style: TextStyle(
                          fontSize: 20, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 10),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        message,
                        style: const TextStyle(
                            fontSize: 12, color: Colors.white70),
                      ),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    alignment: WrapAlignment.center,
                    children: [
                      FilledButton.icon(
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: message));
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('错误信息已复制')));
                          }
                        },
                        icon: const Icon(Icons.copy_rounded, size: 18),
                        label: const Text('复制错误'),
                      ),
                      OutlinedButton(
                        onPressed: () => exit(0),
                        child: const Text('退出'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '请把上面的错误信息反馈给开发者；若提示网络或权限，请检查系统网络与权限设置。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.white38),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 启动引导：设备注册 / 数据加载失败时给可重试的引导页，
/// 而不是卡死或白屏（fqapp「打开后一直卡在初始化」的同款问题）。
class AquaApp extends StatefulWidget {
  const AquaApp({
    super.key,
    required this.settings,
    required this.instance,
    this.formFactor = AppFormFactor.phone,
  });

  final SettingsStore settings;
  final SingleInstance? instance;

  /// 启动时判定一次的运行形态（手机 / 桌面 / 电视）。
  final AppFormFactor formFactor;

  @override
  State<AquaApp> createState() => _AquaAppState();
}

class _AquaAppState extends State<AquaApp> {
  /// DLNA 接收端接线（Phase B）：UDN 走 CastStore 持久化，来投会话开
  /// 接收端播放页（全屏路由）；开关关闭且页开着时 popUntil 精确关页。
  /// 投送准入（11-07-cast-receiver-advanced）：启动时把持久化的模式/名单
  /// 应用到策略；ask 模式的询问弹全局对话框（不依赖播放页打开，首投即问）。
  void _configureReceiver(CastStore cast) {
    final receiver = CastReceiverService.instance;
    receiver.udnLoader = cast.ensureReceiverUdn;
    receiver.admissionPromptHandler = (request) async {
      final context = rootNavigatorKey.currentContext;
      if (context == null) {
        // 导航未就绪（启动极早期来投）：按拒绝处理，由策略层兜底。
        return const AdmissionPromptOutcome(allow: false);
      }
      return showReceiverAdmissionDialog(
        context,
        ip: request.ip,
        userAgent: request.userAgent,
      );
    };
    receiver.applyAdmissionSettings(
      mode: widget.settings.castReceiverAdmissionMode,
      allowJson: widget.settings.castReceiverAllowIps,
      denyJson: widget.settings.castReceiverDenyIps,
    );
    receiver.openSessionPage = (session) {
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null) return false;
      navigator.push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          settings: const RouteSettings(name: ReceiverPlayerScreen.routeName),
          builder: (_) => const ReceiverPlayerScreen(),
        ),
      );
      return true;
    };
    receiver.closeSessionPage = () {
      rootNavigatorKey.currentState?.popUntil(
        (route) => route.settings.name != ReceiverPlayerScreen.routeName,
      );
    };
    unawaited(receiver.startIfEnabled(
      enabledFlag: widget.settings.castReceiverEnabled,
      name: widget.settings.castReceiverName,
    ));
  }

  AquaApi? _api;
  HistoryStore? _history;
  ReadingProgressStore? _reading;
  ListenProgressStore? _listening;
  BookChapterCache? _bookCache;
  FollowStore? _follows;
  SearchHistoryStore? _searches;
  PlaySkipStore? _playSkip;
  DetailSnapshotStore? _detailSnapshots;
  DownloadService? _downloads;
  SourcesStore? _sources;
  BookSourceStore? _bookSources;
  SourceHealthStore? _sourceHealth;
  MarketSitesStore? _marketSites;
  SeedStore? _seeds;
  SourceDiscoveryStore? _discovery;
  AutoSourceManager? _autoSource;
  BookmarkStore? _bookmarks;
  MarkingStore? _markings;
  ReplaceRuleStore? _replaceRules;
  PlaybackHealthStore? _playbackHealth;
  CastStore? _cast;
  LivesStore? _lives;
  ReaderSettingsStore? _readerSettings;
  ReaderSpeechController? _speech;
  Object? _error;
  int _attempt = 0;
  bool _handlingCommand = false;
  StreamSubscription<LaunchCommand>? _commandSub;

  bool get _ready =>
      _api != null &&
      _history != null &&
      _reading != null &&
      _listening != null &&
      _bookCache != null &&
      _follows != null &&
      _playSkip != null &&
      _detailSnapshots != null &&
      _sources != null &&
      _sourceHealth != null &&
      _marketSites != null &&
      _seeds != null &&
      _discovery != null &&
      _autoSource != null &&
      _bookmarks != null &&
      _markings != null &&
      _replaceRules != null &&
      _playbackHealth != null &&
      _cast != null &&
      _lives != null &&
      _speech != null;

  @override
  void initState() {
    super.initState();
    _commandSub = CommandBus.instance.stream.listen(_handleCommand);
    _bootstrap();
  }

  @override
  void dispose() {
    _commandSub?.cancel();
    _autoSource?.dispose();
    _speech?.dispose();
    widget.instance?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _error = null;
    });
    try {
      // 更新源地址来自设置：先绑定，检查更新时才能读到用户配置。
      UpdateService.instance.attachSettings(widget.settings);
      // 设备档案放应用支持目录（Android 私有目录 / 桌面用户配置目录）。
      final dir = await getApplicationSupportDirectory();
      final client = await AquaClient.create(
        '${dir.path}${Platform.pathSeparator}aquan_device.json',
      );
      final history = HistoryStore()
        ..limit = widget.settings.historyLimit;
      final reading = ReadingProgressStore();
      final listening = ListenProgressStore();
      final bookCache = BookChapterCache();
      final follows = FollowStore();
      final searches = SearchHistoryStore();
      final playSkip = PlaySkipStore();
      final detailSnapshots = DetailSnapshotStore();
      final downloads = DownloadStore();
      // 第三方影视源：启动即加载（索引站种子在 store 首载时写入）。
      final sources = SourcesStore();
      final bookSources = await SharedPreferences.getInstance().then((p) => BookSourceStore(p));
      final sourceHealth = SourceHealthStore();
      final marketSites = MarketSitesStore();
      final seeds = SeedStore();
      final discovery = SourceDiscoveryStore();
      final bookmarks = BookmarkStore();
      final markings = MarkingStore();
      final replaceRules = ReplaceRuleStore();
      final playbackHealth = PlaybackHealthStore();
      final cast = CastStore();
      final lives = LivesStore();
      final readerSettings = ReaderSettingsStore();
      await history.ensureLoaded();
      await reading.ensureLoaded();
      await listening.ensureLoaded();
      await bookCache.ensureLoaded();
      await follows.ensureLoaded();
      await searches.ensureLoaded();
      await playSkip.ensureLoaded();
      await detailSnapshots.ensureLoaded();
      await downloads.ensureLoaded();
      await sources.ensureLoaded();
      await sourceHealth.ensureLoaded();
      await marketSites.ensureLoaded();
      await seeds.ensureLoaded();
      await discovery.ensureLoaded();
      await bookmarks.ensureLoaded();
      await markings.ensureLoaded();
      await replaceRules.ensureLoaded();
      await playbackHealth.ensureLoaded();
      await cast.ensureLoaded();
      await lives.ensureLoaded();
      // M3-4：配方/画像持久化接线（修复 recipeStore 未注入，AC-14
      // 跨启动命中依赖这里）。R1：CastStore 兼任会话恢复记录器
      // （lastSession 持久化 + 一键恢复，cast_session_resume）。
      CastService.instance.attachStores(
        recipes: cast.recipes,
        profiles: cast.profiles,
        sessionRecorder: cast,
      );
      // DLNA 接收端（Phase B）：UDN 持久化 + 来投页路由；设置里开着则
      // 直接拉起（失败只进 ErrorLog，不阻断启动）。
      _configureReceiver(cast);
      await readerSettings.ensureLoaded();
      // 本地导入的阅读字体：重启后按记录过的路径重新注册。
      await ReaderFontRegistrar.ensureRegistered(
        readerSettings.value.effectiveThemes
            .map((theme) => theme.typography.fontFilePath),
      );
      if (!mounted) return;
      final api = AquaApi(client);
      // 恢复投屏等无播放页场景的兜底转码执行体（加密分集恢复不再回退直投）。
      CastService.instance.controller.defaultTranscodeResolver =
          defaultRelayResolver(api,
              quality: () => widget.settings.castRelayQuality);
      // 恢复投屏「跨天可用」（11-08-resume-reparse）：面板一键恢复按记录的
      // sourceId 重新解析分集拿新鲜 URL（红果直链带时效签名，跨天必失效）；
      // 加密分集走本机解密中继（与播放页同款）。解析失败回退记录 URL 现状
      // 分支，异常只进 ErrorLog。
      CastService.instance.controller.defaultResumeProvider =
          defaultResumeProvider(api,
              quality: () => widget.settings.castRelayQuality);
      // 全局听书控制器：挂在 AppScope 上，阅读页退出后仍可继续朗读。
      final speech = ReaderSpeechController(
        api: api,
        store: listening,
        // 朗读文本与阅读页同源：替换规则与简繁模式都从这两个 store 现取（只读注入）。
        rules: replaceRules,
        settings: readerSettings,
      );
      // 自动找源：启动 60s 后按缓存与开关决定是否联网（不阻塞首屏）。
      final autoSource = AutoSourceManager(
        seeds: seeds,
        sources: sources,
        discovery: discovery,
        marketSites: marketSites,
        settings: widget.settings,
      );
      // 系统媒体会话（通知栏/锁屏/耳机键）：只在 Android 上真正初始化，
      // 其他平台 ensure() 返回 null，此处零开销、零异常。
      unawaited(ListenMediaBridge.ensure());
      final downloadService = DownloadService(
        store: downloads,
        baseDir: await _resolveDownloadDir(widget.settings, dir),
        resolver:
            defaultResolver(api, () => widget.settings.cacheQuality),
        // 限速值每次下载读取，设置改动立即生效。
        downloader: (url, path, onProgress, isCancelled) => defaultDownloader(
          url,
          path,
          onProgress,
          isCancelled,
          maxBytesPerSecond: widget.settings.downloadSpeedKbps * 1024,
        ),
        concurrency: widget.settings.downloadConcurrency,
        maxRetries: widget.settings.downloadRetries,
      );
      setState(() {
        _api = api;
        _history = history;
        _reading = reading;
        _listening = listening;
        _bookCache = bookCache;
        _follows = follows;
        _searches = searches;
        _playSkip = playSkip;
        _detailSnapshots = detailSnapshots;
        _downloads = downloadService;
        _sources = sources;
        _bookSources = bookSources;
        _sourceHealth = sourceHealth;
        _marketSites = marketSites;
        _seeds = seeds;
        _discovery = discovery;
        _autoSource = autoSource;
        _bookmarks = bookmarks;
        _markings = markings;
        _replaceRules = replaceRules;
        _playbackHealth = playbackHealth;
        _cast = cast;
        _lives = lives;
        _readerSettings = readerSettings;
        _speech = speech;
      });
      autoSource.start();
      final pending = CommandBus.instance.takePending();
      if (pending != null) {
        // 此时只是 setState 完，根导航器要等下一帧才挂上；
        // 同步执行会拿不到 navigator，命令被静默丢掉。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _handleCommand(pending);
        });
      }
    } catch (e, stack) {
      ErrorLog.instance.record('启动', e, stack);
      if (!mounted) return;
      setState(() {
        _error = e;
        _attempt++;
      });
    }
  }

  /// 执行 AI / 命令行转交过来的命令；返回值作为单实例通道的回包。
  Future<Map<String, dynamic>> _handleCommand(LaunchCommand command) async {
    if (command.isEmpty || !_ready) return {'ok': true};
    // 投屏控制同样不抢窗口焦点：恢复/断开走全局 CastService。
    if (command.kind == 'cast') {
      final ok = await CastService.instance.controller.resumeLastSession();
      return ok
          ? {'ok': true}
          : {'ok': false, 'error': '没有可恢复的投屏记录，或恢复失败'};
    }
    if (command.kind == 'cast_stop') {
      await CastService.instance.controller.disconnect();
      return {'ok': true};
    }
    if (command.kind == 'cast_series') {
      final episode = command.episode > 0 ? command.episode : 1;
      final error = await CastService.instance.controller
          .castSeriesToLastTarget(command.value, episode);
      return error == null
          ? {'ok': true}
          : {'ok': false, 'error': error};
    }
    // 播放控制不需要抢窗口焦点，直接下发给当前播放器。
    if (LaunchCommand.isPlayerKind(command.kind)) {
      return PlayerBus.instance.dispatch(command);
    }
    if (_handlingCommand) return {'ok': false, 'error': '上一条命令还在执行'};
    _handlingCommand = true;
    try {
      if (_isDesktop) {
        try {
          await windowManager.show();
          await windowManager.focus();
        } catch (_) {}
      }
      final navigator = rootNavigatorKey.currentState;
      if (navigator == null) return {'ok': false, 'error': '界面未就绪'};
      if (command.kind == 'series') {
        navigator.push(MaterialPageRoute(
          builder: (_) => DetailScreen(
            seriesId: command.value,
            autoplay: true,
            startEpisode: command.episode,
          ),
        ));
        return {'ok': true};
      } else if (command.kind == 'watch') {
        final page = await _api!.search(command.value, pageSize: command.limit);
        if (page.items.isEmpty) {
          _toast('没搜到《${command.value}》');
          return {'ok': false, 'error': '没搜到《${command.value}》'};
        }
        final best = _bestMatch(command.value, page.items);
        navigator.push(MaterialPageRoute(
          builder: (_) => DetailScreen(
            seriesId: best.id,
            title: best.title,
            autoplay: true,
          ),
        ));
        return {'ok': true, 'message': '正在播放《${best.title}》'};
      }
      return {'ok': false, 'error': '未知命令 ${command.kind}'};
    } catch (e) {
      _toast(e is AquaException ? e.friendlyText : '命令执行失败：$e');
      return {'ok': false, 'error': e.toString()};
    } finally {
      _handlingCommand = false;
    }
  }

  /// 搜索结果里挑最匹配的一部：完全相等 > 前缀 > 包含 > 接口第一条。
  static SeriesSummary _bestMatch(String query, List<SeriesSummary> items) {
    String norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final q = norm(query);
    SeriesSummary? best;
    var bestScore = 0;
    for (final item in items) {
      final t = norm(item.title);
      final score = q == t
          ? 100
          : t.startsWith(q)
              ? 80
              : t.contains(q)
                  ? 60
                  : 0;
      if (score > bestScore) {
        bestScore = score;
        best = item;
      }
    }
    return best ?? items.first;
  }

  void _toast(String text) {
    final context = rootNavigatorKey.currentContext;
    if (context == null) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) {
      return AppScope(
        notifier: widget.settings,
        api: _api!,
        settings: widget.settings,
        history: _history!,
        reading: _reading!,
        listening: _listening!,
        bookCache: _bookCache!,
        follows: _follows!,
        searches: _searches!,
        playSkip: _playSkip!,
        downloads: _downloads!,
        detailSnapshots: _detailSnapshots!,
        sources: _sources!,
        bookSources: _bookSources!,
        sourceHealth: _sourceHealth!,
        marketSites: _marketSites!,
        seeds: _seeds!,
        discovery: _discovery!,
        autoSource: _autoSource!,
        bookmarks: _bookmarks!,
        markings: _markings!,
        replaceRules: _replaceRules!,
        playbackHealth: _playbackHealth!,
        cast: _cast!,
        lives: _lives!,
        readerSettings: _readerSettings!,
        speech: _speech!,
        child: TvScope(
          formFactor: widget.formFactor,
          child: AnimatedBuilder(
            animation: widget.settings,
            builder: (context, _) => MaterialApp(
              title: '阿圈短剧',
              debugShowCheckedModeBanner: false,
              navigatorKey: rootNavigatorKey,
              theme: AppTheme.light(),
              darkTheme: AppTheme.dark(),
              themeMode: AppTheme.modeOf(widget.settings),
              // 电视上让方向键优先移动焦点：包在 MaterialApp.builder 里才能覆盖
              // 所有路由（含 push 出来的详情/播放页）。
              builder: (context, child) => TvFocusScope(
                enabled: TvScope.isTvOf(context),
                child: child ?? const SizedBox.shrink(),
              ),
              home: const HomeScreen(),
            ),
          ),
        ),
      );
    }
    final text = _error is AquaException
        ? (_error as AquaException).friendlyText
        : '初始化需要联网完成设备注册，请检查网络后重试';
    return AnimatedBuilder(
      animation: widget.settings,
      builder: (context, _) => MaterialApp(
        title: '阿圈短剧',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: AppTheme.modeOf(widget.settings),
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.wifi_off_outlined,
                    size: 56, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(text, textAlign: TextAlign.center),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _bootstrap,
                  icon: const Icon(Icons.refresh),
                  label: Text(_attempt > 0 ? '再试一次' : '重试'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
