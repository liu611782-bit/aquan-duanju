/// 朗读单元播放队列（`11-02-listen-tts-streaming` S3）。
///
/// 纯状态机：**不碰播放器**，只负责「当前播到第几段、什么时候该预取下一段、
/// 跳段/切章怎么算位置」。播放器适配层按它给出的信号驱动真实音频。
///
/// 为什么单独抽出来：位置换算（单元序号 + 单元内毫秒）是流式播放最容易错的地方，
/// 用纯逻辑 + 单测锁住，比在播放器里调参可靠。
library;

/// 队列事件。
sealed class UnitQueueEvent {
  const UnitQueueEvent();
}

/// 需要开始/切换播放某个单元（[path] 由调用方提供，可能是临时文件）。
class UnitPlay extends UnitQueueEvent {
  const UnitPlay(this.index, {required this.startMs});
  final int index;
  final int startMs;
}

/// 预取某个单元（播到 70% 时触发，避免切段空隙）。
class UnitPrefetch extends UnitQueueEvent {
  const UnitPrefetch(this.index);
  final int index;
}

/// 一章播完。
class UnitQueueFinished extends UnitQueueEvent {
  const UnitQueueFinished();
}

/// 单元时长表（由合成结果填；未知时按 [fallbackUnitMs] 估算）。
class UnitDurations {
  UnitDurations(this._ms, {this.fallbackUnitMs = 20000});

  final List<int> _ms;
  final int fallbackUnitMs;

  int get length => _ms.length;

  int operator [](int index) => index >= 0 && index < _ms.length
      ? (_ms[index] > 0 ? _ms[index] : fallbackUnitMs)
      : fallbackUnitMs;

  /// 前面所有单元的累计时长（= 该单元在整章里的起点）。
  int startOf(int index) {
    var total = 0;
    for (var i = 0; i < index && i < _ms.length; i++) {
      total += this[i];
    }
    return total;
  }

  int get totalMs {
    var total = 0;
    for (var i = 0; i < _ms.length; i++) {
      total += this[i];
    }
    return total;
  }
}

/// 单元播放队列状态机。
class UnitQueue {
  UnitQueue({
    required this.durations,
    int startIndex = 0,
    this.prefetchAt = 0.7,
  })  : _index = startIndex,
        _prefetched = <int>{};

  final UnitDurations durations;

  /// 播到该比例时触发预取（0.7 = 剩 30% 时开始拉下一段）。
  final double prefetchAt;

  int _index;
  final Set<int> _prefetched;
  bool _finished = false;

  int get index => _index;
  bool get isFinished => _finished;

  /// 开始播放（返回首个单元与起始毫秒）。
  List<UnitQueueEvent> begin({int startMs = 0}) {
    _finished = false;
    _prefetched.clear();
    _prefetched.add(_index);
    return [UnitPlay(_index, startMs: startMs)];
  }

  /// 当前单元播放进度（毫秒）：到达阈值就发预取。
  List<UnitQueueEvent> onProgress(int msInUnit) {
    if (_finished) return const [];
    final events = <UnitQueueEvent>[];
    final unitMs = durations[_index];
    if (unitMs > 0 &&
        msInUnit >= (unitMs * prefetchAt).round() &&
        _index + 1 < durations.length &&
        _prefetched.add(_index + 1)) {
      events.add(UnitPrefetch(_index + 1));
    }
    return events;
  }

  /// 当前单元播完 → 切下一段；已经是最后一段则宣告整章结束。
  List<UnitQueueEvent> onUnitCompleted() {
    if (_finished) return const [];
    if (_index + 1 >= durations.length) {
      _finished = true;
      return const [UnitQueueFinished()];
    }
    _index++;
    _prefetched.add(_index);
    return [UnitPlay(_index, startMs: 0)];
  }

  /// 跳段（点目录/拖动进度）：返回目标单元与单元内偏移。
  List<UnitQueueEvent> seekToUnit(int unitIndex, {int msInUnit = 0}) {
    final clamped = unitIndex.clamp(0, durations.length - 1);
    _index = clamped;
    _finished = false;
    _prefetched.add(clamped);
    return [UnitPlay(clamped, startMs: msInUnit)];
  }

  /// 按整章毫秒定位到「单元 + 单元内毫秒」。
  List<UnitQueueEvent> seekToChapterMs(int chapterMs) {
    var acc = 0;
    for (var i = 0; i < durations.length; i++) {
      final unitMs = durations[i];
      if (chapterMs < acc + unitMs || i == durations.length - 1) {
        return seekToUnit(i, msInUnit: (chapterMs - acc).clamp(0, unitMs));
      }
      acc += unitMs;
    }
    return seekToUnit(0);
  }

  /// 对外的整章毫秒（进度条/继续听用）。
  int get chapterMs => durations.startOf(_index);

  /// 对外的整章比例 0..1。
  double get chapterRatio {
    final total = durations.totalMs;
    if (total <= 0) return 0;
    return (chapterMs / total).clamp(0, 1).toDouble();
  }

  /// 切章/退出：清空预取记录（下一次 begin 重新来）。
  void reset() {
    _prefetched.clear();
    _finished = false;
  }
}
