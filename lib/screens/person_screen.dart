import 'package:flutter/material.dart';

import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';
import '../widgets/loading.dart';

/// 人物页：头像 + 头衔 + 作品流。
class PersonScreen extends StatefulWidget {
  const PersonScreen({super.key, required this.userId, this.name = ''});

  final String userId;
  final String name;

  @override
  State<PersonScreen> createState() => _PersonScreenState();
}

class _PersonScreenState extends State<PersonScreen> {
  Person? _person;
  final _works = <Work>[];
  String _cursor = '';
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final person = await api.person(widget.userId);
      final works = await api.personWorks(widget.userId);
      if (!mounted) return;
      setState(() {
        _person = person;
        _works
          ..clear()
          ..addAll(works.items);
        _cursor = works.cursor;
        _hasMore = works.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    _loadingMore = true;
    try {
      final page = await AppScope.read(context)
          .api
          .personWorks(widget.userId, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _works.addAll(page.items);
        _cursor = page.cursor;
        _hasMore = page.hasMore;
      });
    } catch (_) {
    } finally {
      _loadingMore = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_person?.name ?? widget.name)),
      body: LoadView(
        loading: _loading,
        error: _error,
        onRetry: _reload,
        empty: _works.isEmpty && _person == null,
        emptyText: '没有找到该人物',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 32,
                  // 头像与封面同为 HEIC 签名 URL，走核心转码加载。
                  backgroundImage: (_person != null && _person!.avatarUrl.isNotEmpty)
                      ? AquaImageProvider(
                          _person!.avatarUrl, AppScope.read(context).api)
                      : null,
                  onBackgroundImageError: (_, _) {},
                  child: _person?.avatarUrl.isEmpty ?? true
                      ? const Icon(Icons.person)
                      : null,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_person?.name ?? widget.name,
                          style: theme.textTheme.titleLarge
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      if (_person?.tags.isNotEmpty ?? false)
                        Text(_person!.tags.join(' · '),
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: theme.colorScheme.outline)),
                      if ((_person?.followers ?? 0) > 0) ...[
                        const SizedBox(height: 4),
                        Text(
                          '${formatCount(_person!.followers)}粉丝 · ${formatCount(_person!.likes)}获赞',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (_person?.description.isNotEmpty ?? false) ...[
              const SizedBox(height: 12),
              Text(_person!.description, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 16),
            Text('作品', style: theme.textTheme.titleMedium),
            const SizedBox(height: 10),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 130,
                mainAxisSpacing: 12,
                crossAxisSpacing: 10,
                childAspectRatio: 0.58,
              ),
              itemCount: _works.length + (_hasMore ? 1 : 0),
              itemBuilder: (context, i) {
                if (i >= _works.length) {
                  WidgetsBinding.instance
                      .addPostFrameCallback((_) => _loadMore());
                  return const Center(
                    child: AppLoading.inline(),
                  );
                }
                final w = _works[i];
                return SeriesCard(
                  item: SeriesSummary(
                    id: w.seriesId,
                    title: w.title,
                    coverUrl: w.coverUrl,
                    episodeCount: w.episodeCount,
                  ),
                  onTap: () => openDetail(context, w.seriesId, w.title),
                  subtitle: w.tags.take(2).join(' '),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
