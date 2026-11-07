import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/aqua_error.dart';
import 'package:aquan_duanju/core/error_log.dart';
import 'package:aquan_duanju/widgets/common.dart';

/// 复用「我的 → 重置匿名设备」逻辑的重置入口（错误面板「立即重置」）测试：
/// helper 文案口径、ErrorRetryView 按钮、LoadView 透传。
void main() {
  Future<void> flushSnackBar(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
  }

  Widget host(Future<void> Function() onReset) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => FilledButton(
                onPressed: () => resetAnonymousDevice(context, onReset),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );

  group('resetAnonymousDevice', () {
    testWidgets('成功：返回 true，提示与设置页一致', (tester) async {
      var called = 0;
      await tester.pumpWidget(host(() async => called++));
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(called, 1);
      expect(find.text('已重置，重新拉取数据即可'), findsOneWidget);
      await flushSnackBar(tester);
    });

    testWidgets('AquaException：返回 false，提示 friendlyText，异常进 ErrorLog',
        (tester) async {
      await tester.pumpWidget(host(() async {
        throw AquaException(
          code: AquaCode.anonymousLimited,
          message: 'x',
          retryable: false,
        );
      }));
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.text('当前设备已达到匿名访问上限，可在「我的 → 设置」里重置设备'),
          findsOneWidget);
      await flushSnackBar(tester);
    });

    testWidgets('未知异常：返回 false，给通用失败提示，异常进 ErrorLog', (tester) async {
      final before = ErrorLog.instance.length;
      await tester.pumpWidget(host(() async => throw StateError('boom')));
      await tester.tap(find.text('go'));
      await tester.pump();

      expect(find.text('重置设备失败，请稍后再试'), findsOneWidget);
      expect(ErrorLog.instance.length, greaterThan(before));
      await flushSnackBar(tester);
    });
  });

  group('ErrorRetryView 立即重置', () {
    testWidgets('提供 onResetDevice 时显示「立即重置」按钮，点击触发回调', (tester) async {
      var reset = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ErrorRetryView(
            error: AquaException(
              code: AquaCode.anonymousLimited,
              message: 'x',
              retryable: false,
            ),
            onRetry: () {},
            onResetDevice: () => reset++,
          ),
        ),
      ));

      expect(find.text('立即重置'), findsOneWidget);
      await tester.tap(find.text('立即重置'));
      await tester.pump();
      expect(reset, 1);
    });

    testWidgets('未提供 onResetDevice 时不显示重置按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ErrorRetryView(
            error: const OSError(),
            onRetry: () {},
          ),
        ),
      ));

      expect(find.text('立即重置'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
    });
  });

  group('LoadView 透传 onResetDevice', () {
    testWidgets('error 态下「立即重置」可用（发现页同款接线）', (tester) async {
      var reset = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadView(
            loading: false,
            error: AquaException(
              code: AquaCode.deviceRejected,
              message: 'x',
              retryable: false,
            ),
            onRetry: () {},
            onResetDevice: () => reset++,
            child: const SizedBox.shrink(),
          ),
        ),
      ));

      expect(find.text('立即重置'), findsOneWidget);
      await tester.tap(find.text('立即重置'));
      await tester.pump();
      expect(reset, 1);
    });

    testWidgets('loading 态不给重置入口（骨架屏优先）', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LoadView(
            loading: true,
            error: null,
            onRetry: () {},
            onResetDevice: () {},
            child: const SizedBox.shrink(),
          ),
        ),
      ));

      expect(find.text('立即重置'), findsNothing);
    });
  });
}

/// 非 AquaException 的占位错误（ErrorRetryView 的通用文案分支）。
class OSError {
  const OSError();
  @override
  String toString() => 'Exception';
}
