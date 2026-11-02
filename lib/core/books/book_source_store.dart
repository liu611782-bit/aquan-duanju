import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'book_source_model.dart';
import 'book_source_service.dart';
import 'provider/book_source_provider.dart';

/// 已导入书源注册表：增删改查 + 启停（ChangeNotifier 供 UI 订阅）。
///
/// 除用户导入的源，还会常驻**内置源**（provider 声明的，如 Wenku8）：
/// 加载时自动注入、强制启用、不允许删除/停用。
class BookSourceStore extends ChangeNotifier {
  BookSourceStore(this._prefs, {BookSourceProviderRegistry? registry})
      : _registry = registry ?? BookSourceService().registry;

  static const String _key = 'bookSource.enabled';

  final SharedPreferences _prefs;
  final BookSourceProviderRegistry _registry;

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

  /// 内置源 url 集合（UI 据此隐藏删除/启停按钮）。
  Set<String> get builtinUrls => _registry.builtinUrls;

  bool isBuiltin(String url) => builtinUrls.contains(url);

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

  /// 注入内置源：缺失则补、已存在则刷新元数据并强制启用。
  void _ensureBuiltins() {
    var changed = false;
    for (final builtin in _registry.builtinSources) {
      final existing = byUrl(builtin.url);
      if (existing == null) {
        _sources.add(builtin);
        changed = true;
        continue;
      }
      if (!existing.enabled ||
          existing.name != builtin.name ||
          existing.group != builtin.group ||
          existing.format != builtin.format) {
        final index = _sources.indexOf(existing);
        _sources[index] = BookSource(
          url: builtin.url,
          name: builtin.name,
          group: builtin.group,
          enabled: true,
          searchUrl: existing.searchUrl,
          ruleSearch: existing.ruleSearch,
          ruleBookInfo: existing.ruleBookInfo,
          ruleToc: existing.ruleToc,
          ruleContent: existing.ruleContent,
          jsLib: existing.jsLib,
          cookie: existing.cookie,
          format: builtin.format,
          rawRuleJson: existing.rawRuleJson,
        );
        changed = true;
      }
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

  /// 切启停；内置源常驻启用（传入 false 被忽略）。
  Future<void> setEnabled(String url, bool enabled) async {
    final source = byUrl(url);
    if (source == null) return;
    if (isBuiltin(url) && !enabled) return;
    final index = _sources.indexOf(source);
    // 必须经 copyWithEnabled：手工重建会丢掉 format/rawRuleJson（方言源切启停即坏）。
    _sources[index] = source.copyWithEnabled(enabled);
    await _persist();
  }

  /// 删除源；内置源拒绝删除并返回 false。
  Future<bool> remove(String url) async {
    if (isBuiltin(url)) return false;
    _sources.removeWhere((s) => s.url == url);
    await _persist();
    return true;
  }

  Future<void> _persist() async {
    await _prefs.setString(
      _key,
      jsonEncode([for (final s in _sources) s.toJson()]),
    );
    notifyListeners();
  }
}
