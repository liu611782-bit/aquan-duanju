import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/widgets/cast_panel.dart';

CastTarget _target(String id, {bool online = true}) => CastTarget.dlna(
      DlnaDevice(
        udn: id,
        friendlyName: '设备-$id',
        modelName: 'Model-$id',
        manufacturer: 'Maker',
        controlUrl: 'http://192.168.1.9/ctl',
        location: 'http://192.168.1.9/desc.xml',
        online: online,
      ),
    );

List<String> _ids(Iterable<CastTarget> devices) =>
    devices.map((d) => d.id).toList();

void main() {
  group('设备列表顺序（R5）', () {
    test('未连接时按既有排序：最近使用置顶', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      final ordered = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
        lastId: 'b',
      );
      expect(_ids(ordered), ['b', 'a', 'c']);
    });

    test('点击不重排：连接开始冻结快照，touchLast 变化不触发重新排序', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      // 面板当前顺序（连接开始时）作为快照。
      final frozen = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
        lastId: null,
      );
      expect(_ids(frozen), ['a', 'b', 'c']);

      // 连接期间固定 lastId + frozen：即便 CastStore 的 lastId 被改成 c
      // （模拟 touchLast 生效），顺序仍是快照。
      final duringConnect = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
        lastId: null, // 固定为连接开始时的值
        frozen: frozen,
      );
      expect(_ids(duringConnect), _ids(frozen));

      // 对照组：没有冻结时 lastId=c 会把 c 顶到最前，证明冻结确实生效。
      final withoutFreeze = orderedDevices(
        live: [a, b, c],
        pinnedIds: const <String>{},
        lastId: 'c',
      );
      expect(_ids(withoutFreeze).first, 'c');
    });

    test('连接中扫描刷新：顺序不变，只同步在线状态', () {
      final a = _target('a');
      final b = _target('b');
      final c = _target('c');
      final frozen = <CastTarget>[b, a, c];
      // 扫描刷新：设备顺序全变、b 变为离线、还多出一个新设备 d。
      final live = <CastTarget>[
        _target('c'),
        _target('a'),
        _target('b', online: false),
        _target('d'),
      ];
      final result = orderedDevices(
        live: live,
        pinnedIds: const <String>{},
        lastId: 'a', // 连接期间即便传入新 lastId 也不参与重排
        frozen: frozen,
      );
      expect(_ids(result), ['b', 'a', 'c'],
          reason: '顺序严格按快照，不重排、不插入新设备');
      expect(result.first.online, isFalse,
          reason: '在线状态来自最新扫描结果');
    });
  });

  group('最近使用写入时机（R5）', () {
    test('castTo 成功才写最近使用', () async {
      var casted = false;
      var remembered = false;
      await castAndRemember(
        cast: () async {
          casted = true;
        },
        remember: () async {
          remembered = true;
        },
      );
      expect(casted, isTrue);
      expect(remembered, isTrue);
    });

    test('castTo 失败不写最近使用', () async {
      var remembered = false;
      await expectLater(
        castAndRemember(
          cast: () async {
            throw StateError('SOAP 500');
          },
          remember: () async {
            remembered = true;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(remembered, isFalse, reason: '失败设备不能被顶到列表前面');
    });
  });

  group('状态徽标映射（transportState → 中文固定文案）', () {
    test('五态映射 + RUNNING/BUFFERING 别名', () {
      expect(castTransportStateLabel('PLAYING'), '播放中');
      expect(castTransportStateLabel('RUNNING'), '播放中',
          reason: '部分设备回 RUNNING（CastPoll.isRunning 同口径）');
      expect(castTransportStateLabel('PAUSED_PLAYBACK'), '已暂停');
      expect(castTransportStateLabel('TRANSITIONING'), '缓冲中');
      expect(castTransportStateLabel('BUFFERING'), '缓冲中',
          reason: 'Chromecast poll 映射出的 BUFFERING 同显示');
      expect(castTransportStateLabel('STOPPED'), '已停止');
      expect(castTransportStateLabel('NO_MEDIA_PRESENT'), '已停止');
      expect(castTransportStateLabel('playing'), '播放中', reason: '大小写不敏感');
      expect(castTransportStateLabel(' paused_playback '), '已暂停');
    });

    test('未知/空串（尚未轮询到）返回 null：UI 不显示徽标', () {
      expect(castTransportStateLabel(''), isNull);
      expect(castTransportStateLabel('   '), isNull);
      expect(castTransportStateLabel('WHATEVER'), isNull);
    });
  });

  group('TRANSITIONING 抖动消抖（800ms）', () {
    test('窗口内维持上一状态，抖回立即恢复，满窗口后放行', () {
      fakeAsync((async) {
        final d = CastTransitionDebouncer();
        var elapsed = 0;
        d.onElapsed = () => elapsed++;

        expect(d.shouldHold('PLAYING'), isFalse);
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '进入抖动即消抖');
        async.elapse(const Duration(milliseconds: 700));
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '窗口内维持上一状态');
        expect(d.shouldHold('PAUSED_PLAYBACK'), isFalse,
            reason: '抖回其他状态立即放行并复位计时');
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '再次进入重新计时');
        async.elapse(const Duration(milliseconds: 799));
        expect(d.shouldHold('TRANSITIONING'), isTrue, reason: '距重新进入仅 799ms');
        async.elapse(const Duration(milliseconds: 10));
        expect(d.shouldHold('TRANSITIONING'), isFalse, reason: '满 800ms 显示「缓冲中」');
        expect(elapsed, 1, reason: '被打断的窗口不触发回调');
        expect(d.shouldHold('TRANSITIONING'), isFalse,
            reason: '持续 TRANSITIONING 不反复消抖');
        d.dispose();
      });
    });
  });
}
