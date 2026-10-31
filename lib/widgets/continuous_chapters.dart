import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/reader/reader_speech_settings.dart';
import 'reader/speech_span_layout.dart';

import '../core/reader/reader_typography.dart';

/// 连续阅读体：把章节按需拼成一条长列表，读到底自动接上下一章。
///
/// 段落是列表里的独立 item，所以「现在读到第几段」可以直接由 item 下标得出。
///
/// **当前章的判定不能依赖 GlobalKey 的 context**：ListView 会回收屏幕外的 item，
/// 被回收后 context 变 null，于是「当前章」会退回第一个已加载的章（表现为读到
/// 第八章又跳回第四章）。这里改为在**构建时**把每章起点的绝对 offset 记下来，
/// 之后只用 offset 表判断。
class ContinuousChapters extends StatefulWidget {
  const ContinuousChapters({
    super.key,
    required this.chapters,
    required this.initialChapter,
    required this.loadChapter,
    required this.onPosition,
    this.chapterTitle,
    this.controller,
    this.typography,
    this.textColor,
    this.night = false,
    this.highlightChapter,
    this.highlightParagraph,
    this.highlightBase,
    this.highlightActive,
    this.highlightStyle = SpeechHighlightStyle.highlight,
    this.highlightColorArgb = 0x66FFC107,
    this.autoFollow = true,
  });

  /// 全部章节的 id（顺序即阅读顺序）。
  final List<String> chapters;

  /// 起始章下标。
  final int initialChapter;

  /// 取某章的段落文本。
  final Future<List<String>> Function(int index, String chapterId) loadChapter;

  /// 位置变化：(章下标, 段下标, 章内比例 0..1)。
  final void Function(int chapterIndex, int paragraphIndex, double ratio)
      onPosition;

  /// 章标题的渲染。
  final Widget Function(BuildContext context, int chapterIndex, String title)?
      chapterTitle;

  /// 外部翻屏控制（阅读页九宫格「上一页/下一页」用）。
  final ContinuousChaptersController? controller;

  /// 排版参数（字号/行距/段距/边距/字体）。为空时退回旧默认值。
  final ReaderTypography? typography;

  /// 正文字色：阅读页传夜间切换后的阅读主题字色。
  /// 不传退回 App 主题色——但 App 主题不随阅读夜间开关变化，
  /// 黑底深字不可读（滚动模式夜间字色 bug 的根因）。
  final Color? textColor;

  /// 阅读器夜间开关（朗读高亮的黑白兜底跟着它走，而非 App 主题亮度）。
  final bool night;

  /// 正在朗读的章（与 [highlightParagraph] 配合，null 表示不高亮）。
  final int? highlightChapter;

  /// 正在朗读的段落下标（章内序号）。
  final int? highlightParagraph;

  /// 正在念的**句子**（章内字符区间）。给了就改用区间切 span（句底纹），
  /// 比整段铺色精确；音轨路径拿不到句区间时仍走整段底色。
  final (int, int)? highlightBase;

  /// 当前**词**（章内字符区间）——卡拉OK 的实心高亮。
  final (int, int)? highlightActive;

  /// 高亮样式与颜色：滚动模式与翻页模式必须用同一套设置，否则两边观感不一致。
  final SpeechHighlightStyle highlightStyle;
  final int highlightColorArgb;

  /// 朗读推进时是否自动把高亮段滚进视口。
  final bool autoFollow;

  @override
  State<ContinuousChapters> createState() => _ContinuousChaptersState();
}

class _Flat {
  _Flat(
    this.chapter,
    this.isTitle,
    this.text, [
    this.paraIndex = -1,
    this.charStart = -1,
  ]);

  final int chapter;
  final bool isTitle;
  final String text;

  /// 该段在本章内的序号（标题行为 -1）；朗读高亮按它匹配。
  final int paraIndex;

  /// 该段在**章内字符坐标系**的起点（段落以 `'\n'` 相接，与分页/朗读同一系）。
  /// 标题行为 -1（不参与字符区间高亮）。
  final int charStart;
}

class _ContinuousChaptersState extends State<ContinuousChapters> {
  final _scroll = ScrollController();
  final _flat = <_Flat>[];
  final _chapterStart = <int, int>{};
  final _titleKeys = <int, GlobalKey>{};

  /// 每章起点在滚动内容中的绝对 offset（构建时记录一次，之后长期有效）。
  final _chapterOffsets = <int, double>{};

  int _loadedThrough = -1;

  /// 同一时刻只允许一次追加：并发追加会让章节顺序交错（曾出现 5→7→6）。
  bool _appending = false;
  bool _didInitialJump = false;
  Timer? _report;

  /// 列表代号：换章重建后，旧 append 的 await 结果必须丢弃。
  int _appendEpoch = 0;

