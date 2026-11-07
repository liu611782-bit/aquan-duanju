import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_recipe.dart';
import 'package:aquan_duanju/core/cast/cast_target.dart';
import 'package:aquan_duanju/core/cast/didl.dart';
import 'package:aquan_duanju/core/cast/dlna_device.dart';
import 'package:aquan_duanju/widgets/cast_panel.dart';

MediaRequestTrace _trace({
  int status = 200,
  int bytes = 0,
  DateTime? at,
}) =>
    MediaRequestTrace(
      url: 'http://192.168.1.5:18280/p/tok/index.m3u8',
      method: 'GET',
      statusCode: status,
      bytesServed: bytes,
      at: at,
    );

void main() {
  group('会话抽屉取流指示（R1 / AC-1）', () {
    test('0 次且未播放：不显示（null，避免连接瞬间误报）', () {
      expect(castFetchIndicatorText(const []), isNull);
    });

    test('0 次且播放中：「电视尚未取流」', () {
      expect(castFetchIndicatorText(const [], playing: true), '电视尚未取流');
    });

    test('≥1 次 2xx：次数 / 累计 MB / 最近时刻', () {
      final line = castFetchIndicatorText([
        _trace(
            bytes: 700 * 1024,
            at: DateTime(2026, 11, 7, 9, 8, 7)),
        _trace(
            bytes: 1572864 - 700 * 1024,
            at: DateTime(2026, 11, 7, 10, 20, 30)),
      ]);
      expect(line, '电视已来取流（2 次 · 1.5 MB，最近 10:20:30）');
    });

    test('只统计 2xx：非 2xx 记录不计次数也不计入 MB', () {
      final line = castFetchIndicatorText(
        [
          _trace(status: 404, bytes: 0),
          _trace(status: 416, bytes: 512),
        ],
        playing: true,
      );
      expect(line, '电视尚未取流', reason: '0 次 2xx 时按未取流展示（明细在诊断弹窗）');
    });

    test('混合：2xx 与失败并存时只按 2xx 聚合', () {
      final line = castFetchIndicatorText([
        _trace(status: 206, bytes: 1024 * 1024, at: DateTime(2026, 11, 7, 8, 0, 0)),
        _trace(status: 404, bytes: 999, at: DateTime(2026, 11, 7, 9, 0, 0)),
      ]);
      expect(line, '电视已来取流（1 次 · 1.0 MB，最近 08:00:00）');
    });
  });

  group('配方命中显示（R3 / AC-3）', () {
    test('未命中：「未记忆（将自动尝试 7 步梯度）」', () {
      expect(castRecipeDisplayText(null), '未记忆（将自动尝试 7 步梯度）');
    });

    test('命中：didl/模板/延迟/URL 形态/兼容模式 全展示', () {
      expect(
        castRecipeDisplayText(const CastRecipe()),
        'DIDL 完整 · 模板 标准 · 延迟 0ms · URL 带扩展名 · 兼容 自动',
      );
      expect(
        castRecipeDisplayText(const CastRecipe(
          didl: DidlVariant.compact,
          protocolInfoTemplate: DidlProtocolInfoTemplate.bare,
          playDelayMs: 300,
          urlSuffixMode: CastUrlSuffixMode.bare,
          transcodeMode: CastTranscodeMode.always,
        )),
        'DIDL 精简 · 模板 裸 · 延迟 300ms · URL 裸形态 · 兼容 始终',
      );
      expect(
        castRecipeDisplayText(const CastRecipe(
          didl: DidlVariant.compatEscaped,
          protocolInfoTemplate: DidlProtocolInfoTemplate.sinkEntry,
          playDelayMs: 500,
          transcodeMode: CastTranscodeMode.never,
        )),
        'DIDL 兼容转义 · 模板 设备同款 · 延迟 500ms · URL 带扩展名 · 兼容 从不',
      );
    });

    test('已试变体：只抽配方尝试行，旧→新，最多 max 条', () {
      const timeline = [
        '09:00:01 connecting → 电视（192.168.1.9）',
        '09:00:02 配方未命中：didl=full → fault 401',
        '09:00:03 能力预检完成：Sink 12 条',
        '09:00:04 配方未命中：didl=compact → fault 402',
        '09:00:05 配方命中：didl=full template=bare',
      ];
      expect(castRecipeAttemptLines(timeline), [
        '09:00:02 配方未命中：didl=full → fault 401',
        '09:00:04 配方未命中：didl=compact → fault 402',
        '09:00:05 配方命中：didl=full template=bare',
      ]);
    });

    test('已试变体：无配方尝试行返回空列表（UI 不加段）', () {
      expect(castRecipeAttemptLines(['09:00:01 用户断开投屏']), isEmpty);
      expect(castRecipeAttemptLines(const []), isEmpty);
    });

    test('已试变体：超过上限时只保留最近 max 条', () {
      final timeline = <String>[
        for (var i = 1; i <= 5; i++) '09:00:0$i 配方未命中：didl=v$i',
      ];
      final lines = castRecipeAttemptLines(timeline, max: 2);
      expect(lines.length, 2);
      expect(lines.last, '09:00:05 配方未命中：didl=v5');
      expect(lines.first, '09:00:04 配方未命中：didl=v4');
    });
  });

  group('深度诊断重试开关可用性（R1.2）', () {
    test('仅 DLNA 目标可用；未选择目标 / Chromecast / AirPlay 置灰', () {
      final dlna = CastTarget.dlna(DlnaDevice(
        udn: 'uuid:t1',
        friendlyName: '电视',
        controlUrl: 'http://192.168.1.8/ctrl',
      ));
      final cc = CastTarget.chromecast(
          const CastDeviceInfo(host: '192.168.1.9', name: 'CC'));
      final ap = CastTarget.airplay(
          const AirPlayDeviceInfo(host: '192.168.1.10', name: 'ATV'));
      expect(castDeepScanAvailable(dlna), isTrue);
      expect(castDeepScanAvailable(cc), isFalse);
      expect(castDeepScanAvailable(ap), isFalse);
      expect(castDeepScanAvailable(null), isFalse);
    });
  });
}
