import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_source_model.dart';
import 'book_source_service.dart';
import 'builtin_sources.dart';
import 'provider/book_source_provider.dart';

/// 已导入书源注册表：增删改查 + 启停（ChangeNotifier 供 UI 订阅）。
///
/// 内置源（provider 声明的，如 Wenku8）首次加载时注入；用户停用或删除后
/// **不再重复注入**（`bookSource.builtinDismissed`），可完全按自己的源表使用。
class BookSourceStore extends ChangeNotifier {
  BookSourceStore(
    this._prefs, {
    BookSourceProviderRegistry? registry,
    List<BookSource> Function()? bundled,
  })  : _registry = registry ?? BookSourceService().registry,
        _bundled = bundled ?? builtinBookSources;

  static const String _key = 'bookSource.enabled';
  static const String _dismissedKey = 'bookSource.builtinDismissed';

  final SharedPreferences _prefs;
  final BookSourceProviderRegistry _registry;

  /// 随应用内置的规则源（测试可注入空表）。
  final List<BookSource> Function() _bundled;

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

  /// 内置源 url 集合（UI 用它打「内置」标记，不再限制操作）。
  Set<String> get builtinUrls => _registry.builtinUrls;

  bool isBuiltin(String url) => builtinUrls.contains(url);

  /// 用户删掉/关掉过的内置源（不再自动注入）。
  final Set<String> _dismissed = <String>{};

  bool isDismissed(String url) => _dismissed.contains(url);

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
    _ensureBuiltins();
    _loaded = true;
    notifyListeners();
  }

  /// 注入内置源：**只补缺失**，不覆盖用户的启停与编辑；被删过的不再注入。
  void _ensureBuiltins() {
    final rawDismissed = _prefs.getString(_dismissedKey);
    if (rawDismissed != null && rawDismissed.isNotEmpty) {
      try {
        final list = jsonDecode(rawDismissed);
        if (list is List) {
          _dismissed
            ..clear()
            ..addAll(list.map((e) => e.toString()));
        }
      } catch (_) {
        // 坏数据当没删过。
      }
    }

    var changed = false;
    // 1) provider 声明的内置源（如 Wenku8，默认停用）
    for (final builtin in _registry.builtinSources) {
      if (_dismissed.contains(builtin.url)) continue;
      if (byUrl(builtin.url) != null) continue;
      _sources.add(builtin);
      changed = true;
    }
    // 2) 随应用内置的**实测可用**规则源（免登录站点）
    for (final bundled in _bundled()) {
      if (_dismissed.contains(bundled.url)) continue;
      if (byUrl(bundled.url) != null) continue;
      _sources.add(bundled);
      changed = true;
    }
    if (changed) {
      // 不 await：ensureLoaded 的调用方不关心落盘时机，但不能丢状态。
      _persist();
    }
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

  /// 替换同 url 的源（改 Cookie/命名等元数据；内置源也允许，url 不变）。
  Future<void> update(BookSource source) async {
    final existing = byUrl(source.url);
    if (existing == null) return;
    final index = _sources.indexOf(existing);
    _sources[index] = source;
    await _persist();
  }

  /// 切启停（内置源同样可以关；关掉后不再自动注入）。
  Future<void> setEnabled(String url, bool enabled) async {
    final source = byUrl(url);
    if (source == null) return;
    final index = _sources.indexOf(source);
    // 必须经 copyWithEnabled：手工重建会丢掉 format/rawRuleJson（方言源切启停即坏）。
    _sources[index] = source.copyWithEnabled(enabled);
    if (isBuiltin(url) && !enabled) _dismissed.add(url);
    if (isBuiltin(url) && enabled) _dismissed.remove(url);
    await _persist();
    await _persistDismissed();
  }

  /// 删除源（内置源也可删，删后不再自动注入）。
  Future<bool> remove(String url) async {
    final removed = _sources.any((s) => s.url == url);
    _sources.removeWhere((s) => s.url == url);
    if (isBuiltin(url)) _dismissed.add(url);
    await _persist();
    await _persistDismissed();
    return removed;
  }

  /// 一键清理：删除校验失败的源（[urls] 由调用方探测得到）。
  ///
  /// 内置源一并删除并记为「已忽略」，避免下次启动又被注入。
  Future<int> removeAll(Iterable<String> urls) async {
    final targets = urls.toSet();
    if (targets.isEmpty) return 0;
    final before = _sources.length;
    for (final url in targets) {
      if (isBuiltin(url)) _dismissed.add(url);
    }
    _sources.removeWhere((s) => targets.contains(s.url));
    await _persist();
    await _persistDismissed();
    return before - _sources.length;
  }

  Future<void> _persistDismissed() async {
    await _prefs.setString(_dismissedKey, jsonEncode(_dismissed.toList()));
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode([for (final s in _sources) s.toJson()]),
    );
    notifyListeners();
  }
}