  /// 重建后要跳到的章（外部跳章时用来覆盖 widget.initialChapter 的旧值）。
  int? _jumpTarget;

  /// 朗读高亮段的 key：用于 `Scrollable.ensureVisible` 跟随。
  final GlobalKey _speechKey = GlobalKey();

  /// 当前阅读位置的锚点 key：排版变化后据此回到原来那一段。
  final GlobalKey _anchorKey = GlobalKey();

  /// 当前读到哪一章 / 哪一段（排版重排后用来恢复位置）。
  int _currentChapter = -1;
  int _currentPara = -1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.controller?._attach(this);
    _append(widget.initialChapter);
  }

  @override
  void didUpdateWidget(covariant ContinuousChapters oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    final highlightChanged =
        oldWidget.highlightChapter != widget.highlightChapter ||
            oldWidget.highlightParagraph != widget.highlightParagraph;
    if (highlightChanged && widget.highlightParagraph != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followSpeech());
    }
    // 排版变了（字号/行距/字体）：行高全变，位置表失效，
    // 必须回到原来那一段，否则会落到别的章。
    if (oldWidget.typography != widget.typography) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reanchor());
    }
  }

  /// 排版重排后回到当前段：优先用锚点 item，兜底跳到当前章。
  void _reanchor() {
    if (!mounted) return;
    final ctx = _anchorKey.currentContext;
    if (ctx != null) {
      unawaited(Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 200),
        alignment: 0.3,
      ));
      return;
    }
    if (_currentChapter >= 0) _jumpToChapter(_currentChapter);
  }

  /// 朗读推进：把高亮段滚进视口；目标段还没构建就先跳到所属章。
  void _followSpeech() {
    if (!mounted || !widget.autoFollow) return;
    final chapter = widget.highlightChapter;
    if (chapter == null) return;
    final ctx = _speechKey.currentContext;
    if (ctx != null) {
      unawaited(Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 220),
        alignment: 0.35,
      ));
      return;
    }
    if (!_chapterStart.containsKey(chapter)) _jumpTo(chapter);
  }

  Color _speechHighlight(ThemeData theme) => theme.brightness == Brightness.dark
      ? const Color(0x40FFD54F)
      : const Color(0xFFFFF0A8);

  @override
  void dispose() {
    widget.controller?._detach(this);
    _report?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  double get _scrollOffset =>
      _scroll.hasClients ? _scroll.position.pixels : 0;

  double get _maxScrollExtent =>
      _scroll.hasClients ? _scroll.position.maxScrollExtent : 0;

  double get _viewportHeight =>
      _scroll.hasClients ? _scroll.position.viewportDimension : 0;

  /// 翻一屏；到边返回 false（调用方据此换章）。
  Future<bool> _scrollByPage(int direction) async {
    if (!_scroll.hasClients) return false;
    final position = _scroll.position;
    final delta = position.viewportDimension * 0.9;
    if (direction > 0) {
      if (position.maxScrollExtent - position.pixels <= 1) return false;
      final target = math.min(position.pixels + delta, position.maxScrollExtent);
      await _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      return true;
    }
    if (position.pixels <= 1) return false;
    final target = math.max(position.pixels - delta, 0.0);
    await _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
    return true;
  }

  Future<void> _append(int chapterIndex) async {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    if (_appending) return;
    _appending = true;
    final epoch = _appendEpoch;
    try {
      final id = widget.chapters[chapterIndex];
      final paragraphs = await widget.loadChapter(chapterIndex, id);
      if (!mounted || epoch != _appendEpoch) return;
      _chapterStart[chapterIndex] = _flat.length;
      _flat.add(_Flat(chapterIndex, true, ''));
      var paraIndex = 0;
      // 章内字符偏移：与分页/朗读共用同一个坐标系，段落之间以 '\n' 相接。
      var charOffset = 0;
      for (final p in paragraphs) {
        _flat.add(_Flat(chapterIndex, false, p, paraIndex++, charOffset));
        charOffset += p.length + 1;
      }
      if (chapterIndex > _loadedThrough) _loadedThrough = chapterIndex;
      setState(() {});
      if (!_didInitialJump) {
        _didInitialJump = true;
        final target = _jumpTarget ?? widget.initialChapter;
        _jumpTarget = null;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _jumpToChapter(target));
      }
      // 追加完若仍在底部附近，继续接下一章（首章加载期间错过的触底要补上）。
      if (_nearBottom) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _maybeLoadNext());
      }
    } finally {
      // 只有本代 append 能解锁，否则会把新章的加载锁提前释放。
      if (epoch == _appendEpoch) _appending = false;
    }
  }

  /// 换到指定章：清空已拼接内容并从该章重新开始（目录/上下章跳转用）。
  void _resetTo(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    _appendEpoch++;
    _appending = false;
    _didInitialJump = false;
    _loadedThrough = -1;
    _jumpTarget = chapterIndex;
    _flat.clear();
    _chapterStart.clear();
    _chapterOffsets.clear();
    _titleKeys.clear();
    _report?.cancel();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    setState(() {});
    _append(chapterIndex);
  }

  /// 外部跳章：已加载的章只滚动过去，未加载的章重建列表。
  void _jumpTo(int chapterIndex) {
    if (chapterIndex < 0 || chapterIndex >= widget.chapters.length) return;
    if (_chapterStart.containsKey(chapterIndex)) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _jumpToChapter(chapterIndex));
    } else {
      _resetTo(chapterIndex);
    }
  }

  bool get _nearBottom {
    if (!_scroll.hasClients) return false;
    return _scroll.position.maxScrollExtent - _scroll.offset < 900;
  }

  void _jumpToChapter(int chapterIndex, {int attempt = 0}) {
    if (!_scroll.hasClients) return;
    var target = _chapterOffsets[chapterIndex];
    if (target == null) {
      // 起点还没记上（首帧）：退回用标题 widget 的位置。
      final box = _titleKeys[chapterIndex]?.currentContext?.findRenderObject();
      if (box is! RenderBox) {
        // 目标章还没被构建（不在当前列表里）：有限重试后放弃，避免死循环。
        if (attempt >= 3) return;
        WidgetsBinding.instance.addPostFrameCallback(
            (_) => _jumpToChapter(chapterIndex, attempt: attempt + 1));
        return;
      }
      target = _scroll.offset + box.localToGlobal(Offset.zero).dy;
    }
    _scroll.jumpTo(
        (target - 8).clamp(0.0, _scroll.position.maxScrollExtent));
  }

  /// 快到底了就把下一章接上来（位置不会跳，因为是往下追加）。
  Future<void> _maybeLoadNext() async {
    if (_appending || _loadedThrough < 0) return;
    if (_loadedThrough >= widget.chapters.length - 1) return;
    if (!_nearBottom) return;
    await _append(_loadedThrough + 1);
  }  /// 记录某章起点的绝对 offset（构建时 context 一定可用，之后不再依赖它）。
  void _rememberChapterStart(int chapterIndex, GlobalKey key) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final box = key.currentContext?.findRenderObject();
      if (box is! RenderBox) return;
      final offset = _scroll.offset + box.localToGlobal(Offset.zero).dy;
      final old = _chapterOffsets[chapterIndex];
      // 同一章可能被构建多次，取更靠前（更小）的那个作为起点。
      if (old == null || offset < old) _chapterOffsets[chapterIndex] = offset;
    });
  }

  void _onScroll() {
    _maybeLoadNext();
    _report?.cancel();
    _report = Timer(const Duration(milliseconds: 600), _reportPosition);
  }

  void _reportPosition() {
    if (!mounted || _flat.isEmpty || !_scroll.hasClients) return;
    final keys = _chapterOffsets.keys.toList()..sort();
    if (keys.isEmpty) return;
    final offset = _scroll.offset;

    // 当前章 = 起点已经滚过去的最后一章。
    var current = keys.first;
    for (final k in keys) {
      final start = _chapterOffsets[k] ?? double.infinity;
      if (start <= offset) current = k;
    }
    final start = _chapterOffsets[current] ?? offset;
    final scrolled = offset - start;
    final count = _paragraphCount(current);
    final nextStart = _chapterOffsets[current + 1];
    final double ratio;
    if (nextStart != null && nextStart > start) {
      // 下一章已加载：用真实章高算比例（最准）。
      ratio = ((scrolled / (nextStart - start)).clamp(0.0, 1.0));
    } else {
      // 下一章还没加载：用本章估计高度兜底（段落数 × 平均段高 42），
      // 否则比例恒为 0，听书会总从章开头开始。
      final est = count <= 0 ? 1.0 : count * 42.0;
      ratio = (scrolled / est).clamp(0.0, 1.0);
    }
    final paragraphIndex =
        count <= 0 ? 0 : (ratio * count).floor().clamp(0, count - 1);
    // 记住当前位置：排版变化后据此回到同一段（见 _reanchor）。
    _currentChapter = current;
    _currentPara = paragraphIndex;
    widget.onPosition(current, paragraphIndex, ratio);
  }

  int _paragraphCount(int chapterIndex) {
    var count = 0;
    for (final item in _flat) {
      if (item.chapter == chapterIndex && !item.isTitle) count++;
    }
    return count;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final type = widget.typography;
    final paragraphGap = type?.paragraphSpacing ?? 14;
    return ListView.builder(
      controller: _scroll,
      padding: EdgeInsets.fromLTRB(
        type?.paddingLeft ?? 22,
        20,
        type?.paddingRight ?? 22,
        140,
      ),
      // 字号变化要重排，否则列表会沿用旧的行高估算。
      key: ValueKey<String>(
        'cc_${type?.fontSize ?? 19}_${type?.lineHeight ?? 1.8}_${type?.fontFamily ?? '-'}',
      ),
      itemCount: _flat.length,
      itemBuilder: (context, i) {
        final item = _flat[i];
        if (item.isTitle) {
          final key = _titleKeys.putIfAbsent(item.chapter, GlobalKey.new);
          _rememberChapterStart(item.chapter, key);
          return Padding(
            key: key,
            padding: const EdgeInsets.only(top: 22, bottom: 12),
            child: widget.chapterTitle?.call(context, item.chapter, '') ??
                Text('第 ${item.chapter + 1} 章',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
          );
        }
        final highlighted = item.chapter == widget.highlightChapter &&
            item.paraIndex == widget.highlightParagraph;
        // 锚点 item：排版重排后用它回到原来那一段。
        final anchored = item.chapter == _currentChapter &&
            item.paraIndex == _currentPara;
        // 有字符区间就切 span（词级卡拉OK + 句底纹）；否则回落到整段底色
        // （音轨路径只有段落，没有句/词时间点）。两条路径共用同一个
        // [lineSpansFor]，不在这里另写一份切分。
        final base = widget.highlightBase;
        final active = widget.highlightActive;
        final sameChapter = item.chapter == widget.highlightChapter;
        final useSpans = sameChapter &&
            item.charStart >= 0 &&
            lineNeedsSpans(
              lineCharStart: item.charStart,
              lineCharEnd: item.charStart + item.text.length,
              markings: const [],
              base: base,
              active: active,
            );
        final Widget body;
        if (useSpans) {
          body = Text.rich(
            TextSpan(
              children: lineSpansFor(
                lineText: item.text,
                lineCharStart: item.charStart,
                lineCharEnd: item.charStart + item.text.length,
                markings: const [],
                base: base,
                active: active,
                style: widget.highlightStyle,
                colorArgb: widget.highlightColorArgb,
                night: widget.night || theme.brightness == Brightness.dark,
              ),
            ),
            style: _bodyStyle(theme),
          );
        } else {
          body = Text(item.text, style: _bodyStyle(theme));
        }
        return Padding(
          key: anchored ? _anchorKey : null,
          padding: EdgeInsets.only(bottom: paragraphGap),
          child: Padding(
            key: highlighted ? _speechKey : null,
            padding: EdgeInsets.zero,
            // 已有字符区间时底纹在 span 里，不再整段铺色（会盖住词实心）。
            child: highlighted && !useSpans
                ? ColoredBox(color: _speechHighlight(theme), child: body)
                : body,
          ),
        );
      },
    );
  }

  TextStyle _bodyStyle(ThemeData theme) {
    final color = widget.textColor ??
        theme.textTheme.bodyLarge?.color ??
        const Color(0xFF222222);
    final type = widget.typography;
    if (type != null) return type.bodyStyle(color: color);
    return TextStyle(fontSize: 19, height: 1.8, color: color);
  }
}

