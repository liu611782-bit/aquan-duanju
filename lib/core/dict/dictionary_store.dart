/// 词典仓库：导入 StarDict（复制进应用目录）、索引持久化、跨词典查词。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'stardict.dart';

/// 导入结果。
class DictImportResult {
  const DictImportResult({this.info, this.error = ''});

  final DictInfo? info;
  final String error;

  bool get ok => info != null;
}

/// 词典仓库。
class DictionaryStore {
  DictionaryStore({
    required this.root,
    this.prefs,
  });

  /// 默认目录：`<appSupport>/dictionaries`。
  static Future<DictionaryStore> openDefault({SharedPreferences? prefs}) async {
    final support = await getApplicationSupportDirectory();
    return DictionaryStore(
      root: Directory('${support.path}/dictionaries'),
      prefs: prefs,
    );
  }

  static const String prefsKey = 'dictionaries.v1';

  final Directory root;
  SharedPreferences? prefs;

  final List<DictInfo> _dicts = <DictInfo>[];
  final Map<String, StarDict> _open = <String, StarDict>{};
  bool _loaded = false;

  List<DictInfo> get dictionaries => List.unmodifiable(_dicts);

  Future<SharedPreferences> get _prefsAsync async =>
      prefs ??= await SharedPreferences.getInstance();

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    if (!root.existsSync()) await root.create(recursive: true);
    final prefs = await _prefsAsync;
    final raw = prefs.getString(prefsKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          for (final item in list) {
            if (item is! Map<String, dynamic>) continue;
            final info = DictInfo.fromJson(item);
            if (info.id.isEmpty || !Directory(info.path).existsSync()) continue;
            _dicts.add(info);
          }
        }
      } catch (_) {
        // 坏索引按空表处理。
      }
    }
    _loaded = true;
  }

  /// 导入一个 `.ifo`（同目录的 .idx/.dict/.dict.dz 一起复制）。
  Future<DictImportResult> importIfo(String ifoPath) async {
    await ensureLoaded();
    final source = File(ifoPath);
    if (!source.existsSync()) {
      return const DictImportResult(error: '文件不存在');
    }
    if (!ifoPath.toLowerCase().endsWith('.ifo')) {
      return const DictImportResult(error: '请选择 .ifo 文件（StarDict 词典）');
    }
    final base = ifoPath.substring(0, ifoPath.length - 4);
    final idx = File('$base.idx');
    if (!idx.existsSync()) {
      return const DictImportResult(error: '同目录缺少 .idx 文件');
    }
    final dict = File('$base.dict');
    final dz = File('$base.dict.dz');
    if (!dict.existsSync() && !dz.existsSync()) {
      return const DictImportResult(error: '同目录缺少 .dict 或 .dict.dz');
    }

    final baseName = ifoPath.replaceAll('\\', '/').split('/').last;
    final id = _idOf(baseName + File(ifoPath).lengthSync().toString());
    final target = Directory('${root.path}/$id');
    if (!target.existsSync()) await target.create(recursive: true);
    await source.copy('${target.path}/$baseName');
    await idx.copy('${target.path}/${baseName.substring(0, baseName.length - 4)}.idx');
    if (dict.existsSync()) {
      await dict.copy(
          '${target.path}/${baseName.substring(0, baseName.length - 4)}.dict');
    } else {
      await dz.copy(
          '${target.path}/${baseName.substring(0, baseName.length - 4)}.dict.dz');
    }

    // 打开一次校验格式（坏词典不留脏数据）。
    try {
      final probe = await StarDict.open(target.path);
      final info = probe.info;
      await probe.close();
      _dicts.removeWhere((d) => d.id == id);
      _dicts.add(DictInfo(
        id: id,
        name: info.name,
        wordCount: info.wordCount,
        path: target.path,
        sametypesequence: info.sametypesequence,
      ));
      await _persist();
      return DictImportResult(info: _dicts.last);
    } catch (e) {
      try {
        await target.delete(recursive: true);
      } catch (_) {}
      return DictImportResult(error: '词典格式不支持：$e');
    }
  }

  /// 跨词典查词（命中即返回；多词典时按导入顺序）。
  Future<List<DictHit>> lookup(String word, {int limit = 8}) async {
    await ensureLoaded();
    final hits = <DictHit>[];
    for (final info in _dicts) {
      if (hits.length >= limit) break;
      try {
        final dict = await _openOf(info);
        final hit = await dict.lookup(word);
        if (hit != null) hits.add(hit);
      } catch (_) {
        // 单本词典坏了不影响其它词典。
        continue;
      }
    }
    return hits;
  }

  /// 前缀建议（合并各词典）。
  Future<List<String>> suggestions(String prefix, {int limit = 12}) async {
    await ensureLoaded();
    final out = <String>{};
    for (final info in _dicts) {
      if (out.length >= limit) break;
      try {
        final dict = await _openOf(info);
        out.addAll(await dict.suggestions(prefix, limit: limit));
      } catch (_) {
        continue;
      }
    }
    return out.take(limit).toList();
  }

  Future<bool> remove(String id) async {
    await ensureLoaded();
    final index = _dicts.indexWhere((d) => d.id == id);
    if (index < 0) return false;
    final info = _dicts.removeAt(index);
    await _open.remove(id)?.close();
    await _persist();
    try {
      await Directory(info.path).delete(recursive: true);
    } catch (_) {}
    return true;
  }

  Future<StarDict> _openOf(DictInfo info) async {
    final cached = _open[info.id];
    if (cached != null && cached.isOpen) return cached;
    final dict = await StarDict.open(info.path);
    _open[info.id] = dict;
    return dict;
  }

  Future<void> _persist() async {
    final prefs = await _prefsAsync;
    await prefs.setString(
      prefsKey,
      jsonEncode([for (final d in _dicts) d.toJson()]),
    );
  }

  Future<void> close() async {
    for (final dict in _open.values) {
      await dict.close();
    }
    _open.clear();
  }
}

String _idOf(String seed) {
  var hash = 0x811c9dc5;
  for (final unit in utf8.encode(seed)) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(36);
}
