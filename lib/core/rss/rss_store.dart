/// 订阅源仓库：增删改 + 已读状态（prefs 持久化）。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rss_models.dart';

class RssStore extends ChangeNotifier {
  RssStore(this._prefs);

  static const String _key = 'rss.sources.v1';
  static const String _readKey = 'rss.read.v1';

  final SharedPreferences _prefs;
  final List<RssSource> _sources = <RssSource>[];
  final Set<String> _read = <String>{};
  bool _loaded = false;

  List<RssSource> get sources => List.unmodifiable(_sources);

  bool isRead(String id) => _read.contains(id);

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    final raw = _prefs.getString(_key);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          _sources
            ..clear()
            ..addAll([
              for (final item in list)
                if (item is Map<String, dynamic>) RssSource.fromJson(item),
            ]);
        }
      } catch (_) {
        // 坏数据按空表处理。
      }
    }
    final read = _prefs.getString(_readKey);
    if (read != null && read.isNotEmpty) {
      try {
        final list = jsonDecode(read);
        if (list is List) {
          _read
            ..clear()
            ..addAll(list.map((e) => e.toString()));
        }
      } catch (_) {}
    }
    _loaded = true;
    notifyListeners();
  }

  /// 导入订阅源 JSON（legado `rssSource` 数组 / 单对象 / `{sources:[...]}`）。
  Future<int> importJson(String text) async {
    await ensureLoaded();
    final List<dynamic> items;
    try {
      final decoded = jsonDecode(text.trim());
      if (decoded is List) {
        items = decoded;
      } else if (decoded is Map<String, dynamic>) {
        final inner = decoded['sources'] ?? decoded['rssSources'];
        items = inner is List ? inner : [decoded];
      } else {
        return 0;
      }
    } catch (_) {
      return 0;
    }
    var added = 0;
    for (final item in items) {
      if (item is! Map<String, dynamic>) continue;
      final source = RssSource.fromJson(item);
      if (source.url.isEmpty || !source.url.startsWith('http')) continue;
      if (_sources.any((s) => s.url == source.url)) continue;
      _sources.add(source);
      added++;
    }
    if (added > 0) await _persist();
    return added;
  }

  Future<void> add(RssSource source) async {
    await ensureLoaded();
    if (source.url.isEmpty) return;
    if (_sources.any((s) => s.url == source.url)) return;
    _sources.add(source);
    await _persist();
  }

  Future<void> remove(String url) async {
    await ensureLoaded();
    _sources.removeWhere((s) => s.url == url);
    await _persist();
  }

  Future<void> setEnabled(String url, bool enabled) async {
    await ensureLoaded();
    final index = _sources.indexWhere((s) => s.url == url);
    if (index < 0) return;
    _sources[index] = _sources[index].copyWith(enabled: enabled);
    await _persist();
  }

  Future<void> markRead(String articleId) async {
    if (!_read.add(articleId)) return;
    await _prefs.setString(_readKey, jsonEncode(_read.toList()));
    notifyListeners();
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode([for (final s in _sources) s.toJson()]),
    );
    notifyListeners();
  }
}
