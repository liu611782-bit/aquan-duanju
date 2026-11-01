import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_source_model.dart';

/// 已导入书源注册表：增删改查 + 启停（ChangeNotifier 供 UI 订阅）。
class BookSourceStore extends ChangeNotifier {
  BookSourceStore(this._prefs);

  static const String _key = 'bookSource.enabled';

  final SharedPreferences _prefs;

  final _sources = <BookSource>[];
  bool _loaded = false;

  List<BookSource> get sources => List.unmodifiable(_sources);

  List<BookSource> get enabled =>
      _sources.where((s) => s.enabled).toList();

  BookSource? byUrl(String url) {
    for (final s in _sources) {
      if (s.url == url) return s;
    }
    return null;
  }

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final raw = _prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        _sources
          ..clear()
          ..addAll(BookSource.listFromJson(list));
      } catch (_) {
        // 坏数据按空表处理：注册表坏了不该让聚合整个不可用。
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// 批量导入：按 url 去重（同 url 覆盖），返回新增数。
  Future<int> importAll(List<BookSource> incoming) async {
    await ensureLoaded();
    var added = 0;
    for (final source in incoming) {
      if (source.url.trim().isEmpty) continue;
      final existing = byUrl(source.url);
      if (existing != null) {
        final index = _sources.indexOf(existing);
        _sources[index] = source;
      } else {
        _sources.add(source);
        added++;
      }
    }
    await _persist();
    return added;
  }

  Future<void> setEnabled(String url, bool enabled) async {
    final source = byUrl(url);
    if (source == null) return;
    final index = _sources.indexOf(source);
    // 必须经 copyWithEnabled：手工重建会丢掉 format/rawRuleJson（方言源切启停即坏）。
    _sources[index] = source.copyWithEnabled(enabled);
    await _persist();
  }

  Future<void> remove(String url) async {
    _sources.removeWhere((s) => s.url == url);
    await _persist();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode([for (final s in _sources) s.toJson()]),
    );
    notifyListeners();
  }
}
