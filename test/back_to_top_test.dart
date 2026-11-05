import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/back_to_top.dart';

Widget harness(ScrollController controller) => MaterialApp(
      home: Scaffold(
        floatingActionButton: BackToTopFab(controller: controller),
        body: ListView(
          controller: controller,
          children: [
            for (var i = 0; i < 60; i++)
              SizedBox(height: 100, child: Text('row $i')),
          ],
        ),
      ),
    );

void main() {
  testWidgets('未超过阈值时不显示', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller));

    expect(find.byType(FloatingActionButton), findsNothing);

    controller.jumpTo(kBackToTopOffset - 50);
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('超过阈值后显示，点击回顶并消失', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(harness(controller));

    controller.jumpTo(kBackToTopOffset + 400);
    await tester.pump();
    expect(find.byType(FloatingActionButton), findsOneWidget);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);
    expect(find.byType(FloatingActionButton), findsNothing);
  });

  testWidgets('控制器未挂载时不显示', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    // 用一个不把它挂到滚动视图上的页面：模拟加载态把列表换掉的情形。
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        floatingActionButton: BackToTopFab(controller: controller),
        body: const SizedBox.shrink(),
      ),
    ));
    await tester.pump();

    expect(controller.hasClients, isFalse);
    expect(find.byType(FloatingActionButton), findsNothing);
  });
}
