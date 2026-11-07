import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/models/models.dart';
import 'package:aquan_duanju/widgets/common.dart';

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 180, height: 300, child: child),
        ),
      ),
    );

void main() {
  testWidgets('封面卡片渲染热度/播放徽标与标签 chips（至多 3 个）', (tester) async {
    await tester.pumpWidget(_wrap(SeriesCard(
      item: const SeriesSummary(
        id: '701',
        title: '万妖图录',
        heat: 48000000,
        playCount: 6970000,
        tags: ['古装', '3D', '历史玄幻', '热血'],
      ),
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    // 数字格式化复用 formatCount：「4800万」「697万」。
    expect(find.text('4800万'), findsOneWidget);
    expect(find.text('697万'), findsOneWidget);
    expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    // 标签至多 3 个，第 4 个不渲染。
    expect(find.text('古装'), findsOneWidget);
    expect(find.text('3D'), findsOneWidget);
    expect(find.text('历史玄幻'), findsOneWidget);
    expect(find.text('热血'), findsNothing);
  });

  testWidgets('无热度/标签数据时不渲染徽标与遮罩（旧行为不变）', (tester) async {
    await tester.pumpWidget(_wrap(SeriesCard(
      item: const SeriesSummary(id: '702', title: '无数据剧'),
      onTap: () {},
    )));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.local_fire_department), findsNothing);
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    // 封面上没有任何渐变遮罩。
    expect(
      find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).gradient != null),
      findsNothing,
    );
  });

  testWidgets('SeriesSummary.fromJson 解析 heat/play_count/tags（vendor 补丁 P6）',
      (tester) async {
    final s = SeriesSummary.fromJson(const {
      'id': '701',
      'title': '万妖图录',
      'heat': 48000000,
      'play_count': 6970000,
      'tags': ['古装', '3D', '历史玄幻'],
    });
    expect(s.heat, 48000000);
    expect(s.playCount, 6970000);
    expect(s.tags, ['古装', '3D', '历史玄幻']);

    // 缺字段兜底：0 / 空。
    final bare = SeriesSummary.fromJson(const {'id': '702'});
    expect(bare.heat, 0);
    expect(bare.playCount, 0);
    expect(bare.tags, isEmpty);
  });

  test('formatCount：热度/播放量的中文单位', () {
    expect(formatCount(48000000), '4800万');
    expect(formatCount(6970000), '697万');
    expect(formatCount(125000000), '1.3亿');
    expect(formatCount(9999), '9999');
  });
}
