import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/aqua_error.dart';
import 'package:aquan_duanju/core/auto_retry.dart';

AquaException err(String code, {bool retryable = false}) =>
    AquaException(code: code, message: code, retryable: retryable);

void main() {
  test('最多自动重试两次，退避递增', () {
    expect(autoRetryDelay(0), const Duration(milliseconds: 400));
    expect(autoRetryDelay(1), const Duration(milliseconds: 900));
    expect(autoRetryDelay(2), isNull);
  });

  test('非法重试次数不影响判定', () {
    expect(autoRetryDelay(-1), isNull);
    expect(canAutoRetry(-1), isFalse);
    expect(canAutoRetry(999), isFalse);
  });

  test('可重试判定与延迟序列一致', () {
    for (var i = 0; i < kAutoRetryDelays.length; i++) {
      expect(canAutoRetry(i), isTrue, reason: '第 $i 次应允许重试');
    }
    expect(canAutoRetry(kAutoRetryDelays.length), isFalse);
  });

  test('退避时间严格递增（避免密集重试）', () {
    for (var i = 1; i < kAutoRetryDelays.length; i++) {
      expect(kAutoRetryDelays[i], greaterThan(kAutoRetryDelays[i - 1]));
    }
  });

  group('worthAutoRetry', () {
    test('瞬时网络类错误重试', () {
      expect(worthAutoRetry(err(AquaCode.transport)), isTrue);
      expect(worthAutoRetry(err(AquaCode.contentUnavailable)), isTrue);
    });

    test('限流与设备类不重试（否则更快耗尽配额）', () {
      expect(worthAutoRetry(err(AquaCode.anonymousLimited)), isFalse);
      expect(worthAutoRetry(err(AquaCode.rateLimited)), isFalse);
      expect(worthAutoRetry(err(AquaCode.deviceRejected)), isFalse);
      expect(worthAutoRetry(err(AquaCode.challengeRequired)), isFalse);
    });

    test('参数/版本类不重试（重试必然同样失败）', () {
      expect(worthAutoRetry(err(AquaCode.paramInvalid)), isFalse);
      expect(worthAutoRetry(err(AquaCode.invalidOptions)), isFalse);
      expect(worthAutoRetry(err(AquaCode.signatureRejected)), isFalse);
      expect(worthAutoRetry(err(AquaCode.authenticationRequired)), isFalse);
    });

    test('非 AquaException 不重试（避免掩盖编程错误）', () {
      expect(worthAutoRetry(Exception('boom')), isFalse);
      expect(worthAutoRetry('boom'), isFalse);
    });
  });

  group('deviceRecoverable', () {
    test('换设备能恢复的错误', () {
      expect(deviceRecoverable(err(AquaCode.anonymousLimited)), isTrue);
      expect(deviceRecoverable(err(AquaCode.deviceRejected)), isTrue);
      expect(deviceRecoverable(err(AquaCode.challengeRequired)), isTrue);
      expect(deviceRecoverable(err(AquaCode.rateLimited)), isTrue);
    });

    test('换设备无用的错误不给重置入口', () {
      expect(deviceRecoverable(err(AquaCode.transport)), isFalse);
      expect(deviceRecoverable(err(AquaCode.paramInvalid)), isFalse);
      expect(deviceRecoverable(Exception('boom')), isFalse);
    });
  });
}
