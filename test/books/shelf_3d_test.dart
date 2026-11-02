import 'package:aquan_duanju/core/shelf/shelf_geometry.dart';
import 'package:aquan_duanju/widgets/shelf_3d.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('书架几何', () {
    test('正中：正立、无缩放、不透明', () {
      final pose = poseFor(offset: 0, halfViewport: 400);
      expect(pose.tiltY, 0);
      expect(pose.lift, 0);
      expect(pose.scale, 1);
      expect(pose.opacity, 1);
      expect(pose.z, 0);
    });

    test('右侧：向右倾斜、下沉、缩小、变暗；左侧镜像', () {
      final right = poseFor(offset: 200, halfViewport: 400);
      final left = poseFor(offset: -200, halfViewport: 400);
      expect(right.tiltY, lessThan(0));
      expect(left.tiltY, greaterThan(0));
      expect(right.scale, lessThan(1));
      expect(right.opacity, lessThan(1));
      expect(right.lift, greaterThan(0));
      expect(right.z, closeTo(left.z, 1e-9));
    });

    test('超出视口按 1 截断（不越界）', () {
      final far = poseFor(offset: 100000, halfViewport: 400);
      final edge = poseFor(offset: 400, halfViewport: 400);
      expect(far.z, 1);
      expect(far.z, edge.z);
    });

    test('半视口为 0 时返回单位位姿（不除零）', () {
      final pose = poseFor(offset: 12, halfViewport: 0);
      expect(pose.scale, 1);
      expect(pose.tiltY, 0);
    });

    test('吸附取最近档位', () {
      expect(snapTarget(0, 120), 0);
      expect(snapTarget(59, 120), 0);
      expect(snapTarget(61, 120), 120);
      expect(snapTarget(-61, 120), -120);
      expect(snapTarget(5, 0), 5);
    });

    test('波浪位移周期内起伏，且不超出振幅', () {
      final values = [for (var i = 0; i < 6; i++) waveLift(i)];
      expect(values.any((v) => v > 0), isTrue);
      expect(values.any((v) => v < 0), isTrue);
      expect(values.every((v) => v.abs() <= 2.4 + 1e-9), isTrue);
    });

    test('透视位姿随纵深变矮（书脊）', () {
      expect(spineHeight(160, 0), 160);
      expect(spineHeight(160, 1), lessThan(160));
    });
  });

  group('3D 书架视图', () {
    testWidgets('三本书能渲染，点中间那本触发 onOpen', (tester) async {
      ShelfBook? opened;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 800,
            height: 400,
            child: Shelf3DView(
              books: const [
                ShelfBook(id: 'a', title: '第一本'),
                ShelfBook(id: 'b', title: '第二本'),
                ShelfBook(id: 'c', title: '第三本'),
              ],
              onOpen: (book) => opened = book,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.byType(Shelf3DView), findsOneWidget);
      expect(find.text('第一本'), findsOneWidget);

      await tester.tap(find.text('第一本'));
      await tester.pumpAndSettle();
      expect(opened?.id, 'a');
    });

    testWidgets('空书架不渲染（不崩）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Shelf3DView(books: [], onOpen: _noop),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(ListView), findsNothing);
    });
  });
}

void _noop(ShelfBook book) {}
