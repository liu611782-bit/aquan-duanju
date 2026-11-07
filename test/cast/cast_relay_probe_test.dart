import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/aqua_error.dart';
import 'package:aquan_duanju/core/cast/cast_diagnostics.dart';
import 'package:aquan_duanju/core/cast/cast_relay_probe.dart';

void main() {
  group('CastRelayProbe（M0-5：Go 中继取流日志 → CastDiagnostics）', () {
    test('pollOnce 把 recent 转写进 mediaRequests（source=relay）', () async {
      final d = CastDiagnostics();
      d.beginSession(deviceName: '客厅电视', protocol: 'dlna');
      final probe = CastRelayProbe(diagnostics: d);
      probe.watch((session) async {
        expect(session, 'session-1');
        return <String, dynamic>{
          'session': session,
          'recent': [
            {
              'seq': 1,
              'at': '10:00:01',
              'path': '/cast/AbCdEf0123456789AbCdEf0123456789/index.m3u8',
              'status': 200,
              'bytes': 512,
            },
            {
              'seq': 2,
              'at': '10:00:02',
              'path': '/cast/AbCdEf0123456789AbCdEf0123456789/seg_00000.ts',
              'range': 'bytes=0-',
              'ua': 'DALISHI/1.0',
              'status': 206,
              'bytes': 65536,
            },
          ],
        };
      }, 'session-1');
      await probe.pollOnce();

      final relayRequests =
          d.mediaRequests.where((m) => m.source == 'relay').toList();
      expect(relayRequests.length, 2);
      expect(relayRequests[0].url, contains('/index.m3u8'));
      expect(relayRequests[0].statusCode, 200);
      expect(relayRequests[0].bytesServed, 512);
      expect(relayRequests[0].isOk, isTrue);
      expect(relayRequests[1].statusCode, 206);
      expect(relayRequests[1].range, 'bytes=0-');
      expect(relayRequests[1].userAgent, 'DALISHI/1.0');
      probe.unwatch();
      expect(probe.watching, isFalse);
    });

    test('按 seq 去重：已见过的记录不重复转写', () async {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      final probe = CastRelayProbe(diagnostics: d);
      final entries = <Map<String, dynamic>>[
        {'seq': 1, 'path': '/cast/tok/index.m3u8', 'status': 200, 'bytes': 10},
      ];
      probe.watch((session) async => {'recent': List.of(entries)},
          'session-1');
      await probe.pollOnce();
      entries.add({
        'seq': 2,
        'path': '/cast/tok/seg_00000.ts',
        'status': 200,
        'bytes': 20,
      });
      await probe.pollOnce();
      expect(d.mediaRequests.where((m) => m.source == 'relay').length, 2,
          reason: '只有新增 seq 的记录被转写');
      probe.unwatch();
    });

    test('会话不存在（castRelayStop/空闲回收）→ 探针自停', () async {
      final probe = CastRelayProbe();
      probe.watch((session) async {
        throw AquaException(
          code: AquaCode.castRelayNoSession,
          message: '会话不存在或已回收',
          retryable: false,
        );
      }, 'session-gone');
      await probe.pollOnce();
      expect(probe.watching, isFalse, reason: '会话已回收，轮询应自动停止');
      // 自停后 unwatch 无害。
      probe.unwatch();
    });

    test('没有 recent 字段（旧版核心）→ 不转写也不出错', () async {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      final probe = CastRelayProbe(diagnostics: d);
      probe.watch((session) async => <String, dynamic>{'ready': true},
          'session-1');
      await probe.pollOnce();
      expect(d.mediaRequests.where((m) => m.source == 'relay'), isEmpty);
      expect(probe.watching, isTrue, reason: '正常响应不触发自停');
      probe.unwatch();
    });

    test('R3：lanIp/port/url 转写进诊断目标字段（中继会话激活期间）', () async {
      final d = CastDiagnostics();
      d.beginSession(deviceName: 'WMP 电视', protocol: 'dlna');
      final probe = CastRelayProbe(diagnostics: d);
      probe.watch((session) async => <String, dynamic>{
            'session': session,
            'lanIp': '192.168.1.9',
            'port': 29170,
            'url': 'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts',
            'recent': <dynamic>[],
          }, 'session-1');
      await probe.pollOnce();
      expect(d.selectedIp, '192.168.1.9');
      expect(d.mediaPort, 29170);
      expect(d.mediaUrl,
          'http://192.168.1.9:29170/cast/AbCdEf0123456789AbCdEf0123456789/stream.ts');
      probe.unwatch();
    });

    test('R3：旧版核心缺 lanIp 字段 → 不误清已有目标字段', () async {
      final d = CastDiagnostics();
      d.beginSession(protocol: 'dlna');
      d.setTarget(
        selectedIp: '192.168.1.2',
        mediaPort: 18280,
        mediaUrl: 'http://192.168.1.2:18280/m/tok/index.m3u8',
      );
      final probe = CastRelayProbe(diagnostics: d);
      probe.watch((session) async => <String, dynamic>{'ready': true},
          'session-1');
      await probe.pollOnce();
      expect(d.selectedIp, '192.168.1.2', reason: '缺字段不覆盖');
      expect(d.mediaPort, 18280);
      expect(d.mediaUrl, 'http://192.168.1.2:18280/m/tok/index.m3u8');
      probe.unwatch();
    });

    test('R3：中继路径 verdict=acceptedButNotFetched 时 IP/端口可见'
        '（面板防火墙指引生效前提，AC-5）', () async {
      final d = CastDiagnostics();
      d.beginSession(deviceName: '投屏电视Q3', protocol: 'dlna');
      d.recordSoap(SoapTrace(
        action: 'SetAVTransportURI',
        requestBody: '<s:Envelope/>',
        httpStatus: 200,
      ));
      expect(d.computeVerdict(), CastVerdict.acceptedButNotFetched,
          reason: '命令已接受但电视没来取流');
      final probe = CastRelayProbe(diagnostics: d);
      probe.watch((session) async => <String, dynamic>{
            'lanIp': '192.168.1.9',
            'port': 29171,
            'url': 'http://192.168.1.9:29171/cast/AbCdEf0123456789AbCdEf0123456789/index.m3u8',
          }, 'session-1');
      await probe.pollOnce();
      expect(d.computeVerdict(), CastVerdict.acceptedButNotFetched,
          reason: '取流记录仍为空，判定不变');
      expect(d.selectedIp, '192.168.1.9');
      expect(d.mediaPort, 29171,
          reason: '中继监听端口对面板可见 → 防火墙指引带端口');
      probe.unwatch();
    });
  });
}
