import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/aqua_error.dart';

void main() {
  group('AquaException', () {
    test('解析信封错误', () {
      final e = AquaException.fromJson(const {
        'code': 'RATE_LIMITED',
        'message': 'too fast',
        'retryable': true,
        'retryAfterMs': 1200,
      });
      expect(e.code, AquaCode.rateLimited);
      expect(e.retryable, isTrue);
      expect(e.retryAfterMs, 1200);
      expect(e.friendlyText, contains('频繁'));
    });

    test('每个已知错误码都有中文文案', () {
      const codes = [
        AquaCode.cancelled,
        AquaCode.invalidOptions,
        AquaCode.profileNotFound,
        AquaCode.signerUnavailable,
        AquaCode.authenticationRequired,
        AquaCode.notProtected,
        AquaCode.drmProtected,
        AquaCode.anonymousLimited,
        AquaCode.rateLimited,
        AquaCode.transport,
        AquaCode.signatureRejected,
        AquaCode.contentUnavailable,
        AquaCode.paramInvalid,
        AquaCode.challengeRequired,
        AquaCode.deviceRejected,
        AquaCode.endOfList,
        AquaCode.albumUnavailable,
        AquaCode.unknown,
      ];
      for (final c in codes) {
        final e = AquaException(code: c, message: 'x', retryable: false);
        expect(e.friendlyText, isNotEmpty, reason: '$c 缺少文案');
      }
    });

    test('未知 code 回落默认文案并带上 code（便于定位）', () {
      final e = AquaException.fromJson(const {'code': 'WHATEVER'});
      expect(e.friendlyText, '出了点小问题（WHATEVER），请稍后再试');
      expect(e.friendlyText, contains('WHATEVER'));
    });
  });
}
