/// 阅读统计：按天累计阅读时长、按书累计、连续天数与热力图数据。
///
/// 存储：SharedPreferences `reading_stats.v1`（JSON，纯派生数据，不进备份）。
/// 时间口径：只统计阅读器前台时长（阅读页每 30s 落一次，见 `ReadingStatsTicker`）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一天的统计。
class ReadingDay {
  const ReadingDay({required this.date, required this.seconds, required this.books});

  /// `yyyy-MM-dd`。
  final String date;
  final int seconds;

  /// 当天各书时长（bookId → 秒）。
  final Map<String, int> books;

  int get minutes => (seconds / 60).round();
}

/// 统计快照（供 UI 直接读）。
class ReadingStatsSnapshot {
  const ReadingStatsSnapshot({
    required this.days,
    required this.books,
    required this.totalSeconds,
    required this.streakDays,
  });

  /// 按日期升序。
  final List<ReadingDay> days;

  /// bookId → 累计秒。
  final Map<String, int> books;
  final int totalSeconds;

  /// 连续阅读天数（截至今天或昨天）。
  final int streakDays;

  int secondsOn(DateTime day) {
    final key = dateKey(day);
    for (final d in days) {
      if (d.date == key) return d.seconds;
    }
    return 0;
  }

  /// 最近 [count] 天（含今天），缺的补 0，用于热力图。
  List<ReadingDay> recentDays(int count) {
    final map = {for (final d in days) d.date: d};
    final today = DateTime.now();
    return [
      for (var i = count - 1; i >= 0; i--)
        () {
          final day = today.subtract(Duration(days: i));
          final key = dateKey(day);
          return map[key] ??
              ReadingDay(date: key, seconds: 0, books: const {});
        }(),
    ];
  }
}

/// `yyyy-MM-dd`（本地时区）。
String dateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

/// 统计仓库。
class ReadingStatsStore extends ChangeNotifier {
  ReadingStatsStore({this.prefs});

  /// UI 侧默认实例（避免给 AppScope 再加一层参数）。
  static final ReadingStatsStore shared = ReadingStatsStore();

  static const String prefsKey = 'reading_stats.v1';
  static const int maxDays = 400;

  SharedPreferences? prefs;
  bool _loaded = false;

  final Map<String, ReadingDay> _days = <String, ReadingDay>{};
  final Map<String, int> _books = <String, int>{};

  Future<SharedPreferences> get _prefsAsync async =>
      prefs ??= await SharedPreferences.getInstance();

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final prefs = await _prefsAsync;
    final raw = prefs.getString(prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final json = jsonDecode(raw);
        if (json is Map<String, dynamic>) {
          final days = json['days'];
          if (days is Map) {
            days.forEach((key, value) {
              if (value is! Map) return;
              final seconds = (value['s'] as num?)?.toInt() ?? 0;
              final books = <String, int>{};
              final rawBooks = value['b'];
              if (rawBooks is Map) {
                rawBooks.forEach((k, v) {
                  final n = (v as num?)?.toInt() ?? 0;
                  if (n > 0) books[k.toString()] = n;
                });
              }
              _days[key.toString()] =
                  ReadingDay(date: key.toString(), seconds: seconds, books: books);
            });
          }
          final books = json['books'];
          if (books is Map) {
            books.forEach((k, v) {
              final n = (v as num?)?.toInt() ?? 0;
              if (n > 0) _books[k.toString()] = n;
            });
          }
        }
      } catch (_) {
        // 坏数据按空表处理：统计是派生数据，坏了不该影响阅读。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 累加一次阅读时长（[at] 默认当前时间，测试可指定）。
  Future<void> addDuration(
    String bookId,
    Duration duration, {
    DateTime? at,
  }) async {
    await ensureLoaded();
    final seconds = duration.inSeconds;
    if (seconds <= 0) return;
    final key = dateKey(at ?? DateTime.now());
    final existing = _days[key];
    final books = Map<String, int>.from(existing?.books ?? const {});
    if (bookId.isNotEmpty) {
      books[bookId] = (books[bookId] ?? 0) + seconds;
      _books[bookId] = (_books[bookId] ?? 0) + seconds;
    }
    _days[key] = ReadingDay(
      date: key,
      seconds: (existing?.seconds ?? 0) + seconds,
      books: books,
    );
    _trim();
    await _persist();
  }

  void _trim() {
    if (_days.length <= maxDays) return;
    final keys = _days.keys.toList()..sort();
    for (final key in keys.take(_days.length - maxDays)) {
      _days.remove(key);
    }
  }

  Future<void> _persist() async {
    final prefs = await _prefsAsync;
    await prefs.setString(
      prefsKey,
      jsonEncode({
        'days': {
          for (final e in _days.entries)
            e.key: {'s': e.value.seconds, 'b': e.value.books},
        },
        'books': _books,
      }),
    );
    notifyListeners();
  }

  ReadingStatsSnapshot snapshot() {
    final days = _days.values.toList()..sort((a, b) => a.date.compareTo(b.date));
    return ReadingStatsSnapshot(
      days: days,
      books: Map.unmodifiable(_books),
      totalSeconds: _days.values.fold(0, (sum, d) => sum + d.seconds),
      streakDays: _streak(days),
    );
  }

  /// 连续天数：从今天往回数，允许「今天还没读」时从昨天起算。
  int _streak(List<ReadingDay> days) {
    final set = {
      for (final d in days)
        if (d.seconds > 0) d.date,
    };
    if (set.isEmpty) return 0;
    var cursor = DateTime.now();
    if (!set.contains(dateKey(cursor))) {
      cursor = cursor.subtract(const Duration(days: 1));
      if (!set.contains(dateKey(cursor))) return 0;
    }
    var streak = 0;
    while (set.contains(dateKey(cursor))) {
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// 清空统计（设置页「清除阅读统计」）。
  Future<void> clear() async {
    _days.clear();
    _books.clear();
    await _persist();
  }
}

/// 阅读时长计时器：阅读页每 [interval] 落一次（页面不可见时不计）。
class ReadingStatsTicker {
  ReadingStatsTicker({
    required this.store,
    required this.bookId,
    this.interval = const Duration(seconds: 30),
    this.isActive,
  });

  final ReadingStatsStore store;
  final String bookId;
  final Duration interval;

  /// 是否应该计时（默认恒 true；阅读页传入「已就绪且在栈顶」）。
  final bool Function()? isActive;

  Future<void> tick() async {
    if (isActive != null && !isActive!()) return;
    await store.addDuration(bookId, interval);
  }
}
