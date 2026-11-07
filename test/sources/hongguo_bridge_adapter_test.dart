import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/aqua_api.dart';
import 'package:aquan_duanju/core/aqua_client.dart';
import 'package:aquan_duanju/core/sources/hongguo_bridge_adapter.dart';
import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/models/models.dart';

/// 不走 FFI 的桩客户端（参照 test/tts/speech_fakes.dart 的 StubClient）。
class _StubClient implements AquaClient {
  @override
  Future<dynamic> call(String method, [List<Object?> args = const []]) async =>
      throw UnsupportedError('测试不该走 FFI：$method');
}

/// 脚本化门面：只覆盖 search，按词返回预设页；未命中脚本返回空页。
class _ScriptedApi extends AquaApi {
  _ScriptedApi() : super(_StubClient());

  final calls = <String>[];
  final script = <String, AquaPage<SeriesSummary>>{};

  @override
  Future<AquaPage<SeriesSummary>> search(
    String query, {
    String cursor = '',
    String tab = '',
    List<String> filters = const [],
    int pageSize = 0,
  }) async {
    calls.add(query);
    return script[query] ??
        const AquaPage<SeriesSummary>(items: [], cursor: '', hasMore: false);
  }
}

void main() {
  test('全名空结果 → 去尾退化重试命中，notice 标注实际检索词', () async {
    final api = _ScriptedApi();
    api.script['万妖图录'] = AquaPage<SeriesSummary>(items: [
      const SeriesSummary(
          id: '7019842578', title: '万妖图录', episodeCount: 80,
          heat: 48000000, playCount: 6970000,
          tags: ['古装', '3D', '历史玄幻']),
    ]);
    final adapter = HongguoBridgeAdapter(api);

    final events = await adapter.search('万妖图录传').toList();
    expect(api.calls, ['万妖图录传', '万妖图录'], reason: '命中即止，不再退化');

    final hits = events.whereType<SourceHits>().single;
    expect(hits.items, hasLength(1));
    final s = hits.items.single;
    expect(s.sourceKey, '', reason: '红果 sourceKey 为空串');
    expect(s.sourceItemId, '7019842578');
    expect(s.title, '万妖图录');
    expect(s.normalizedTitle, '万妖图录');
    expect(s.remarks, '共80集');
    expect(hits.notice, '已按「万妖图录」检索');
    expect(hits.hasMore, isFalse, reason: '红果只参与第 1 页聚合');
    expect(events.whereType<SourceSearchDone>(), hasLength(1));
  });

  test('原词直接命中：一次调用，无 notice', () async {
    final api = _ScriptedApi();
    api.script['万妖图录'] = AquaPage<SeriesSummary>(items: [
      const SeriesSummary(id: '701', title: '万妖图录'),
    ]);
    final adapter = HongguoBridgeAdapter(api);

    final events = await adapter.search('万妖图录').toList();
    final hits = events.whereType<SourceHits>().single;
    expect(api.calls, ['万妖图录']);
    expect(hits.notice, '');
    expect(hits.items.single.sourceItemId, '701');
  });

  test('全链为空：空命中批次 + 无 notice，不发失败事件', () async {
    final api = _ScriptedApi();
    final adapter = HongguoBridgeAdapter(api);

    final events = await adapter.search('不存在的剧名某某').toList();
    expect(api.calls, ['不存在的剧名某某', '不存在的剧名某', '不存在的剧']);
    final hits = events.whereType<SourceHits>().single;
    expect(hits.items, isEmpty);
    expect(hits.notice, '');
    expect(events.whereType<SourceSearchFailed>(), isEmpty);
  });

  test('结果按 seriesId 去重（退化层与原词结果重叠时只留先到）', () async {
    final api = _ScriptedApi();
    api.script['万妖图录'] = AquaPage<SeriesSummary>(items: [
      const SeriesSummary(id: '701', title: '万妖图录'),
      const SeriesSummary(id: '701', title: '万妖图录'),
      const SeriesSummary(id: '702', title: '万妖图志'),
    ]);
    final adapter = HongguoBridgeAdapter(api);

    final events = await adapter.search('万妖图录').toList();
    final hits = events.whereType<SourceHits>().single;
    expect(hits.items.map((s) => s.sourceItemId).toList(), ['701', '702']);
  });

  test('API 抛异常 → SourceSearchFailed（network），UI 只见友好文案', () async {
    final adapter = HongguoBridgeAdapter(_FailingApi());

    final events = await adapter.search('万妖图录传').toList();
    expect(events.whereType<SourceSearchFailed>().single.code,
        SourceExceptionCode.network);
    expect(events.whereType<SourceHits>(), isEmpty);
  });
}

class _FailingApi extends AquaApi {
  _FailingApi() : super(_StubClient());

  @override
  Future<AquaPage<SeriesSummary>> search(String query,
      {String cursor = '',
      String tab = '',
      List<String> filters = const [],
      int pageSize = 0}) async {
    throw StateError('模拟核心调用失败');
  }
}
