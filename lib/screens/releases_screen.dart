import 'package:flutter/material.dart';

import '../core/date_strip_scroll.dart';
import '../models/models.dart';
import '../widgets/common.dart';
import 'detail_screen.dart';

/// 上新日历：newReleases(date)，服务端给出今天前后各一周的日期。
/// 已上线的作品可点进详情；预告作品显示上线时间与预约人数。
class ReleasesScreen extends StatefulWidget {
  const ReleasesScreen({super.key});

  @override
  State<ReleasesScreen> createState() => _ReleasesScreenState();
}

class _ReleasesScreenState extends State<ReleasesScreen> {
  /// 日期项固定宽度：程序化居中要能算出每个下标的滚动偏移。
  /// 左右 padding 取 (视口宽 - 项宽)/2，首尾日期也能真正落到正中。
  static const double _dateItemWidth = 92.0;

  final ScrollController _dateScroll = ScrollController();
  bool _centeredOnce = false;

  List<String> _dates = const [];
  String _selectedDate = '';
  List<NewRelease> _items = const [];
  bool _hasMore = false;
  String _cursor = '';
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _dateScroll.dispose();
    super.dispose();
  }

  double _sidePad(double viewport) =>
      dateStripSidePad(viewport, _dateItemWidth);

  /// 把当前选中日期滚到可视区域正中。
  void _centerSelectedDate({bool animate = true}) {
    if (!_dateScroll.hasClients || _dates.isEmpty) return;
    final index = _dates.indexOf(_selectedDate);
    if (index < 0) return;
    final pos = _dateScroll.position;
    final viewport = pos.viewportDimension;
    if (viewport <= 0) return;
    final target = dateStripCenterOffset(
      viewport: viewport,
      itemWidth: _dateItemWidth,
      index: index,
      maxScrollExtent: pos.maxScrollExtent,
    );
    if ((_dateScroll.offset - target).abs() < 1.0) return;
    if (animate) {
      _dateScroll.animateTo(target,
          duration: const Duration(milliseconds: 260), curve: Curves.easeOut);
    } else {
      _dateScroll.jumpTo(target);
    }
  }

  /// 首屏骨架阶段日期条可能还没挂载，等一两帧再居中。
  void _scheduleCenter({required bool animate, int retry = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_dateScroll.hasClients) {
        if (retry < 3) _scheduleCenter(animate: animate, retry: retry + 1);
        return;
      }
      _centerSelectedDate(animate: animate);
    });
  }

  /// 点选日期：立即居中（不等网络），再拉取该日数据。
  void _selectDate(String date) {
    if (date == _selectedDate) return;
    setState(() => _selectedDate = date);
    _centerSelectedDate(animate: true);
    _load(date: date);
  }

  Future<void> _load({String? date}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = AppScope.read(context).api;
      final page = await api.newReleases(date: date ?? '');
      if (!mounted) return;
      setState(() {
        if (page.dates.isNotEmpty) _dates = page.dates;
        final resolved = page.date.isNotEmpty
            ? page.date
            : (date ?? _dates.firstOrNull ?? '');
        // 服务端偶尔会给出不在 date_list 里的默认日期；兜底到列表内的值，
        // 否则 indexOf == -1，进页时无法把当前日期滚到正中。
        _selectedDate = _dates.contains(resolved)
            ? resolved
            : (_dates.firstOrNull ?? resolved);
        _items = page.items;
        _cursor = page.cursor;
        _hasMore = page.hasMore;
        _loading = false;
      });
      // 进入页面时把当前日期放到正中；之后选中的日期也回到正中。
      _scheduleCenter(animate: _centeredOnce);
      _centeredOnce = true;
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
          .newReleases(date: _selectedDate, cursor: _cursor);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
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
    return Scaffold(
      appBar: AppBar(title: const Text('上新')),
      body: Column(
        children: [
          // 日期条必须独立于 LoadView：加载骨架 / 空态 / 错误态都会整个替换
          // child，放进去会让日期条闪一下消失，且「无上新」时无法再切日期。
          if (_dates.isNotEmpty) _buildDateStrip(),
          Expanded(
            child: LoadView(
              loading: _loading,
              error: _error,
              onRetry: () => _load(),
              empty: _items.isEmpty,
              emptyText: '这一天没有上新',
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: _items.length + (_hasMore ? 1 : 0),
                separatorBuilder: (_, _) => const SizedBox(height: 10),
                itemBuilder: (context, i) {
                  if (i >= _items.length) {
                    WidgetsBinding.instance
                        .addPostFrameCallback((_) => _loadMore());
                    return const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                            width: 22,
                            height: 22,
                            child:
                                CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    );
                  }
                  return _ReleaseCard(item: _items[i]);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDateStrip() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        return SizedBox(
          height: 52,
          child: ListView.builder(
            controller: _dateScroll,
            scrollDirection: Axis.horizontal,
            padding: EdgeInsets.symmetric(
              horizontal: _sidePad(width),
              vertical: 8,
            ),
            itemExtent: _dateItemWidth,
            itemCount: _dates.length,
            itemBuilder: (_, i) {
              final d = _dates[i];
              return Center(
                child: ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(_dateLabel(d),
                      style: const TextStyle(fontSize: 12)),
                  selected: d == _selectedDate,
                  onSelected: (_) => _selectDate(d),
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// YYYYMMDD → 「10月28日」。
  String _dateLabel(String raw) {
    final d = DateTime.tryParse(
        raw.length == 8 ? '${raw.substring(0, 4)}-${raw.substring(4, 6)}-${raw.substring(6, 8)}' : raw);
    if (d == null) return raw;
    return '${d.month}月${d.day}日';
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({required this.item});

  final NewRelease item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = [
      if (item.online && item.episodeCount > 0) '已上线 · 共${item.episodeCount}集',
      if (!item.online) item.note,
      if (item.heat.isNotEmpty) item.heat,
      if (item.categories.isNotEmpty) item.categories.take(2).join(' · '),
    ].where((s) => s.isNotEmpty).join(' · ');
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: item.online && item.seriesId.isNotEmpty
            ? () => openDetail(context, item.seriesId, item.title)
            : null,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 84,
                  height: 116,
                  child: CoverImage(url: item.coverUrl),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(item.title,
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w600)),
                      ),
                      if (!item.online)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.tertiaryContainer,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text('预告',
                              style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onTertiaryContainer)),
                        ),
                    ]),
                    if (item.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(item.description,
                          maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant)),
                    ],
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(sub,
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.outline)),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
