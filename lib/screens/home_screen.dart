import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import '../core/ops_switches.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/window_geometry.dart';
import '../update/update_service.dart';
import '../widgets/common.dart';
import '../widgets/reader/reader_audio_bar.dart';

import 'discover_screen.dart';
import 'mine_screen.dart';
import 'random_feed_screen.dart';
import 'rankings_screen.dart';
import 'search_screen.dart';

/// 应用壳：Android 底部导航 / Windows 左侧导航栏，四个 tab。
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WindowListener {
  int _tab = 0;
  Rect? _savedRect;
  Timer? _boundsSaveTimer;

  static const _tabs = [
    (Icons.explore_outlined, Icons.explore, '发现'),
    (Icons.shuffle_outlined, Icons.shuffle, '随机'),
    (Icons.leaderboard_outlined, Icons.leaderboard, '榜单'),
    (Icons.person_outline, Icons.person, '我的'),
  ];

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (Platform.isWindows || Platform.isMacOS || Platform.isLinux)) {
      _initWindow();
    }
    // 启动后半分钟静默查一次新版本，失败不打扰；提示出现在「我的」页。
    // 开关与运维急停都在触发时现读，改设置不用重启。
    Timer(const Duration(seconds: 30), () {
      if (!mounted) return;
      final settings = AppScope.read(context).settings;
      if (!settings.autoCheckUpdate || OpsSwitches.disableAutoUpdate) return;
      UpdateService.instance.checkQuietly();
    });
  }

  Future<void> _initWindow() async {
    final saved = AppScope.read(context).settings.windowBounds;
    await windowManager.ensureInitialized();
    windowManager.addListener(this);
    var geometry = WindowGeometryGuard.sanitize(null);
    if (saved != null) {
      try {
        final raw = jsonDecode(saved) as Map<String, dynamic>;
        final rect = Rect.fromLTWH(
          (raw['x'] as num).toDouble(),
          (raw['y'] as num).toDouble(),
          (raw['w'] as num).toDouble(),
          (raw['h'] as num).toDouble(),
        );
        // 多显示器工作区用于判断保存的位置是否还看得见；取不到时退化为
        // 「只剔除明显的最小化占位坐标」。
        var workAreas = const <Rect>[];
        try {
          final displays = await screenRetriever.getAllDisplays();
          workAreas = [
            for (final d in displays)
              Rect.fromLTWH(
                d.visiblePosition?.dx ?? 0,
                d.visiblePosition?.dy ?? 0,
                d.visibleSize?.width ?? d.size.width,
                d.visibleSize?.height ?? d.size.height,
              ),
          ];
        } catch (_) {}
        geometry = WindowGeometryGuard.sanitize(rect, workAreas: workAreas);
      } catch (_) {}
    }
    _savedRect = geometry.position == null
        ? null
        : Rect.fromLTWH(geometry.position!.dx, geometry.position!.dy,
            geometry.size.width, geometry.size.height);
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        title: '阿圈短剧',
        minimumSize: const Size(380, 480),
        size: geometry.size,
        center: geometry.position == null,
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        final rect = _savedRect;
        if (rect != null) {
          // WindowOptions 没有 position 参数，位置在显示前 setBounds。
          await windowManager.setBounds(rect);
        } else {
          await windowManager.center();
        }
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  /// 拖动/缩放会连续触发，节流 800ms 落盘一次。
  void _scheduleSaveBounds() {
    _boundsSaveTimer?.cancel();
    _boundsSaveTimer = Timer(const Duration(milliseconds: 800), _saveBounds);
  }

  Future<void> _saveBounds() async {
    if (!mounted) return;
    final settings = AppScope.read(context).settings;
    // 迷你小窗的尺寸不落盘，还原后的正常窗口才值得记住。
    if (settings.miniWindowActive) return;
    try {
      // 最小化 / 最大化时 Windows 给的是占位几何，不落盘。
      final minimized = await windowManager.isMinimized();
      if (minimized || await windowManager.isMaximized()) return;
      final bounds = await windowManager.getBounds();
      if (!WindowGeometryGuard.isPersistable(
          minimized: minimized, size: bounds.size)) {
        return;
      }
      settings.windowBounds = jsonEncode({
        'x': bounds.left,
        'y': bounds.top,
        'w': bounds.width,
        'h': bounds.height,
      });
    } catch (_) {}
  }

  @override
  void onWindowClose() async {
    await _saveBounds();
    await windowManager.destroy();
  }

  @override
  void onWindowResize() => _scheduleSaveBounds();

  @override
  void onWindowMove() => _scheduleSaveBounds();

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final pages = [
      const DiscoverScreen(),
      RandomFeedScreen(active: _tab == 1),
      const RankingsScreen(),
      const MineScreen(),
    ];
    final speech = AppScope.read(context).speech;
    return Focus(
      autofocus: true,
      onKeyEvent: _onKeyEvent,
      child: Scaffold(
        body: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final t in _tabs)
                    NavigationRailDestination(
                      icon: Icon(t.$1),
                      selectedIcon: Icon(t.$2),
                      label: Text(t.$3),
                    ),
                ],
                trailing: IconButton(
                  icon: const Icon(Icons.search),
                  tooltip: '搜索',
                  onPressed: () => showSearchScreen(context),
                ),
              ),
            VerticalDivider(width: 1, thickness: 1,
                color: Theme.of(context).colorScheme.surfaceContainerHighest),
            Expanded(child: IndexedStack(index: _tab, children: pages)),
          ],
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (speech.isActive) _miniSpeechBar(speech),
            if (!wide)
              NavigationBar(
                selectedIndex: _tab,
                onDestinationSelected: (i) => setState(() => _tab = i),
                destinations: [
                  for (final t in _tabs)
                    NavigationDestination(
                      icon: Icon(t.$1),
                      selectedIcon: Icon(t.$2),
                      label: t.$3,
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  /// 全局迷你听书条：朗读中离开阅读页也能控制。
  Widget _miniSpeechBar(ReaderSpeechController controller) =>
      ListenableBuilder(
        listenable: controller,
        builder: (context, _) => MiniSpeechBar(controller: controller),
      );

  /// 桌面全局快捷键：Ctrl+F 搜索、Ctrl+1..4 切页、F11 窗口全屏。
  /// 播放器页的按键它自己处理，未处理的会冒泡到这里（如 F11）。
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (HardwareKeyboard.instance.isControlPressed) {
      if (key == LogicalKeyboardKey.keyF || key == LogicalKeyboardKey.keyK) {
        showSearchScreen(context);
        return KeyEventResult.handled;
      }
      final digitTabs = {
        LogicalKeyboardKey.digit1: 0,
        LogicalKeyboardKey.digit2: 1,
        LogicalKeyboardKey.digit3: 2,
        LogicalKeyboardKey.digit4: 3,
      };
      final tab = digitTabs[key];
      if (tab != null) {
        setState(() => _tab = tab);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11) {
      windowManager.isFullScreen().then((full) async {
        await windowManager.setFullScreen(!full);
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}
