import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../core/aqua_error.dart';
import '../core/reader/reader_click_action.dart';
import '../core/reader/reader_page_metrics.dart';
import '../core/reader/reader_paginator.dart';
import '../core/reader/reader_paragraphs.dart';
import '../core/reader/reader_speech_controller.dart';
import '../core/reader/reader_speech_settings.dart';
import '../core/reader/speech_follow_gate.dart';
import '../core/reader/reader_settings.dart';
import '../core/reader/reader_theme.dart';
import '../core/reader/reader_typography.dart';
import '../widgets/continuous_chapters.dart';
import '../widgets/reader/follow_pill.dart';
import '../widgets/reader/reader_audio_bar.dart';
import '../widgets/reader/reader_page_view.dart';
import '../widgets/reader/reader_pager.dart';
import '../widgets/reader/reader_settings_sheet.dart';
import '../widgets/reader/sleep_sheet.dart';
import 'replace_rules_screen.dart';
import '../core/reader/content_signature.dart';
import '../models/book.dart';
import '../store/stores.dart';
import '../widgets/book_directory_sheet.dart';
import '../widgets/common.dart';
import '../widgets/reader/reader_click_zone_editor.dart';

/// 本章内搜索面板。
class _ChapterSearchSheet extends StatefulWidget {
  const _ChapterSearchSheet({
    required this.paragraphs,
    required this.onJump,
  });

  final List<String> paragraphs;

  /// 命中项在章内的字符偏移。
  final ValueChanged<int> onJump;

  @override
  State<_ChapterSearchSheet> createState() => _ChapterSearchSheetState();
}

class _ChapterSearchSheetState extends State<_ChapterSearchSheet> {
  static const int _maxHits = 100;

