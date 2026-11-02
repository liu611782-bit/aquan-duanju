import 'dart:async';
import 'dart:typed_data';

import 'package:aquan_duanju/core/tts/tts_unit_producer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('单元切分', () {
    test('短段合并到 ≥120 字', () {
      final units = mergeIntoTtsUnits([
        '第一段' * 20, // 60 字
        '第二段' * 20, // 60 字 → 与上段合成一个单元
        '第三段' * 40, // 120 字 → 自己一个单元
      ]);
      expect(units, hasLength(2));
      expect(units.first.text.contains('第一段'), isTrue);
      expect(units.first.text.contains('第二段'), isTrue);
      expect(units.last.index, 1);
    });

    test('超长段落按 600 字硬切', () {
      final units = mergeIntoTtsUnits(['字' * 1500], maxChars: 600);
      expect(units, hasLength(3));
      expect(units.map((u) => u.text.length).reduce((a, b) => a + b), 1500);
      expect(units.map((u) => u.index), [0, 1, 2]);
    });

    test('空段落与纯空白被丢弃', () {
      final units = mergeIntoTtsUnits(['', '   ', '内容' * 70]);
      expect(units, hasLength(1));
      expect(units.single.index, 0);
    });
  });

  group('流式产出', () {
    test('按序产出，首单元先返回即可用', () async {
      final order = <int>[];
      final units = mergeIntoTtsUnits(
        List.generate(4, (i) => '段落$i' * 40),
      );
      final stream = produceUnits(
        units: units,
        synthesize: (text, {timeout}) async {
          // 首单元最快，模拟「第一段先合成完」
          final delay = text.contains('段落0') ? 10 : 40;
          await Future<void>.delayed(Duration(milliseconds: delay));
          order.add(text.contains('段落0') ? 0 : 1);
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      final products = await stream.toList();
      expect(products, hasLength(units.length));
      expect(products.map((p) => p.index), List.generate(units.length, (i) => i));
      expect(order.first, 0, reason: '首单元应最先完成');
    });

    test('取消后不再产出（epoch 过期）', () async {
      var cancelled = false;
      final units = mergeIntoTtsUnits(List.generate(5, (i) => '段落$i' * 40));
      final products = <UnitProduct>[];
      await for (final p in produceUnits(
        units: units,
        isCancelled: () => cancelled,
        synthesize: (text, {timeout}) async {
          cancelled = true; // 第一次合成完就模拟切章
          await Future<void>.delayed(const Duration(milliseconds: 5));
          return Uint8List.fromList([1]);
        },
      )) {
        products.add(p);
      }
      expect(products.length, lessThan(units.length));
    });

    test('空单元列表不产出', () async {
      final products = await produceUnits(
        units: const [],
        synthesize: (text, {timeout}) async => Uint8List(0),
      ).toList();
      expect(products, isEmpty);
    });

    test('并发不超过 2（在线语音限速保护）', () async {
      var inFlight = 0;
      var peak = 0;
      final units = mergeIntoTtsUnits(List.generate(6, (i) => '段落$i' * 40));
      await produceUnits(
        units: units,
        synthesize: (text, {timeout}) async {
          inFlight++;
          peak = inFlight > peak ? inFlight : peak;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          inFlight--;
          return Uint8List.fromList([1]);
        },
      ).toList();
      expect(peak, lessThanOrEqualTo(2));
    });
  });
}
