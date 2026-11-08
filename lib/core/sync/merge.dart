/// 备份包记录级合并的纯函数（无 IO、无依赖，仅 dart:convert）。
///
/// 从 book_sync 抽出（11-08-book-sync-race）：`lib/store/stores.dart` 的
/// `mergeRemoteJson` 与 `BookSyncService.mergeBundle` 双方共用。合并算法
/// 与拆出前逐字节一致（新者胜 / id 去重）。
library;

import 'dart:convert';

/// 合并结果（内部）。
class MergedJson {
  const MergedJson({
    required this.json,
    required this.changed,
    required this.changedCount,
  });

  final String json;
  final bool changed;
  final int changedCount;
}

/// 进度合并：同书取 `updated_at` 较新；新书补入。
MergedJson mergeProgressJson(String localJson, String remoteJson) {
  final local = _decodeMap(localJson);
  final remote = _decodeMap(remoteJson);
  var changed = 0;

  for (final entry in remote.entries) {
    final incoming = entry.value;
    final existing = local[entry.key];
    if (existing == null) {
      local[entry.key] = incoming;
      changed++;
      continue;
    }
    final incomingAt = _timeOf(incoming);
    final existingAt = _timeOf(existing);
    if (incomingAt.isAfter(existingAt)) {
      local[entry.key] = incoming;
      changed++;
    }
  }
  return MergedJson(
    json: jsonEncode(local),
    changed: changed > 0,
    changedCount: changed,
  );
}

/// 列表合并（书签/划线）：按 `id` 取并集，同 id 取较新 `created_at`。
MergedJson mergeListJson(String localJson, String remoteJson) {
  final local = _decodeMap(localJson);
  final remote = _decodeMap(remoteJson);
  var changed = 0;

  for (final entry in remote.entries) {
    final bookId = entry.key;
    final incoming = _asList(entry.value);
    final existing = _asList(local[bookId]);
    final byId = <String, Map<String, dynamic>>{
      for (final item in existing) _idOf(item): item,
    };
    var bookChanged = false;
    for (final item in incoming) {
      final id = _idOf(item);
      if (id.isEmpty) continue;
      final current = byId[id];
      if (current == null) {
        byId[id] = item;
        bookChanged = true;
        changed++;
        continue;
      }
      if (_timeOf(item).isAfter(_timeOf(current))) {
        byId[id] = item;
        bookChanged = true;
        changed++;
      }
    }
    if (bookChanged) {
      local[bookId] = byId.values.toList()
        ..sort((a, b) => _timeOf(a).compareTo(_timeOf(b)));
    }
  }
  return MergedJson(
    json: jsonEncode(local),
    changed: changed > 0,
    changedCount: changed,
  );
}

Map<String, dynamic> _decodeMap(String text) {
  if (text.trim().isEmpty) return <String, dynamic>{};
  try {
    final json = jsonDecode(text);
    if (json is Map<String, dynamic>) return json;
  } catch (_) {
    // 坏 JSON 当作空表（不阻断合并）。
  }
  return <String, dynamic>{};
}

List<Map<String, dynamic>> _asList(Object? value) {
  if (value is! List) return const [];
  return [
    for (final item in value)
      if (item is Map<String, dynamic>) item,
  ];
}

String _idOf(Map<String, dynamic> item) => item['id']?.toString() ?? '';

DateTime _timeOf(Map<String, dynamic> item) {
  for (final key in ['updated_at', 'created_at', 'saved_at']) {
    final raw = item[key];
    if (raw is String) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
  }
  return DateTime.fromMillisecondsSinceEpoch(0);
}
