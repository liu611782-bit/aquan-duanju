import 'dart:async';

import '../aqua_api.dart';
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
      final result = await _api.search(query);
      yield SourceHits(
        items: result.items
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
        hasMore: result.hasMore && page == 1 ? false : false,
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
