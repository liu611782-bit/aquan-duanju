import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/reader/manga_tap_zones.dart';

void main() {
  group('mangaTapActionFor 九宫格分区', () {
    // Legado 默认：上[上一,上一,下一] 中[上一,菜单,下一] 下[上一,下一,下一]
    test('九格中心点全部命中默认动作', () {
      // 列中心：1/6、1/2、5/6；行中心同理。
      expect(mangaTapActionFor(const Offset(1 / 6, 1 / 6)),
          MangaTapAction.prev); // 左上
      expect(mangaTapActionFor(const Offset(1 / 2, 1 / 6)),
          MangaTapAction.prev); // 上中
      expect(mangaTapActionFor(const Offset(5 / 6, 1 / 6)),
          MangaTapAction.next); // 右上
      expect(mangaTapActionFor(const Offset(1 / 6, 1 / 2)),
          MangaTapAction.prev); // 左中
      expect(mangaTapActionFor(const Offset(1 / 2, 1 / 2)),
          MangaTapAction.menu); // 正中
      expect(mangaTapActionFor(const Offset(5 / 6, 1 / 2)),
          MangaTapAction.next); // 右中
      expect(mangaTapActionFor(const Offset(1 / 6, 5 / 6)),
          MangaTapAction.prev); // 左下
      expect(mangaTapActionFor(const Offset(1 / 2, 5 / 6)),
          MangaTapAction.next); // 下中
      expect(mangaTapActionFor(const Offset(5 / 6, 5 / 6)),
          MangaTapAction.next); // 右下
    });

    test('1/3、2/3 分数边界归属确定（==1/3 入中列/中行，==2/3 入右列/下行）', () {
      expect(mangaTapActionFor(const Offset(1 / 3, 1 / 3)),
          MangaTapAction.menu); // 恰在 1/3 → 中列/中行
      expect(mangaTapActionFor(const Offset(2 / 3, 2 / 3)),
          MangaTapAction.next); // 恰在 2/3 → 右列/下行
      expect(mangaTapActionFor(const Offset(0.34, 0.5)),
          MangaTapAction.menu); // 0.34 → 中列
      expect(mangaTapActionFor(const Offset(0.67, 0.5)),
          MangaTapAction.next); // 0.67 → 右列
      expect(mangaTapActionFor(const Offset(0.32, 0.5)),
          MangaTapAction.prev); // 0.32 → 左列
    });

    test('越界坐标钳制（按下点到窗口外不崩溃）', () {
      expect(mangaTapActionFor(const Offset(-0.5, 1.5)), MangaTapAction.prev);
      expect(mangaTapActionFor(const Offset(1.5, -0.5)), MangaTapAction.next);
    });
  });

  group('MangaTapArbiter 仲裁', () {
    late List<MangaTapAction> fired;

    MangaTapArbiter newArbiter() =>
        MangaTapArbiter(onAction: fired.add, tapWait: const Duration(milliseconds: 200));

    setUp(() => fired = []);

    test('200ms 到点执行九宫格动作（按下位置判区）', () {
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapDown(const Offset(0.9, 0.9)); // 右下 = 下一页
        arbiter.onTapUp();
        expect(arbiter.waiting, isTrue);
        expect(fired, isEmpty, reason: '到点前不执行');
        async.elapse(const Duration(milliseconds: 200));
        expect(fired, [MangaTapAction.next]);
        expect(arbiter.waiting, isFalse);
      });
    });

    test('抬起位置不影响判区（按下位置判区，松手抖动忽略）', () {
      // arbiter 只收按下坐标：抬起不传位置，天然满足；这里锁定语义。
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapDown(const Offset(0.1, 0.9)); // 左下 = 上一页
        arbiter.onTapUp();
        async.elapse(const Duration(milliseconds: 250));
        expect(fired, [MangaTapAction.prev]);
      });
    });

    test('200ms 内再次按下会作废上一轮待定单击', () {
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapDown(const Offset(0.9, 0.9));
        arbiter.onTapUp();
        async.elapse(const Duration(milliseconds: 100));
        arbiter.onTapDown(const Offset(0.5, 0.5)); // 新按下：正中
        arbiter.onTapUp();
        async.elapse(const Duration(milliseconds: 200));
        expect(fired, [MangaTapAction.menu], reason: '只执行最新一轮');
      });
    });

    test('取消矩阵：cancel 后到点不执行', () {
      for (final reason in [
        MangaTapCancelReason.drag,
        MangaTapCancelReason.doubleTap,
        MangaTapCancelReason.pageTurn,
        MangaTapCancelReason.contentNotReady,
      ]) {
        fakeAsync((async) {
          fired.clear();
          final arbiter = newArbiter();
          arbiter.onTapDown(const Offset(0.9, 0.9));
          arbiter.onTapUp();
          arbiter.cancel(reason);
          async.elapse(const Duration(milliseconds: 300));
          expect(fired, isEmpty, reason: '$reason 应取消待定单击');
        });
      }
    });

    test('onTapCancel = drag 取消', () {
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapDown(const Offset(0.9, 0.9));
        arbiter.onTapUp();
        arbiter.onTapCancel();
        async.elapse(const Duration(milliseconds: 300));
        expect(fired, isEmpty);
      });
    });

    test('未按下直接 onTapUp 不产生动作；连续两次单击各自结算', () {
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapUp(); // 无按下
        async.elapse(const Duration(milliseconds: 300));
        expect(fired, isEmpty);

        arbiter.onTapDown(const Offset(0.5, 0.5));
        arbiter.onTapUp();
        async.elapse(const Duration(milliseconds: 200));
        expect(fired, [MangaTapAction.menu]);
        arbiter.onTapDown(const Offset(0.9, 0.1));
        arbiter.onTapUp();
        async.elapse(const Duration(milliseconds: 200));
        expect(fired, [MangaTapAction.menu, MangaTapAction.next]);
      });
    });

    test('dispose 后不执行', () {
      fakeAsync((async) {
        final arbiter = newArbiter();
        arbiter.onTapDown(const Offset(0.9, 0.9));
        arbiter.onTapUp();
        arbiter.dispose();
        async.elapse(const Duration(milliseconds: 300));
        expect(fired, isEmpty);
      });
    });
  });
}
