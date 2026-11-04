import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/sources/source_adapter.dart';
import 'package:aquan_duanju/core/sources/source_checker.dart';

/// 全链路健康 / 列表空 / 分类空 三种伪适配器。
class _OkAdapter implements SourceAdapter {
  @override
  String get id => 'ok';
  @override
  String get name => '健康源';
  @override
  SourceCaps get caps => const SourceCaps();

  @override
  Future<List<SourceCategory>> categories() async =>
      const [SourceCategory(id: '1', name: '电影')];

  @override
  Future<SourcePage<UnifiedSeries>> list(
      {String? categoryId, required int page}) async {
    return SourcePage(items: [_series()], page: 1);
  }

  UnifiedSeries _series() => UnifiedSeries(
        sourceKey: 'ok',
        sourceItemId: '1',
        title: '剧',
        normalizedTitle: '剧',
        lines: [
          const PlayLine(name: 'm', episodes: [
            UnifiedEpisode(title: '第1集', url: 'http://v/1.m3u8', index: 1),
          ]),
        ],
      );

  @override
  Stream<SourceSearchEvent> search(String query, {int page = 1, CancelToken? cancel}) async* {}

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async => _series();

  @override
  Future<String> probePlayable({String? itemId}) async => 'http://v/1.m3u8';
}

class _EmptyAdapter implements SourceAdapter {
  @override
  String get id => 'empty';
  @override
  String get name => '空源';
  @override
  SourceCaps get caps => const SourceCaps();

  @override
  Future<List<SourceCategory>> categories() async => const [];

  @override
  Future<SourcePage<UnifiedSeries>> list(
          {String? categoryId, required int page}) async =>
      const SourcePage(items: [], page: 1);

  @override
  Stream<SourceSearchEvent> search(String query, {int page = 1, CancelToken? cancel}) async* {}

  @override
  Future<UnifiedSeries> detail(String sourceItemId) async =>
      throw UnimplementedError();

  @override
  Future<String> probePlayable({String? itemId}) async => '';
}

void main() {
  test('健康源：ok，输出分类数与可播地址', () async {
    final result = await checkSource(_OkAdapter());
    expect(result.verdict, SourceCheckVerdict.ok);
    expect(result.categoryCount, 1);
    expect(result.listOk, isTrue);
    expect(result.detailOk, isTrue);
    expect(result.playableUrl, 'http://v/1.m3u8');
    expect(result.friendlyText, contains('可用'));
  });

  test('空源：failed（假成功识别）', () async {
    final result = await checkSource(_EmptyAdapter());
    expect(result.verdict, SourceCheckVerdict.failed);
    expect(result.friendlyText, contains('失败'));
  });
}
