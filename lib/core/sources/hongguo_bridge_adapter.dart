import 'dart:async';

import '../aqua_api.dart';
import '../error_log.dart';
import '../search/search_fallback.dart';
import 'normal_title.dart';
import 'source_adapter.dart';

/// 红果内容的桥接适配器：把 `AquaApi.search` 包成 [SourceAdapter]，
/// 让聚合搜索编排器把红果与 CMS 源统一消费。
///
/// 红果的浏览/详情走自有链路（DiscoverScreen/DetailScreen），这里只暴露
/// 搜索与能力声明；[UnifiedSeries.sourceKey] 为空串即红果（历史兼容）。
class HongguoBridgeAdapter implements SourceAdapter {
  HongguoBridgeAdapter(this._api);

  final AquaApi _api;

  @override
  String get id => '';

  @override
  String get name => '红果';

  @override
  SourceCaps get caps => const SourceCaps(
        searchable: true,
        filterable: false,
        multiLine: false,
      );

  @override
  Future<List<SourceCategory>> categories() async => const [];

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    throw UnsupportedError('红果浏览走自有链路');
  }

  @override
  Stream<SourceSearchEvent> search(
    String query, {
    int page = 1,
    CancelToken? cancel,
  }) async* {
    try {
      // 红果是游标分页 + SDK 设备风控：单并发、只取第一页参与聚合。
      // 服务端对完整剧名可能检索不到（实测「万妖图录传」空、「万妖图录」命中），
      // 结果为空时客户端按 [searchWithDegradedRetry] 去尾退化重试并合并去重；
      // 命中词与原词不同时随 [SourceHits.notice] 带给 UI「已按 X 检索」。
      final outcome = await searchWithDegradedRetry(
        _api.search,
        query,
        isCancelled: () => cancel?.isCancelled ?? false,
        onError: (e, st) => ErrorLog.instance
            .record('聚合搜索·红果', '退化重试失败（原词 $query）：$e', st),
      );
      yield SourceHits(
        items: outcome.page.items
            .map((s) => UnifiedSeries(
                  sourceKey: '',
                  sourceItemId: s.id,
                  title: s.title,
                  normalizedTitle: normalizeTitle(s.title),
                  coverUrl: s.coverUrl,
                  remarks: s.episodeCount > 0 ? '共${s.episodeCount}集' : '',
                  description: s.description,
                ))
            .toList(),
        page: 1,
        // 红果只参与第 1 页聚合，不再续页。
        hasMore: false,
        notice: outcome.degraded ? '已按「${outcome.query}」检索' : '',
      );
      yield const SourceSearchDone();
    } catch (e) {
      yield SourceSearchFailed(SourceExceptionCode.network, e.toString());
    }
  }

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async {
    throw UnsupportedError('红果详情走自有链路');
  }

  @override
  Future<String> probePlayable({String? itemId}) async => '';
}