  final _controller = TextEditingController();
  List<_SearchHit> _hits = const <_SearchHit>[];
  String _query = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _search(String raw) {
    final query = raw.trim().toLowerCase();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() => _hits = const <_SearchHit>[]);
      return;
    }
    final hits = <_SearchHit>[];
    // 段落之间的分隔符算 1 个字符，与分页器的字符偏移口径一致。
    var paragraphStart = 0;
    for (var i = 0; i < widget.paragraphs.length; i++) {
      final text = widget.paragraphs[i];
      final lower = text.toLowerCase();
      var from = 0;
      while (hits.length < _maxHits) {
        final index = lower.indexOf(query, from);
        if (index < 0) break;
        final snippet = _snippet(text, index, query.length);
        hits.add(_SearchHit(
          paragraph: i,
          charOffset: paragraphStart + index,
          snippet: snippet.$1,
          snippetIndex: snippet.$2,
          matchLength: query.length,
        ));
        from = index + query.length;
      }
      paragraphStart += text.length + 1;
      if (hits.length >= _maxHits) break;
    }
    setState(() => _hits = hits);
  }

  /// 返回（片段, 命中词在片段里的下标）。
  static (String, int) _snippet(String text, int start, int length) {
    final from = (start - 12).clamp(0, text.length);
    final to = (start + length + 12).clamp(0, text.length);
    final prefix = from > 0 ? '…' : '';
    final suffix = to < text.length ? '…' : '';
    return ('$prefix${text.substring(from, to)}$suffix',
        prefix.length + (start - from));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FractionallySizedBox(
      heightFactor: 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              onChanged: _search,
              decoration: InputDecoration(
                hintText: '本章内查找',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    _hits.isEmpty ? '没有找到「$_query」' : '${_hits.length} 处命中',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _hits.isEmpty
                ? Center(
                    child: Text(
                      _query.isEmpty ? '输入关键词开始查找' : '换个词试试',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                : ListView.builder(
                    itemCount: _hits.length,
                    itemBuilder: (context, i) {
                      final hit = _hits[i];
                      return ListTile(
                        dense: true,
                        leading: Text(
                          '${hit.paragraph + 1}',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: theme.colorScheme.outline),
                        ),
                        title: _highlight(theme, hit),
                        onTap: () => widget.onJump(hit.charOffset),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  /// 命中词加粗高亮。
  Widget _highlight(ThemeData theme, _SearchHit hit) {
    final base = theme.textTheme.bodyMedium;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: hit.snippet.substring(0, hit.snippetIndex)),
          TextSpan(
            text: hit.snippet.substring(
              hit.snippetIndex,
              (hit.snippetIndex + hit.matchLength).clamp(0, hit.snippet.length),
            ),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          TextSpan(
            text: hit.snippet.substring(
              (hit.snippetIndex + hit.matchLength).clamp(0, hit.snippet.length),
            ),
          ),
        ],
      ),
      style: base,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _SearchHit {
  const _SearchHit({
    required this.paragraph,
    required this.charOffset,
    required this.snippet,
    required this.snippetIndex,
    required this.matchLength,
  });

  final int paragraph;
  final int charOffset;
  final String snippet;

  /// 命中词在 [snippet] 里的下标。
  final int snippetIndex;
  final int matchLength;
}

/// 书签与划线面板。
class _BookmarkSheet extends StatelessWidget {
  const _BookmarkSheet({
    required this.store,
    required this.markings,
    required this.bookId,
    required this.onJump,
  });

  final BookmarkStore store;
  final MarkingStore markings;
  final String bookId;

  /// 跳转到某章某字符位置。
  final Future<void> Function(int chapterIndex, int charOffset) onJump;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[store, markings]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final bookmarkList = store.of(bookId);
        final markingList = markings.of(bookId);
        if (bookmarkList.isEmpty && markingList.isEmpty) {
          return SizedBox(
            height: 220,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bookmarks_outlined,
                      size: 40, color: theme.colorScheme.outline),
                  const SizedBox(height: 10),
                  Text('还没有书签', style: theme.textTheme.bodyMedium),
                  const SizedBox(height: 4),
                  Text(
                    '长按正文选字可划线；九宫格「添加书签」可存位置',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
          );
        }
        return FractionallySizedBox(
          heightFactor: 0.8,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text('书签与划线', style: theme.textTheme.titleMedium),
                    const Spacer(),
                    Text(
                      '${bookmarkList.length} 书签 · ${markingList.length} 划线',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              const Divider(height: 16),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.only(bottom: 24),
                  children: [
                    if (bookmarkList.isNotEmpty)
                      _sectionHeader(theme, '书签'),
                    for (final bookmark in bookmarkList)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.bookmark, size: 18),
                        title: Text(
                          bookmark.chapterTitle.isEmpty
                              ? '第 ${bookmark.chapterIndex + 1} 章'
                              : bookmark.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          bookmark.excerpt.isEmpty
                              ? '位置 ${bookmark.charOffset}'
                              : bookmark.excerpt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        onTap: () => onJump(
                            bookmark.chapterIndex, bookmark.charOffset),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => store.remove(bookId, bookmark.id),
                        ),
                      ),
                    if (markingList.isNotEmpty) _sectionHeader(theme, '划线'),
                    for (final marking in markingList)
                      ListTile(
                        dense: true,
                        leading: Container(
                          width: 14,
                          height: 14,
                          decoration: BoxDecoration(
                            color: Color(marking.color.argb),
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                        title: Text(
                          marking.text,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          marking.chapterTitle.isEmpty
                              ? '第 ${marking.chapterIndex + 1} 章'
                              : marking.chapterTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                        onTap: () => onJump(
                            marking.chapterIndex, marking.charStart),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => markings.remove(bookId, marking.id),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionHeader(ThemeData theme, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      );
}

/// 阅读主题：纸张 / 白底 / 夜间。
class _ReaderTheme {
  const _ReaderTheme(this.name, this.background, this.foreground);

  final String name;
  final Color background;
  final Color foreground;
}

/// 跨章加载完成后要落到的位置。
enum _ChapterLanding { keep, first, last }

/// 小说阅读页：滚动阅读 + 目录抽屉 + 字号/行距/主题 + 进度记忆。
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.bookId,
    required this.bookTitle,
    required this.chapters,
    this.coverUrl = '',
    this.initialIndex = 0,
    this.restoreOffset = 0,
    this.restoreCharOffset = -1,
    this.autoListen = false,
  });

  final String bookId;
  final String bookTitle;
  final String coverUrl;
  final List<BookChapter> chapters;
  final int initialIndex;

  /// 首次进入时还原到该章内的相对位置（0..1）。
  final double restoreOffset;

  /// 章内字符偏移；`>= 0` 时优先于 [restoreOffset]。
  final int restoreCharOffset;

  /// 首章加载完成后**自动开始朗读**（从“无音轨听书页”跳进来时用）。
  ///
  /// 默认 false：正常进阅读页不应抢用户操作；只有用户刚在听书页点过
  /// “去阅读页听书”，意图才明确到可以代他点一下。
  final bool autoListen;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _cache = <String, List<String>>{};

  /// 自绘翻页容器：6 种动画与手势都在 [ReaderPager] 内部。
  final _pager = ReaderPagerController();

  late final ReadingProgressStore _store = AppScope.read(context).reading;
  late final BookChapterCache _cacheStore = AppScope.read(context).bookCache;
  late final BookmarkStore _bookmarks = AppScope.read(context).bookmarks;
  late final MarkingStore _markings = AppScope.read(context).markings;
  late final ReplaceRuleStore _replaceRules = AppScope.read(context).replaceRules;

  /// 九宫格动作与分区几何的唯一来源（S2 起排版设置也走这里）。
  late final ReaderSettingsStore _settingsStore =
      AppScope.read(context).readerSettings;

  /// 连续阅读体控制器：滚动模式的「翻一屏」由它执行。
  final ContinuousChaptersController _continuous = ContinuousChaptersController();

  late int _index = widget.initialIndex.clamp(0, _maxIndex);

  /// 跨章后要落到首页还是末页（`_afterLoad` 消费一次）。
  _ChapterLanding _landing = _ChapterLanding.keep;

  List<String>? _paragraphs;

  /// 翻页模式的分页结果（含页码↔字符 offset 映射）。
  ReaderPagination? _pagination;

  /// 分页缓存键：章 / 排版 / 几何 / 简繁 任一变化都要重算。
  String _paginationKey = '';

  /// 上一次派生用的简繁模式：模式变了要用 `_rawCache` 的原文重新派生（§9.3）。
  ChineseConvert _derivedConvert = ChineseConvert.off;

  /// 高亮样式与颜色的读取入口（`listen.highlightStyle` / `listen.highlightColor`）。
  /// prefs 实例异步取一次，取到之前按默认值画，不阻塞首帧。
  ReaderSpeechSettings? _speechSettings;

  int _currentPage = 0;

  /// 章节原文缓存：替换规则变了要用它重新派生段落，不再联网。
  final _rawCache = <String, String>{};

  Object? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _restored = false;

  /// 正文就绪：加载完成前不写进度，避免把「空位置」落盘。
  bool _ready = false;

  /// 写入序号，只增不减：旧快照后到也不会覆盖新进度。
  int _persistSeq = 0;

  /// 是否已从 store 续上跨会话序号（每个页面实例只做一次）。
  bool _revisionSeeded = false;

  /// 状态栏「净化已生效」提示是否可见。
  bool _replaceHintShown = false;

  Timer? _autoTimer;

  /// 连续阅读时：当前章内比例与段落下标（用于进度与听书对齐）。
  double _continuousRatio = 0;
  int _paragraphIndex = 0;

  /// 听书：自动跟随闸门（锁 1500ms → 期间手动翻过页就转挂起 → 药丸）。
  /// 挂起时刻可能一个朗读事件都没有，所以把 `setState` 交给它自己触发。
  /// **它从不暂停朗读、也从不改进度**（`core/reader/speech_follow_gate.dart`）。
  late final SpeechFollowGate _follow = SpeechFollowGate(
    repaint: () {
      if (mounted) setState(() {});
    },
  );

  /// 听书：上一次渲染高亮时的章/段，用来避免整页重建。
  int _lastSpeechChapter = -1;
  int _lastSpeechParagraph = -1;

  /// 上一次画过的句/词区间：词级卡拉OK 每帧都在动，区间没变就不必重建页面。
  (int, int)? _lastSpeechBase;
  (int, int)? _lastSpeechActive;

  /// 听书：控制器变化回调（全局单例，页面退订即可）。
  ReaderSpeechController? _speech;

  Timer? _saveTimer;

  /// 设置唯一来源。
  ReaderSettings get _settings => _settingsStore.value;

  /// 本书生效的主题配置（按书覆盖，无覆盖回退全局活动主题）。
  ReaderThemeConfig get _bookThemeConfig {
    final list = _settings.effectiveThemes;
    return list[_settings.themeIndexFor(widget.bookId).clamp(0, list.length - 1)];
  }

  ReaderTypography get _type =>
      _bookThemeConfig.typography.scale(_settings.fontScaleFor(widget.bookId));

  double get _fontSize => _type.fontSize;
  double get _lineHeight => _type.lineHeight;
  bool get _autoTurn => _settings.autoTurn;
  int get _autoInterval => _settings.autoIntervalSec;

  bool get _paged => _settings.modeFor(widget.bookId) == ReaderMode.paged;

  /// 双页并排是否生效：翻页模式 + 开关打开 + 屏幕够宽（窄屏自动退回单页）。
  bool get _spreadEnabled =>
      _paged && _settings.doublePage && MediaQuery.sizeOf(context).width >= 600;

  /// 单页下标 → 屏下标。
  int _spreadIndexOf(int page) => _spreadEnabled ? page ~/ 2 : page;

  /// 九宫格分区几何（跟随用户配置）。
  ClickZoneLayout get _clickLayout => _settings.zoneLayout;

  int get _maxIndex => widget.chapters.isEmpty ? 0 : widget.chapters.length - 1;

  BookChapter get _chapter => widget.chapters[_index];

  _ReaderTheme get _theme {
    final config = _bookThemeConfig;
    final night = _settings.nightMode;
    return _ReaderTheme(
      config.name,
      Color(night ? config.backgroundColorNight : config.backgroundColor),
      Color(night ? config.textColorNight : config.textColor),
    );
  }

  /// 设置变化：作废分页缓存、重排自动翻页、应用屏幕相关项。
  ///
  /// 简繁模式变了必须**重新派生段落**：转换已经进派生入口（[deriveDisplayParagraphs]），
  /// 页面不再有「读到才转」的第二层缓存可切。这条与既有「替换规则变更 → 清段落缓存、
  /// 用 `_rawCache` 重派生」同构（`frontend/reader-paging-contract.md` §9.3）。
  void _onSettingsChanged() {
    if (!mounted) return;
    _paginationKey = '';
    _syncAutoTimer();
    _applyScreenSettings();
    if (_settings.convert != _derivedConvert) {
      _rederiveCurrentChapter();
      return;
    }
    setState(() {});
  }

  /// 用原文重新派生当前章：替换规则与简繁模式共用这条快路径，不联网。
  void _rederiveCurrentChapter() {
    final raw = _rawCache[_chapter.id];
    if (raw == null) {
      setState(() {});
      return;
    }
    final paragraphs = _deriveParagraphs(_chapter, raw);
    _cache[_chapter.id] = paragraphs;
    setState(() => _paragraphs = paragraphs);
  }

  void _applyScreenSettings() {
    final settings = _settings;
    if (settings.keepAwake) {
      WakelockPlus.enable();
    } else {
      WakelockPlus.disable();
    }
    if (settings.brightness >= 0) {
      // Linux 等平台没有亮度插件，失败时不打断阅读。
      ScreenBrightness()
          .setApplicationScreenBrightness(settings.brightness)
          .catchError((_) {});
    } else {
      ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    }
  }

  /// 批注/划线变化：重绘当前页（高亮跟随）。
  void _onAnnotationsChanged() {
    if (!mounted) return;
    setState(() {});
  }

  /// 首次进章节时提示一次「净化已生效」，避免用户以为正文被吞了。
  void _maybeToastReplace() {
    if (_replaceHintShown) return;
    final count = _replaceRules.forBook(widget.bookId).length;
    if (count == 0) return;
    _replaceHintShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _toast('已应用 $count 条正文净化规则');
    });
  }

  /// 替换规则变化：用原文重新派生段落，再重排。
  void _onReplaceRulesChanged() {
    if (!mounted) return;
    _cache.clear();
    _paginationKey = '';
    final hadRaw = _rawCache.containsKey(_chapter.id);
    _rederiveCurrentChapter();
    if (hadRaw) _replaceHintShown = true;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 切后台/被遮挡时立刻落盘：系统可能在之后直接杀掉进程。
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _saveTimer?.cancel();
      // ignore: discarded_futures
      _persist();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    _settingsStore.addListener(_onSettingsChanged);
    _bookmarks.addListener(_onAnnotationsChanged);
    _markings.addListener(_onAnnotationsChanged);
    _replaceRules.addListener(_onReplaceRulesChanged);
    // 听书控制器是全局单例：订阅它才能拿到高亮与自动跟随。
    _speech = AppScope.read(context).speech;
    _speech!.addListener(_onSpeechChanged);
    // 高亮样式/颜色落在 SharedPreferences 上：插件内部有单例，这里异步取一次即可。
    // ignore: discarded_futures
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() => _speechSettings = ReaderSpeechSettings(prefs));
    });
    _syncAutoTimer();
    _applyScreenSettings();
    _load(
      _index,
      restore: widget.restoreOffset > 0 || widget.restoreCharOffset >= 0,
    ).then((_) {
      if (!mounted || !widget.autoListen) return;
      if (widget.chapters.isEmpty) return;
      final paragraphs = _cache[widget.chapters[_index].id];
      if (paragraphs == null || paragraphs.isEmpty) return;
      unawaited(_autoStartSpeech());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speech?.removeListener(_onSpeechChanged);
    _settingsStore.removeListener(_onSettingsChanged);
    _bookmarks.removeListener(_onAnnotationsChanged);
    _markings.removeListener(_onAnnotationsChanged);
    _replaceRules.removeListener(_onReplaceRulesChanged);
    _saveTimer?.cancel();
    _autoTimer?.cancel();
    _follow.dispose();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    WakelockPlus.disable();
    ScreenBrightness().resetApplicationScreenBrightness().catchError((_) {});
    // 退出时补一次进度；dispose 里不能 await，直接丢出去。
    // ignore: discarded_futures
    _persist();
    super.dispose();
  }

  /// 翻到相邻页；返回是否真的翻动了（到边界返回 false，调用方据此换章）。
  bool _turnPage(int delta) {
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return false;
    final step = _spreadEnabled ? 2 : 1;
    final target =
        (_currentPage + delta * step).clamp(0, pagination.pageCount - 1);
    if (target == _currentPage) return false;
    _feedbackOnTurn();
    // ignore: discarded_futures
    _pager.goTo(_spreadIndexOf(target));
    return true;
  }

  /// 九宫格单击派发。`_chrome` 打开时任意点击先收菜单，避免误翻页。
  void _onTapUp(TapUpDetails details, Size size) {
    if (_chrome) {
      setState(() => _chrome = false);
      return;
    }
    final slot = _clickLayout.indexFor(details.localPosition, size);
    final action = _settingsStore.value.actionAt(slot);
    // ignore: discarded_futures
    _runAction(action);
  }

  Future<void> _runAction(ReaderClickAction action) async {
    switch (action) {
      case ReaderClickAction.none:
        return;
      case ReaderClickAction.menu:
        setState(() => _chrome = !_chrome);
        return;
      case ReaderClickAction.prevPage:
        await _stepPage(-1);
        return;
      case ReaderClickAction.nextPage:
        await _stepPage(1);
        return;
      case ReaderClickAction.prevChapter:
        await _go(-1, landing: _ChapterLanding.last);
        return;
      case ReaderClickAction.nextChapter:
        await _go(1, landing: _ChapterLanding.first);
        return;
      case ReaderClickAction.prevParagraph:
      case ReaderClickAction.nextParagraph:
        final speech = _speech;
        if (speech != null && speech.isFor(widget.bookId) && speech.isActive) {
          await speech.stepParagraph(
              action == ReaderClickAction.nextParagraph ? 1 : -1);
          return;
        }
        // 没有逐段朗读队列时退化为翻页，保证点击有反馈。
        await _stepPage(action == ReaderClickAction.nextParagraph ? 1 : -1);
        return;
      case ReaderClickAction.directory:
        await _openDirectory();
        return;
      case ReaderClickAction.toggleSpeech:
        await _startSpeech();
        return;
      case ReaderClickAction.addBookmark:
        await _addBookmark();
        return;
      case ReaderClickAction.editContent:
      case ReaderClickAction.toggleReplace:
        await _openReplaceRules();
        return;
      case ReaderClickAction.searchContent:
        await _openSearchInChapter();
        return;
      case ReaderClickAction.syncProgress:
        _toast('「${action.label}」暂未支持');
        return;
    }
  }

  /// 本章内全文搜索：命中段落列出，点击跳到对应页。
  Future<void> _openSearchInChapter() async {
    final paragraphs = _displayParagraphs;
    if (paragraphs.isEmpty) {
      _toast('正文还没加载完');
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => _ChapterSearchSheet(
        paragraphs: paragraphs,
        onJump: (offset) {
          Navigator.of(context).maybePop();
          _jumpToChar(offset);
        },
      ),
    );
  }

  /// 跳到章内某个字符位置。
  void _jumpToChar(int charOffset) {
    if (!_paged) {
      _continuous.jumpToTop();
      return;
    }
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return;
    final page = pagination.pageForChar(charOffset);
    setState(() => _currentPage = page);
    _pager.jumpTo(_spreadIndexOf(page));
    // 搜索/书签这类跳页是用户自己定位，和手动翻页同等对待。
    _noteManualTurn();
  }

  /// 翻页反馈：轻触 + 可选点击音。所有翻页入口（点击/滑动/自动/按键）共用。
  void _feedbackOnTurn() {
    final settings = _settings;
    if (settings.hapticOnTurn) HapticFeedback.selectionClick();
    if (settings.soundOnTurn) SystemSound.play(SystemSoundType.click);
  }

  Future<void> _addBookmark() async {
    final offset = _currentCharOffset;
    if (offset < 0) {
      _toast('正文还在加载，稍后再试');
      return;
    }
    await _bookmarks.add(
      bookId: widget.bookId,
      chapterId: _chapter.id,
      chapterIndex: _index,
      charOffset: offset,
      chapterTitle: _chapter.title,
      excerpt: _excerptAt(offset),
    );
    if (!mounted) return;
    _toast('已加书签');
  }

  /// 划线：把选中文本在整章里的位置换算成字符区间。
  ///
  /// 选区文本取自 `SelectionArea`，跨行时带换行；这里按「去掉所有空白后」的
  /// 扁平串定位，再把扁平下标映射回原文下标，避免缩进/换行造成偏移。
  Future<void> _markSelection(String selectedText) async {
    final target = _stripSpaces(selectedText);
    if (target.isEmpty) return;
    final chapterText = _displayParagraphs.join('\n');
    if (chapterText.isEmpty) return;

    final flat = StringBuffer();
    final map = <int>[];
    for (var i = 0; i < chapterText.length; i++) {
      final ch = chapterText[i];
      if (_isSpace(ch)) continue;
      flat.write(ch);
      map.add(i);
    }
    final flatText = flat.toString();

    var found = flatText.indexOf(target);
    var length = target.length;
    if (found < 0) {
      // 跨段落选择时中间可能夹着段落分隔，退化为用前 20 字定位。
      final probe = target.length > 20 ? target.substring(0, 20) : target;
      found = flatText.indexOf(probe);
      if (found < 0) {
        _toast('定位失败，请重新选择');
        return;
      }
      length = probe.length;
    }
    final charStart = map[found];
    final lastIndex = (found + length - 1).clamp(0, map.length - 1);
    final charEnd = map[lastIndex] + 1;

    await _markings.add(
      bookId: widget.bookId,
      chapterId: _chapter.id,
      chapterIndex: _index,
      charStart: charStart,
      charEnd: charEnd,
      text: chapterText.substring(charStart, charEnd),
      chapterTitle: _chapter.title,
    );
    if (!mounted) return;
    _toast('已划线');
  }

  static String _stripSpaces(String text) {
    final buffer = StringBuffer();
    for (var i = 0; i < text.length; i++) {
      if (_isSpace(text[i])) continue;
      buffer.write(text[i]);
    }
    return buffer.toString();
  }

  static bool _isSpace(String ch) =>
      ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == '\u3000';

  Future<void> _openBookmarks() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      constraints: const BoxConstraints(maxWidth: 620),
      builder: (_) => _BookmarkSheet(
        store: _bookmarks,
        markings: _markings,
        bookId: widget.bookId,
        onJump: _jumpTo,
      ),
    );
  }

  /// 书签/划线跳转：换章 + 定位到字符位置。
  Future<void> _jumpTo(int chapterIndex, int charOffset) async {
    Navigator.of(context).maybePop();
    final target = chapterIndex.clamp(0, _maxIndex);
    if (target != _index) {
      await _go(target - _index, landing: _ChapterLanding.keep);
      if (!mounted) return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    if (_paged) {
      final pagination = _pagination;
      if (pagination == null) return;
      final page = pagination.pageForChar(charOffset);
      _currentPage = page;
      // 双页时 pager 的下标单位是「屏」，必须换算，否则会跳到相邻屏。
      _pager.jumpTo(_spreadIndexOf(page));
      // 书签/划线跳页同样是用户手动定位。
      _noteManualTurn();
    } else {
      _continuous.jumpToTop();
    }
  }

  Future<void> _openReplaceRules() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ReplaceRulesScreen(bookId: widget.bookId),
      ),
    );
  }

  /// 双模式「翻一页」：翻页模式走 PageView，滚动模式翻一屏，到边自动换章。
  Future<void> _stepPage(int delta) async {
    // 用户自己翻页：短暂屏蔽朗读自动跟随（不打断朗读）。
    _lockFollow();
    if (_paged) {
      if (_turnPage(delta)) return;
      if (delta > 0) {
        await _go(1, landing: _ChapterLanding.first);
      } else {
        await _go(-1, landing: _ChapterLanding.last);
      }
      return;
    }
    if (await _continuous.scrollByPage(delta)) return;
    if (delta > 0) {
      await _go(1, landing: _ChapterLanding.first);
    } else {
      await _go(-1, landing: _ChapterLanding.last);
    }
  }

  void _toast(String text) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(SnackBar(
      content: Text(text),
      duration: const Duration(milliseconds: 1200),
    ));
  }

  Future<void> _openClickZoneEditor() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => ReaderClickZoneEditor(store: _settingsStore),
    );
  }

  /// 自动翻页计时器：只在翻页模式且开关打开时跑。
  void _syncAutoTimer() {
    _autoTimer?.cancel();
    _autoTimer = null;
    if (!_autoTurn || !_paged) return;
    _autoTimer = Timer.periodic(Duration(seconds: _autoInterval), (_) {
      if (!mounted) return;
      _turnPage(1);
    });
  }

  /// 键盘：空格/→ 下一页，← 上一页（翻页模式）；滚动模式下空格下翻一段。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;

    // 音量键翻页：桌面端与外接键盘有效；安卓上系统同时会调音量。
    if (_settingsStore.value.volumeKeyPage &&
        (key == LogicalKeyboardKey.audioVolumeUp ||
            key == LogicalKeyboardKey.audioVolumeDown)) {
      // ignore: discarded_futures
      _stepPage(key == LogicalKeyboardKey.audioVolumeUp ? -1 : 1);
      return KeyEventResult.handled;
    }

    if (_paged) {
      if (key == LogicalKeyboardKey.space ||
          key == LogicalKeyboardKey.arrowRight) {
        _turnPage(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        _turnPage(-1);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.space) {
      if (!_scroll.hasClients) return KeyEventResult.ignored;
      final max = _scroll.position.maxScrollExtent;
      _scroll.jumpTo((_scroll.offset + 160).clamp(0.0, max));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 正文段落：**已经是完全派生的结果**（含替换规则与简繁），这里不再二次转换。
  /// 朗读侧调的是同一个 [deriveDisplayParagraphs]，于是「朗读段数 == 屏幕段数」
  /// 且字符偏移逐字对齐（上一子任务的 CRITICAL-1 从这里封口）。
  List<String> get _displayParagraphs => _paragraphs ?? const <String>[];

  /// 页眉/页脚高度（跟随字号，保证小屏不吃掉正文）。
  double get _tipHeight =>
      ((_fontSize - 6).clamp(9.0, 14.0) * 1.2 + 8).clamp(18.0, 30.0);

  bool get _showHeaderTip {
    final mode = _bookThemeConfig.headerMode;
    if (mode == ReaderTipMode.never) return false;
    if (mode == ReaderTipMode.always) return true;
    return _chrome;
  }

  bool get _showFooterTip {
    final mode = _bookThemeConfig.footerMode;
    if (mode == ReaderTipMode.never) return false;
    if (mode == ReaderTipMode.always) return true;
    return _chrome;
  }

  /// 用实测约束做分页。相同键直接命中缓存，参数不变不重算。
  ReaderPagination _paginationFor(BuildContext context, Size size) {
    final paragraphs = _displayParagraphs;
    if (!_paged || paragraphs.isEmpty) return ReaderPagination.empty;
    final type = _type;
    final headerHeight = _showHeaderTip ? _tipHeight : 0.0;
    final footerHeight = _showFooterTip ? _tipHeight : 0.0;
    // 双页并排时每页实际只有半屏宽：测量必须与渲染同宽，
    // 否则按整屏宽度切出来的行在半屏里会被 softWrap:false + clip 直接裁掉。
    final pageWidth = _spreadEnabled ? size.width / 2 : size.width;
    final geometry = ReaderPageGeometry(
      contentWidth: pageWidth - type.paddingLeft - type.paddingRight,
      contentHeight: size.height -
          type.paddingTop -
          type.paddingBottom -
          headerHeight -
          footerHeight,
      textScaler: MediaQuery.textScalerOf(context),
    );
    final key = [
      _chapter.id,
      _index,
      type.hashCode,
      geometry.contentWidth.toStringAsFixed(1),
      geometry.contentHeight.toStringAsFixed(1),
      geometry.textScaler.toString(),
      _settings.convert.name,
      // 正文签名：同章被替换规则或源站改过内容时必须重排。
      paragraphsSignature(paragraphs),
    ].join('|');
    final cached = _pagination;
    if (_paginationKey == key && cached != null) return cached;
    final result = paginateReader(
      paragraphs: paragraphs,
      typography: type,
      geometry: geometry,
      chapterTitle: type.includeChapterTitle ? _chapter.title : null,
    );
    _pagination = result;
    _paginationKey = key;
    if (_currentPage >= result.pageCount) {
      _currentPage = result.pageCount == 0 ? 0 : result.pageCount - 1;
    }
    return result;
  }

  ReaderPageRenderSpec _renderSpec(
    ReaderPagination pagination,
    int pageIndex, {
    bool leftHalf = false,
    bool rightHalf = false,
  }) {
    final config = _bookThemeConfig;
    // 双页时把朝向中缝的一侧内边距减半，否则两页各自 22px 会拼出 44px 空隙。
    // 分页已按半屏宽（含两侧完整内边距）测量，这里只放宽 11px，行不会溢出。
    final type = leftHalf
        ? _type.copyWith(
            paddingRight: (_type.paddingRight / 2).clamp(0.0, 12.0))
        : rightHalf
            ? _type.copyWith(
                paddingLeft: (_type.paddingLeft / 2).clamp(0.0, 12.0))
            : _type;
    final tipContext = ReaderTipContext(
      bookName: widget.bookTitle,
      chapterTitle: _chapter.title,
      chapterIndex: _index,
      chapterSize: widget.chapters.length,
      pageIndex: pageIndex,
      pageSize: pagination.pageCount,
      progress: _offsetRatio,
      batteryPercent: BatteryLevelReader.read(),
    );
    return ReaderPageRenderSpec(
      typography: type,
      theme: config,
      night: _settings.nightMode,
      chapterTitle: _chapter.title,
      bookName: widget.bookTitle,
      chapterIndex: _index,
      chapterSize: widget.chapters.length,
      headerHeight: _showHeaderTip ? _tipHeight : 0,
      footerHeight: _showFooterTip ? _tipHeight : 0,
      // 朗读高亮：底纹 = 当前句（音轨路径退化为段落），实心 = 当前词。
      speechBase: _speechBaseRange(),
      speechActive: _speechWordRange(),
      speechStyle: _speechSettings?.style ?? SpeechHighlightStyle.highlight,
      speechColorArgb:
          _speechSettings?.colorArgb ?? kSpeechColorFollowTheme,
      header: buildTipLayout(
        left: config.headerLeft,
        middle: config.headerMiddle,
        right: config.headerRight,
        ctx: tipContext,
        customLeft: config.headerCustomLeft,
        customMiddle: config.headerCustomMiddle,
        customRight: config.headerCustomRight,
      ),
      footer: buildTipLayout(
        left: config.footerLeft,
        middle: config.footerMiddle,
        right: config.footerRight,
        ctx: tipContext,
        customLeft: config.footerCustomLeft,
        customMiddle: config.footerCustomMiddle,
        customRight: config.footerCustomRight,
      ),
      showHeader: _showHeaderTip,
      showFooter: _showFooterTip,
      progress: _offsetRatio,
      batteryPercent: tipContext.batteryPercent,
      markings: _markings.inChapter(widget.bookId, _chapter.id),
      onMarkRequested: _markSelection,
    );
  }

  /// HTML → 显示段落。**唯一派生入口**是 [deriveDisplayParagraphs]，顺序固定为
  /// `htmlToParagraphs → 去章标题 → 替换规则 → 简繁`；这里只负责把页面的依赖填进去，
  /// 并记下本次用的简繁模式（[_onSettingsChanged] 据此判断要不要重新派生）。
  /// 朗读控制器调同一个函数，两侧不许再加减任何步骤。
  List<String> _deriveParagraphs(BookChapter chapter, String raw) {
    final convert = _settings.convert;
    _derivedConvert = convert;
    return deriveDisplayParagraphs(
      raw: raw,
      chapterTitle: chapter.title,
      rules: _replaceRules.forBook(widget.bookId),
      convert: convert,
    );
  }

  Future<void> _load(int index, {bool restore = false}) async {
    if (widget.chapters.isEmpty) return;
    final chapter = widget.chapters[index];
    // 滚动模式的 ContinuousChapters 会复用同一个 State：目录/上下章跳转必须
    // 显式通知它换章，否则界面仍停在旧章内容上。
    if (!_paged) _continuous.jumpToChapter(index);

    // 已有原文：直接重新派生（替换规则变更后的快路径）。
    final raw = _rawCache[chapter.id];
    if (raw != null) {
      final paragraphs = _deriveParagraphs(chapter, raw);
      _cache[chapter.id] = paragraphs;
      setState(() {
        _index = index;
        _error = null;
        _paragraphs = paragraphs;
        _loading = false;
        _ready = true;
      });
      _paginationKey = '';
      _afterLoad(restore: restore);
      _syncAutoTimer();
      _maybeToastReplace();
      return;
    }

    final cached = _cache[chapter.id];
    setState(() {
      _index = index;
      _error = null;
      _paragraphs = cached;
      _loading = cached == null;
      _ready = cached != null;
    });
    if (cached != null) {
      _afterLoad(restore: restore);
      return;
    }
    try {
      final text = await AppScope.read(context).api.chapterText(chapter.id);
      _rawCache[chapter.id] = text;
      final paragraphs = _deriveParagraphs(chapter, text);
      _cache[chapter.id] = paragraphs;
      // 落盘带正文签名：源站改过正文时这张缓存会被判为过期。
      await _cacheStore.put(
        chapter.id,
        text,
        signature: contentSignature(text),
      );
      if (!mounted || _index != index) return;
      setState(() {
        _paragraphs = paragraphs;
        _loading = false;
        _ready = true;
      });
      _paginationKey = '';
      _afterLoad(restore: restore);
      _syncAutoTimer();
      _maybeToastReplace();
      _prefetch(index + 1);
    } catch (e) {
      if (!mounted || _index != index) return;
      // 网络不可用但有缓存：退化成本地阅读，不弹错误。
      final offline = _cacheStore.text(chapter.id);
      if (offline != null && offline.isNotEmpty) {
        _rawCache[chapter.id] = offline;
        final paragraphs = _deriveParagraphs(chapter, offline);
        _cache[chapter.id] = paragraphs;
        setState(() {
          _paragraphs = paragraphs;
          _loading = false;
          _ready = true;
        });
        _afterLoad(restore: restore);
        return;
      }
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  /// 后台把下一章也拉下来，翻页时基本无等待。
  void _prefetch(int index) {
    if (index < 0 || index > _maxIndex) return;
    final chapter = widget.chapters[index];
    if (_cache.containsKey(chapter.id)) return;
    // ignore: discarded_futures
    AppScope.read(context)
        .api
        .chapterText(chapter.id)
        .then((raw) {
          _rawCache[chapter.id] = raw;
          _cache[chapter.id] = _deriveParagraphs(chapter, raw);
        })
        .catchError((Object _) {});
  }

  void _afterLoad({required bool restore}) {
    // 段落数变了：听书控制器要用它把毫秒位置收敛到段落下标。
    _speech?.setParagraphCount(_displayParagraphs.length);

    final landing = _landing;
    _landing = _ChapterLanding.keep;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_paged) {
        // 分页结果在 build 里按实测几何生成；这里只记下目标页，
        // `ReaderPager.didUpdateWidget` 会在分页就绪后同步索引。
        final count = _pagination?.pageCount ?? 0;
        var target = 0;
        if (landing == _ChapterLanding.last) {
          target = count > 0 ? count - 1 : 0;
        } else if (restore && !_restored) {
          _restored = true;
          final pagination = _pagination;
          if (widget.restoreCharOffset >= 0 && pagination != null) {
            // 字符偏移比比例精确：改过字号也能落回同一句。
            target = pagination.pageForChar(widget.restoreCharOffset);
          } else {
            target = count > 0
                ? (widget.restoreOffset * count).round() - 1
                : 0;
          }
        }
        if (count > 0) target = target.clamp(0, count - 1);
        _currentPage = target < 0 ? 0 : target;
        _pager.jumpTo(_spreadIndexOf(_currentPage));
        return;
      }
      if (landing == _ChapterLanding.last) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        } else {
          _continuous.jumpToBottom();
        }
        return;
      }
      if (landing == _ChapterLanding.first) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(0);
        } else {
          _continuous.jumpToTop();
        }
        return;
      }
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      if (restore && !_restored) {
        _restored = true;
        _scroll.jumpTo((max * widget.restoreOffset).clamp(0.0, max));
      } else {
        _scroll.jumpTo(0);
      }
    });
  }

  double get _offsetRatio {
    if (!_paged) return _continuousRatio;
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return 0;
    return ((_currentPage + 1) / pagination.pageCount).clamp(0.0, 1.0);
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 900), _persist);
  }

  /// 当前阅读位置的章内字符偏移；拿不到返回 -1。
  int get _currentCharOffset {
    if (_paged) {
      final pagination = _pagination;
      if (pagination == null || pagination.isEmpty) return -1;
      final index = _currentPage.clamp(0, pagination.pageCount - 1);
      return pagination.pages[index].charStart;
    }
    final paragraphs = _displayParagraphs;
    if (paragraphs.isEmpty) return -1;
    return paragraphCharOffset(paragraphs, _paragraphIndex);
  }

  /// 从 [offset] 起取 40 字做书签摘录。
  String _excerptAt(int offset) {
    final text = _displayParagraphs.join('\n');
    if (text.isEmpty || offset < 0 || offset >= text.length) return '';
    final end = (offset + 40).clamp(0, text.length);
    return text
        .substring(offset, end)
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> _persist() async {
    // 正文没就绪时写盘会把「第 0 页」当成真实进度。
    if (!_ready || widget.chapters.isEmpty) return;
    final chapter = widget.chapters[_index];
    // 跨会话续号：以 store 已存序号为起点。否则重进页面后 _persistSeq 从 0 重来，
    // 所有写入都会命中「revision <= existing」而被丢弃，进度停在上次会话。
    if (!_revisionSeeded) {
      _revisionSeeded = true;
      _persistSeq = await _store.revisionOf(widget.bookId);
      if (!mounted) return;
    }
    _persistSeq++;
    await _store.record(
      bookId: widget.bookId,
      title: widget.bookTitle,
      coverUrl: widget.coverUrl,
      chapterId: chapter.id,
      chapterTitle: chapter.title,
      chapterIndex: _index,
      chapters: widget.chapters.length,
      offset: _offsetRatio,
      charOffset: _currentCharOffset,
      revision: _persistSeq,
    );
  }

  Future<void> _go(int delta, {_ChapterLanding landing = _ChapterLanding.keep}) async {
    _lockFollow();
    final next = (_index + delta).clamp(0, _maxIndex);
    if (next == _index) {
      _toast(delta > 0 ? '已是最后一章' : '已是第一章');
      return;
    }
    await _persist();
    if (!mounted) return;
    _landing = landing;
    await _load(next);
  }

  /// 自动起朗读：**已有同书会话时什么都不做**。
  ///
  /// 不能直接用 `_startSpeech()`：它在“同书且在播”时会 `toggle()`（把朗读暂停），
  /// 那是“用户点按钮”的语义，不是“进页自动开始”的语义。
  Future<void> _autoStartSpeech() async {
    final speech = _speech;
    if (speech == null) return;
    if (speech.isFor(widget.bookId) && speech.isActive) return;
    await _startSpeech();
  }

  /// 听书：在**当前阅读页内**开始朗读，不再跳独立页面。
  ///
  /// 正文留在原处，当前朗读段落高亮；离开本页后朗读继续（控制器挂在 AppScope）。
  Future<void> _startSpeech() async {
    if (widget.chapters.isEmpty) return;
    final speech = _speech;
    if (speech == null) return;
    if (speech.isFor(widget.bookId) && speech.isActive) {
      await speech.toggle();
      return;
    }
    // 用户主动起朗读 = 明确要跟随：清掉可能挂着的「暂停跟随」与药丸。
    _follow.resume();
    await speech.start(
      bookId: widget.bookId,
      bookTitle: widget.bookTitle,
      coverUrl: widget.coverUrl,
      chapters: widget.chapters,
      chapterIndex: _index,
      startParagraph: _speechParagraphIndex,
      startRatio: _offsetRatio,
    );
    speech.setParagraphCount(_displayParagraphs.length);
    if (!mounted) return;
    setState(() {});
  }

  /// 当前可见段落：翻页模式取当前页首段，滚动模式取滚动位置。
  int get _speechParagraphIndex {    if (_paged) {
      final pagination = _pagination;
      if (pagination == null || pagination.isEmpty) return 0;
      final page = _currentPage.clamp(0, pagination.pageCount - 1);
      return pagination.pages[page].paragraphStart;
    }
    return _paragraphIndex;
  }

  /// 朗读高亮的公共前置：没在朗读本书 / 开关关了 / 正文没就绪 → 一律不画。
  bool get _speechHighlightOn {
    final speech = _speech;
    if (speech == null || !speech.isFor(widget.bookId)) return false;
    if (!AppScope.read(context).settings.listenHighlight) return false;
    return _displayParagraphs.isNotEmpty;
  }

  /// 控制器算出的区间只在「它和本页在同一章」时可用：否则字符位属于另一章的
  /// 段落列表，画过来就是串章（自动连播换章时两边有一帧不一致）。
  bool get _speechSameChapter {
    final speech = _speech;
    return speech != null && speech.chapterIndex == _index;
  }

  /// 底纹区间（章内坐标 `[start,end)`）：TTS 路径用**当前句**；音轨路径没有句表，
  /// 退化为当前段落区间 —— 精度变粗是事实，由控制器的 `highlightGranularity`
  /// 暴露给徽标，不伪装成句级（`backend/listen-tts-contract.md` §4）。
  (int, int)? _speechBaseRange() {
    if (!_speechHighlightOn) return null;
    if (!_speechSameChapter) return null;
    final speech = _speech!;
    final sentence = speech.highlightSentence;
    if (sentence != null) return sentence;
    return paragraphCharRange(_displayParagraphs, speech.paragraphIndex);
  }

  /// 实心区间：当前词。精度不足（音轨路径、句级引擎）或用户只要句级时返回 null。
  (int, int)? _speechWordRange() {
    if (!_speechHighlightOn) return null;
    if (!_speechSameChapter) return null;
    return _speech!.highlightWord;
  }

  /// 滚动模式高亮：正在朗读的章。
  int? get _speechHighlightChapter {
    final speech = _speech;
    if (speech == null || !speech.isFor(widget.bookId)) return null;
    if (!AppScope.read(context).settings.listenHighlight) return null;
    return speech.chapterIndex;
  }

  /// 滚动模式高亮：正在朗读的段。
  int? get _speechHighlightParagraph {
    final speech = _speech;
    if (speech == null || !speech.isFor(widget.bookId)) return null;
    if (!AppScope.read(context).settings.listenHighlight) return null;
    return speech.paragraphIndex;
  }

  /// 用户自己操作了页面：短暂屏蔽自动跟随（不打断朗读）。
  /// 只上锁、不挂起 —— 「点了下菜单」不该变成「朗读不跟了 + 弹药丸」。
  void _lockFollow() => _follow.noteUserAction();

  /// 用户手动翻了页（滑动 / 九宫格翻页 / 书签跳页）：上锁，锁满后转挂起弹药丸。
  void _noteManualTurn() => _follow.noteManualTurn();

  /// 点「继续跟随」：清挂起并**立刻补一次跟随**。朗读与进度一个字节都不碰。
  void _resumeFollow() {
    setState(_follow.resume);
    _followSpeechPage();
  }

  /// 听书控制器变化：章节跟随 + 高亮刷新 + 翻页跟随。
  void _onSpeechChanged() {
    if (!mounted) return;
    final speech = _speech;
    if (speech == null || !speech.isFor(widget.bookId)) return;
    if (speech.chapterIndex != _lastSpeechChapter) {
      _lastSpeechChapter = speech.chapterIndex;
      if (speech.chapterIndex != _index) {
        // 自动连播换章：把正文跟到新章。
        unawaited(_load(speech.chapterIndex));
        return;
      }
    }
    // 重绘条件从「段变」放宽到「段 / 句 / 词 任一区间变」：词级卡拉OK 每帧都在动，
    // 只按段落判断的话词永远画不出来。跳不跳页由闸门按**句起点**决定，两件事分开。
    final base = _speechBaseRange();
    final active = _speechWordRange();
    if (speech.paragraphIndex == _lastSpeechParagraph &&
        base == _lastSpeechBase &&
        active == _lastSpeechActive) {
      return;
    }
    _lastSpeechParagraph = speech.paragraphIndex;
    _lastSpeechBase = base;
    _lastSpeechActive = active;
    if (mounted) setState(() {});
    _followSpeechPage();
  }

  /// 本书当前是否有朗读会话 —— 「继续跟随」药丸的前置。
  ///
  /// 挂起状态由「用户手动翻页」触发，而翻页在阅读里是常态动作：不读它就在纯阅读时
  /// 每隔 1.5s 弹一颗「朗读已停在这里」，等于给没开朗读的人挂了一个永远点不掉的浮层。
  bool get _listeningThisBook {
    final speech = _speech;
    return speech != null && speech.isActive && speech.isFor(widget.bookId);
  }

  /// 翻页模式：朗读跨句（音轨路径是跨段）时跳到该句所在页。
  ///
  /// **句优先**：跳页依据只取底纹区间的起点。词级高亮推进时起点不变，闸门必然返回
  /// `null` → 一次 `jumpTo` 都不会触发（design.md §5）。挂起期间同样不跳，等药丸。
  void _followSpeechPage() {
    if (!_paged) return;
    final pagination = _pagination;
    if (pagination == null || pagination.isEmpty) return;
    final scope = AppScope.read(context);
    final target = _follow.targetPage(
      enabled: scope.settings.listenFollow,
      baseCharStart: _speechBaseRange()?.$1,
      currentPage: _currentPage,
      pageForChar: pagination.pageForChar,
    );
    if (target == null) return;
    setState(() => _currentPage = target);
    _pager.jumpTo(_spreadIndexOf(target));
  }

  Future<void> _openDirectory() async {
    final picked = await showBookDirectorySheet(
      context,
      chapters: widget.chapters,
      currentIndex: _index,
      title: widget.bookTitle,
    );
    if (picked == null || picked == _index || !mounted) return;
    await _persist();
    if (!mounted) return;
    await _load(picked);
  }

  Future<void> _showSettings() {
    final sample = _paragraphs?.isNotEmpty == true ? _paragraphs!.first : '';
    final preview = sample.isEmpty
        ? '春江潮水连海平，海上明月共潮生。'
        : (sample.length > 80 ? sample.substring(0, 80) : sample);
    return showReaderSettingsSheet(
      context,
      store: _settingsStore,
      bookId: widget.bookId,
      previewText: preview,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    return Scaffold(
      backgroundColor: theme.background,
      bottomNavigationBar: _speechBar(context),
      body: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 只注册 tap：PageView 的横滑与 ListView 的纵滑仍在手势竞技场里优先，
          // 不会被这一层抢走。
          onTapUp: (details) {
            final size = context.size ?? MediaQuery.sizeOf(context);
            _onTapUp(details, size);
          },
          child: Stack(
            children: [
              Positioned.fill(child: _buildBody(theme)),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                top: _chrome ? 0 : -120,
                child: _buildTopBar(theme),
              ),
              AnimatedPositioned(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                left: 0,
                right: 0,
                bottom: _chrome ? 0 : -140,
                child: _buildBottomBar(theme),
              ),
              // 跟随挂起时的「继续跟随」药丸：右下角胶囊浮层（样式沿用播放器静音提示）。
              if (_follow.suspended && _listeningThisBook)
                FollowPill(onTap: _resumeFollow, bottom: _chrome ? 132 : 72),
            ],
          ),
        ),
      ),
    );
  }

  /// 底栏页码：双页显示区间（`3-4 / 20 页`）。
  String get _pageLabel {
    final total = _pagination?.pageCount ?? 0;
    if (!_paged || total <= 0) {
      return '${_index + 1} / ${widget.chapters.length}';
    }
    if (!_spreadEnabled) return '${_currentPage + 1} / $total 页';
    final left = _currentPage + 1;
    final right = (left + 1).clamp(left, total);
    return right == left ? '$left / $total 页' : '$left-$right / $total 页';
  }

  Widget _buildTopBar(_ReaderTheme theme) {
    return Material(
      color: theme.background.withValues(alpha: 0.96),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, color: theme.foreground),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  _chapter.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: theme.foreground, fontWeight: FontWeight.w600),
                ),
              ),
              _buildSpeechBadge(theme),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '书签与划线',
                icon: Icon(Icons.bookmarks_outlined, color: theme.foreground),
                onPressed: _openBookmarks,
              ),
              IconButton(
                tooltip: '听书',
                icon: Icon(Icons.headset, color: theme.foreground),
                onPressed: _startSpeech,
              ),
              IconButton(
                tooltip: '定时关闭',
                icon: Icon(Icons.bedtime_outlined, color: theme.foreground),
                onPressed: _openSleepSheet,
              ),
              IconButton(
                tooltip: '目录',
                icon: Icon(Icons.list_alt, color: theme.foreground),
                onPressed: _openDirectory,
              ),
              IconButton(
                tooltip: '设置',
                icon: Icon(Icons.text_fields, color: theme.foreground),
                onPressed: _showSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶栏精度徽标：只取控制器的 `activePath` + `highlightGranularity`（§6）。
  /// 音轨路径恒显「段」—— 拿不到词级就画「段」，不伪装、不静默。
  Widget _buildSpeechBadge(_ReaderTheme theme) {
    final speech = _speech;
    if (speech == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: speech,
      builder: (context, _) => SpeechBadge(
        text: speech.isActive && speech.isFor(widget.bookId)
            ? speech.badgeText
            : '',
        foreground: theme.foreground.withValues(alpha: 0.72),
      ),
    );
  }

  /// 定时浮层入口（阅读页路径）：sheet 驱动控制器的 SleepTimer 实例，
  /// 持久化由控制器统一走 ReaderListenSettings —— 本页不复制定时逻辑。
  Future<void> _openSleepSheet() async {
    final speech = _speech;
    if (speech == null) return;
    await showListenSleepSheet(
      context,
      timer: speech.sleepTimer,
      refresh: speech,
      onSaved: () => unawaited(speech.persistSleep()),
    );
  }

  Widget _buildBottomBar(_ReaderTheme theme) {
    return Material(
      color: theme.background.withValues(alpha: 0.96),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 56,
          child: Row(
            children: [
              IconButton(
                tooltip: '点击区域',
                icon: Icon(Icons.touch_app_outlined, color: theme.foreground),
                onPressed: _openClickZoneEditor,
              ),
              TextButton(
                onPressed: _index > 0 ? () => _go(-1) : null,
                child: const Text('上一章'),
              ),
              Expanded(
                child: Center(
                  child: Text(
                    _pageLabel,
                    style: TextStyle(color: theme.foreground, fontSize: 12),
                  ),
                ),
              ),
              TextButton(
                onPressed: _index < _maxIndex ? () => _go(1) : null,
                child: const Text('下一章'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPaged(_ReaderTheme theme) {
    return SafeArea(
      bottom: false,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final pagination = _paginationFor(context, constraints.biggest);
          if (pagination.isEmpty) {
            return Center(
              child: Text(
                '本章暂无正文',
                style: TextStyle(
                  color: theme.foreground.withValues(alpha: 0.6),
                ),
              ),
            );
          }
          final spread = _spreadEnabled;
          final spreadCount = spread
              ? (pagination.pageCount + 1) ~/ 2
              : pagination.pageCount;
          final index = spread
              ? (_currentPage ~/ 2).clamp(0, spreadCount - 1)
              : _currentPage.clamp(0, spreadCount - 1);
          return ReaderPager(
            controller: _pager,
            pageCount: spreadCount,
            index: index,
            animation: _settings.anim,
            duration: Duration(milliseconds: _settings.animDurationMs),
            swipeEnabled: _settings.swipeEnabled,
            onIndexChanged: (i) {
              if (!mounted) return;
              _feedbackOnTurn();
              // 手势翻页与 `goTo()` 都会回到这里，是「用户手动翻页」的唯一真值出口；
              // 自动跟随走的是 `jumpTo()`（不触发本回调），所以不会被误判成手动。
              _noteManualTurn();
              final single = spread ? i * 2 : i;
              if (single == _currentPage) return;
              setState(() => _currentPage = single);
              // ignore: discarded_futures
              _persist();
            },
            onOverscrollNext: () {
              // ignore: discarded_futures
              _go(1, landing: _ChapterLanding.first);
            },
            onOverscrollPrev: () {
              // ignore: discarded_futures
              _go(-1, landing: _ChapterLanding.last);
            },
            builder: (context, i) {
              if (!spread) {
                return RepaintBoundary(
                  child: ReaderPageContent(
                    page: pagination.pages[i],
                    pageIndex: i,
                    pageSize: pagination.pageCount,
                    spec: _renderSpec(pagination, i),
                  ),
                );
              }
              // 双页：左右各放一个已算好的单页，最后一屏右半留白。
              final left = i * 2;
              final right = left + 1;
              return RepaintBoundary(
                child: Row(
                  children: [
                    Expanded(
                      child: ReaderPageContent(
                        page: pagination.pages[left],
                        pageIndex: left,
                        pageSize: pagination.pageCount,
                        spec: _renderSpec(pagination, left, leftHalf: true),
                      ),
                    ),
                    Expanded(
                      child: right < pagination.pageCount
                          ? ReaderPageContent(
                              page: pagination.pages[right],
                              pageIndex: right,
                              pageSize: pagination.pageCount,
                              spec: _renderSpec(pagination, right,
                                  rightHalf: true),
                            )
                          : ColoredBox(color: _theme.background),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  /// 取某章段落（连续阅读用；已加载的走缓存）。
  Future<List<String>> _paragraphsOf(int index) async {
    final chapter = widget.chapters[index];
    final cached = _cache[chapter.id];
    if (cached != null) return cached;
    final raw = _rawCache[chapter.id] ??
        await AppScope.read(context).api.chapterText(chapter.id);
    _rawCache[chapter.id] = raw;
    final ps = _deriveParagraphs(chapter, raw);
    _cache[chapter.id] = ps;
    return ps;
  }

  /// 连续阅读的位置回调：记录当前章/段与章内比例。
  void _onContinuousPosition(
      int chapterIndex, int paragraphIndex, double ratio) {
    _continuousRatio = ratio.clamp(0.0, 1.0);
    if (paragraphIndex != _paragraphIndex) _paragraphIndex = paragraphIndex;
    if (chapterIndex != _index) {
      setState(() => _index = chapterIndex);
    }
    // ignore: discarded_futures
    _persist();
  }

  /// 听书控制条：只在「正在读这本书」时出现。
  Widget? _speechBar(BuildContext context) {
    final speech = _speech;
    if (speech == null || !speech.isFor(widget.bookId)) return null;
    return ListenableBuilder(
      listenable: speech,
      builder: (context, _) => ReaderAudioBar(
        controller: speech,
        onClose: () => unawaited(speech.close()),
      ),
    );
  }

  Widget _buildBody(_ReaderTheme theme) {
    if (_paged && !_loading && _error == null && (_paragraphs?.isNotEmpty ?? false)) {
      return _buildPaged(theme);
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null) {
      final text = error is AquaException ? error.friendlyText : '正文加载失败';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined,
                  size: 48, color: theme.foreground.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.foreground)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                children: [
                  FilledButton.tonal(
                      onPressed: () => _load(_index), child: const Text('重试')),
                  if (_index < _maxIndex)
                    TextButton(
                        onPressed: () => _go(1), child: const Text('下一章')),
                ],
              ),
            ],
          ),
        ),
      );
    }
    if (!_paged) {
      return SafeArea(
        bottom: false,
        child: ContinuousChapters(
          controller: _continuous,
          typography: _type,
          chapters: widget.chapters.map((c) => c.id).toList(),
          initialChapter: _index,
          loadChapter: (i, _) => _paragraphsOf(i),
          onPosition: _onContinuousPosition,
          // 朗读高亮：段落用于跟随定位，字符区间用于词级卡拉OK。
          // 两者都给：音轨路径拿不到区间时自动回落到整段底色。
          highlightChapter: _speechHighlightChapter,
          highlightParagraph: _speechHighlightParagraph,
          highlightBase: _speechBaseRange(),
          highlightActive: _speechWordRange(),
          highlightStyle:
              _speechSettings?.style ?? SpeechHighlightStyle.highlight,
          highlightColorArgb:
              _speechSettings?.colorArgb ?? kSpeechColorFollowTheme,
          autoFollow: AppScope.read(context).settings.listenFollow,
          chapterTitle: (context, chapterIndex, _) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              widget.chapters[chapterIndex].title,
              style: TextStyle(
                color: theme.foreground,
                fontSize: _fontSize + 4,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
    }
    final paragraphs = _paragraphs ?? const <String>[];
    return SafeArea(
      bottom: false,
      child: SingleChildScrollView(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(22, 64, 22, 120),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _chapter.title,
              style: TextStyle(
                color: theme.foreground,
                fontSize: _fontSize + 4,
                fontWeight: FontWeight.w700,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 18),
            for (final paragraph in paragraphs)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  paragraph,
                  style: TextStyle(
                    color: theme.foreground,
                    fontSize: _fontSize,
                    height: _lineHeight,
                  ),
                ),
              ),
            if (paragraphs.isEmpty)
              Text('本章暂无正文',
                  style: TextStyle(color: theme.foreground.withValues(alpha: 0.6))),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _index > 0 ? () => _go(-1) : null,
                  child: const Text('上一章'),
                ),
                TextButton(
                  onPressed: _index < _maxIndex ? () => _go(1) : null,
                  child: const Text('下一章'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