/// 连续阅读体的外部控制器：阅读页用它实现「左右点击翻一屏」。
class ContinuousChaptersController {
  _ContinuousChaptersState? _state;

  void _attach(_ContinuousChaptersState state) => _state = state;

  void _detach(_ContinuousChaptersState state) {
    if (identical(_state, state)) _state = null;
  }

  bool get attached => _state != null;

  double get viewportHeight => _state?._viewportHeight ?? 0;

  bool get atTop => (_state?._scrollOffset ?? 0) <= 1;

  bool get atBottom {
    final state = _state;
    if (state == null) return true;
    final max = state._maxScrollExtent;
    return max <= 0 || max - state._scrollOffset <= 1;
  }

  /// 翻一屏。返回 `false` 表示已到边界，调用方应切换章节。
  Future<bool> scrollByPage(int direction) async {
    final state = _state;
    if (state == null) return false;
    return state._scrollByPage(direction);
  }

  /// 跳到指定章：已加载的章直接滚过去，未加载的章重建列表。
  void jumpToChapter(int chapterIndex) => _state?._jumpTo(chapterIndex);

  void jumpToTop() {
    final state = _state;
    if (state == null || !state._scroll.hasClients) return;
    state._scroll.jumpTo(0);
  }

  void jumpToBottom() {
    final state = _state;
    if (state == null || !state._scroll.hasClients) return;
    state._scroll.jumpTo(state._scroll.position.maxScrollExtent);
  }
}