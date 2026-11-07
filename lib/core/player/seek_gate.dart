import 'dart:async';

/// seek 闸门：把高频连发的 seek 合并成「最新目标胜出」，未就绪时忽略，
/// 异常不外抛、经 [SeekGateEvent] 上报。
///
/// 背景（安卓拖进度条崩溃，证据先行）：进度条 `onChanged` 每个采样都会发
/// 一次 seek，一次拖动几十连发；安卓上 media_kit/libmpv 在密集 seek 下有
/// native 崩溃的用户反馈。Dart 层能做的防御：
/// - 未打开媒体（未就绪）不 seek；
/// - 执行中的 seek 不叠加——只保留最新目标，正在跑的那个循环结束后会把它
///   带上（**排队但合并**：中间目标丢弃，最终位置不丢）；
/// - 每次 native 调用包 try/catch，异常经 [SeekGateEvent.error] 上报，
///   绝不让未 await 的调用变成未捕获异常；
/// - breadcrumb 事件经 [onEvent] 上报（发起/完成/忽略/异常与位置），带
///   节流（防拖动刷屏），异常永不节流。
///
/// 缓冲中**不**额外拦截：mpv 核心对 seek 命令自带串行排队，Dart 层再拦会
/// 破坏「缓冲中拖动到位后直接跳过去」的预期；连发压力由合并解决。真正的
/// native 崩溃修复需要用户 logcat（见任务报告「需要用户提供的信息」）。
enum SeekGateEvent {
  /// 已向播放器发起一次 seek（含目标位置）。
  dispatch,

  /// 一次 seek 完成。
  applied,

  /// seek 失败（含异常与位置）。
  error,

  /// 播放器未就绪，seek 被忽略。
  ignored,
}

class SeekGate {
  SeekGate({
    required Future<void> Function(Duration position) run,
    this.onEvent,
    DateTime Function()? now,
    this.eventInterval = const Duration(milliseconds: 800),
  })  : _execute = run,
        _now = now ?? DateTime.now;

  final Future<void> Function(Duration position) _execute;

  /// breadcrumb 出口；null 表示不关心事件。
  final void Function(
          SeekGateEvent event, Duration position, Object? error, StackTrace? stack)?
      onEvent;

  /// 发起/完成事件的节流窗口；[SeekGateEvent.error] / [SeekGateEvent.ignored]
  /// 永不节流（都是低频且关键的证据）。
  final Duration eventInterval;

  final DateTime Function() _now;
  // 节流窗口按事件种类各记一个时间戳：一次 seek 的「发起→完成」对在同一个
  // 窗口内都能上报（各 1 条），而不是完成事件总被发起事件顶掉。
  DateTime _lastDispatch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastApplied = DateTime.fromMillisecondsSinceEpoch(0);

  bool _open = false;
  bool _running = false;
  Duration? _pending;

  /// 播放器是否已打开媒体。由引擎在 open/stop/dispose 时接线。
  bool get isOpen => _open;

  void open() => _open = true;

  /// 关闭闸门（换源停止 / 播放器销毁）：丢弃待执行目标；正在跑的那次
  /// native 调用让它自然结束（不打断，避免引擎侧状态错位）。
  void close() {
    _open = false;
    _pending = null;
  }

  /// 发起一次 seek。未就绪时静默忽略（上报 [SeekGateEvent.ignored]）；
  /// 已有执行在跑时只更新目标并立即返回，由执行循环带上最新目标。
  Future<void> seek(Duration position) async {
    if (!_open) {
      _emit(SeekGateEvent.ignored, position);
      return;
    }
    _pending = position;
    if (_running) return;
    _running = true;
    try {
      while (_pending != null) {
        final target = _pending!;
        _pending = null;
        _emit(SeekGateEvent.dispatch, target);
        try {
          await _execute(target);
          _emit(SeekGateEvent.applied, target);
        } catch (e, stack) {
          // 异常只进 breadcrumb，不外抛：拖动路径大量 unawaited，
          // 外抛会变成未捕获异常拖垮页面。
          _emit(SeekGateEvent.error, target, e, stack);
        }
      }
    } finally {
      _running = false;
    }
  }

  void _emit(SeekGateEvent event, Duration position,
      [Object? error, StackTrace? stack]) {
    final sink = onEvent;
    if (sink == null) return;
    if (event == SeekGateEvent.dispatch || event == SeekGateEvent.applied) {
      final t = _now();
      final last =
          event == SeekGateEvent.dispatch ? _lastDispatch : _lastApplied;
      if (t.difference(last) < eventInterval) return;
      if (event == SeekGateEvent.dispatch) {
        _lastDispatch = t;
      } else {
        _lastApplied = t;
      }
    }
    sink(event, position, error, stack);
  }
}
