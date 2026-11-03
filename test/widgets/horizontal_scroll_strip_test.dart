import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/widgets/common.dart';

Widget _host() => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 300,
            child: HorizontalScrollStrip(
              height: 52,
              children: [
                for (var i = 0; i < 20; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(label: Text('源$i')),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

ScrollController _controllerOf(WidgetTester tester) =>
    tester.widget<ListView>(find.byType(ListView)).controller!;

void main() {
  testWidgets('横向条常显滚动条，且组件自持 controller 已挂载', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
    expect(scrollbar.thumbVisibility, isTrue);
    // 旧实现（PrimaryScrollController）在这里是 no clients，滚轮回调空转。
    expect(_controllerOf(tester).hasClients, isTrue);
  });

  testWidgets('垂直滚轮映射为横向滚动', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pump();

    final controller = _controllerOf(tester);
    expect(controller.offset, 0);

    final center = tester.getCenter(find.byType(ListView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(center));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
    await tester.pump();

    expect(controller.offset, greaterThan(0));
  });
}
