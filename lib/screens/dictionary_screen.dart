import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/dict/dictionary_store.dart';
import '../core/dict/stardict.dart';
import '../widgets/skeleton.dart';

/// 离线词典：导入 StarDict（.ifo + .idx + .dict），查词与前后缀建议。
///
/// MDict（.mdx/.mdd）由 Go 核心解析，不在本页（诚实标注）。
class DictionaryScreen extends StatefulWidget {
  const DictionaryScreen({super.key, this.store});

  final DictionaryStore? store;

  @override
  State<DictionaryScreen> createState() => _DictionaryScreenState();
}

class _DictionaryScreenState extends State<DictionaryScreen> {
  DictionaryStore? _store;
  final _controller = TextEditingController();
  List<DictHit> _hits = const [];
  List<String> _suggestions = const [];
  bool _searching = false;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final store = widget.store ?? await DictionaryStore.openDefault();
    await store.ensureLoaded();
    if (!mounted) return;
    setState(() => _store = store);
  }

  Future<void> _import() async {
    final store = _store;
    if (store == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'StarDict 词典', extensions: ['ifo']),
        ],
      );
      if (file == null) return;
      final result = await store.importIfo(file.path);
      if (!mounted) return;
      if (!result.ok) {
        messenger.showSnackBar(SnackBar(content: Text('导入失败：${result.error}')));
        return;
      }
      setState(() {});
      messenger.showSnackBar(
        SnackBar(content: Text('已导入《${result.info!.name}》${result.info!.wordCount} 词')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('导入失败：$e')));
    }
  }

  Future<void> _search(String word) async {
    final store = _store;
    final query = word.trim();
    if (store == null || query.isEmpty) return;
    setState(() {
      _searching = true;
      _query = query;
    });
    final hits = await store.lookup(query);
    final suggestions = hits.isEmpty
        ? await store.suggestions(query)
        : const <String>[];
    if (!mounted) return;
    setState(() {
      _hits = hits;
      _suggestions = suggestions;
      _searching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final store = _store;
    return Scaffold(
      appBar: AppBar(
        title: const Text('离线词典'),
        actions: [
          IconButton(
            tooltip: '导入 StarDict 词典',
            icon: const Icon(Icons.library_add_outlined),
            onPressed: _import,
          ),
        ],
      ),
      body: store == null
          ? const SkeletonView(layout: SkeletonLayout.list)
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                TextField(
                  controller: _controller,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '输入单词或词语（回车查询）',
                    border: const OutlineInputBorder(),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _controller.clear();
                              setState(() {
                                _hits = const [];
                                _suggestions = const [];
                                _query = '';
                              });
                            },
                          ),
                  ),
                  onSubmitted: _search,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 10),
                if (store.dictionaries.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24),
                    child: Text(
                      '还没有词典。点右上角导入 StarDict 词典（选择 .ifo，'
                      '同目录的 .idx/.dict 会自动一起复制）。\n'
                      'MDict（.mdx/.mdd）暂不支持。',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final dict in store.dictionaries)
                        InputChip(
                          label: Text('${dict.name}（${dict.wordCount}）'),
                          onDeleted: () async {
                            await store.remove(dict.id);
                            if (mounted) setState(() {});
                          },
                        ),
                    ],
                  ),
                const SizedBox(height: 16),
                if (_searching) const LinearProgressIndicator(minHeight: 2),
                if (_suggestions.isNotEmpty) ...[
                  Text('你是不是想找：', style: theme.textTheme.labelMedium),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final word in _suggestions)
                        ActionChip(
                          label: Text(word),
                          onPressed: () {
                            _controller.text = word;
                            _search(word);
                          },
                        ),
                    ],
                  ),
                ],
                if (_query.isNotEmpty && !_searching && _hits.isEmpty &&
                    _suggestions.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('没有找到「$_query」',
                        style: theme.textTheme.bodyMedium),
                  ),
                for (final hit in _hits)
                  Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(hit.word,
                                    style: theme.textTheme.titleMedium),
                              ),
                              Text(hit.dictName,
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.outline)),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SelectableText(hit.definition,
                              style: theme.textTheme.bodyMedium
                                  ?.copyWith(height: 1.6)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
