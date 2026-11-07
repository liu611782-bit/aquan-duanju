/// 页面内的轻量自动重试策略。
///
/// 只用于「整页/整块加载失败」这种用户只能干等或手动点重试的场景：连续失败
/// 两次仍不成功才把错误交给 UI。抽成纯函数是为了让退避序列可单测，也避免每个
/// 页面各写一套魔法数字。
library;

import 'aqua_error.dart';

/// 第 1、2 次自动重试前的等待时间。列表长度即最大自动重试次数。
const List<Duration> kAutoRetryDelays = [
  Duration(milliseconds: 400),
  Duration(milliseconds: 900),
];

/// 已经用掉 [attempt] 次自动重试时，下一次重试前该等多久；null 表示不再重试。
Duration? autoRetryDelay(int attempt) {
  if (attempt < 0 || attempt >= kAutoRetryDelays.length) return null;
  return kAutoRetryDelays[attempt];
}

/// 是否还允许自动重试。
bool canAutoRetry(int attempt) => autoRetryDelay(attempt) != null;

/// 这个错误值不值得自动重试。
///
/// 只重试瞬时抖动：网络异常、内容暂时不可用。以下情况一律不重试——
/// - `ANONYMOUS_LIMITED` / `RATE_LIMITED` / `DEVICE_REJECTED`：重试只会更快
///   耗尽匿名配额，正确的恢复动作是重置设备或等一会儿；
/// - `CHALLENGE_REQUIRED` / `AUTHENTICATION_REQUIRED`：需要人机验证/登录，
///   重试无用；
/// - `PARAM_INVALID` / `INVALID_OPTIONS` / `SIGNATURE_REJECTED`：参数或版本
///   问题，重试必然同样失败；
/// - 非 [AquaException]（编程错误）也不重试，避免掩盖 bug。
bool worthAutoRetry(Object error) {
  if (error is! AquaException) return false;
  switch (error.code) {
    case AquaCode.transport:
    case AquaCode.contentUnavailable:
      return true;
    default:
      return false;
  }
}

/// 首载失败的自愈决策：瞬时错误且还有重试额度时，返回下一次自动重试前的
/// 等待时间；否则返回 null（把错误交给 UI 展示）。
///
/// 首页（发现页）首载与筛选页共用这一口径：重试期间保持骨架屏不报错，
/// 两次快速重试（400ms / 900ms）都在服务端/网络冷启动窗口内，用户感知就是
/// 「多转一下圈」，而不是「进入失败 → 手动刷新」。
Duration? selfHealDelay(Object error, int usedAttempts) =>
    worthAutoRetry(error) ? autoRetryDelay(usedAttempts) : null;

/// 是否属于「换一台匿名设备就能恢复」的错误，UI 据此决定是否给重置入口。
bool deviceRecoverable(Object error) {
  if (error is! AquaException) return false;
  switch (error.code) {
    case AquaCode.anonymousLimited:
    case AquaCode.deviceRejected:
    case AquaCode.challengeRequired:
    case AquaCode.rateLimited:
      return true;
    default:
      return false;
  }
}
