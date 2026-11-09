import 'package:flutter/material.dart';

import 'tts_models.dart';

/// 音色 / 音轨展示用图标（听书页 ChoiceChip、阅读页听书面板均可复用）。
///
/// 不依赖网络头像；平台音轨若已有 [tone.icon] URL 可继续用 NetworkImage，
/// 本函数用于无头像或 TTS 合成音色列表。
IconData voiceIconFor({
  required String id,
  String displayName = '',
  String locale = '',
}) {
  final key = '$id $displayName $locale'.toLowerCase();

  // 端侧 / 引擎类型
  if (key.contains('piper') || key.contains('本地') || key.contains('offline')) {
    return Icons.phone_android;
  }
  if (key.contains('edge') || key.contains('azure') || key.contains('cloud')) {
    return Icons.cloud_outlined;
  }

  // 性别 / 常见中文音色短名
  if (key.contains('男') ||
      key.contains('yunxi') ||
      key.contains('yunjian') ||
      key.contains('yunyang') ||
      key.contains('male')) {
    return Icons.face_6_outlined;
  }
  if (key.contains('女') ||
      key.contains('xiaoxiao') ||
      key.contains('xiaoyi') ||
      key.contains('xiaoxuan') ||
      key.contains('female')) {
    return Icons.face_3_outlined;
  }

  // 风格
  if (key.contains('新闻') || key.contains('旁白') || key.contains('narrat')) {
    return Icons.campaign_outlined;
  }
  if (key.contains('童') || key.contains('child')) {
    return Icons.child_care_outlined;
  }
  if (key.contains('戏') || key.contains('角色') || key.contains('drama')) {
    return Icons.theater_comedy_outlined;
  }

  return Icons.record_voice_over_outlined;
}

IconData voiceIconForTts(TtsVoice v) => voiceIconFor(
      id: v.id,
      displayName: v.displayName,
      locale: v.locale,
    );

/// 听书页横向音色 Chip：无网络头像时用本地图标。
Widget voiceChipAvatar({
  required String id,
  required String title,
  String iconUrl = '',
  double radius = 12,
}) {
  if (iconUrl.isNotEmpty) {
    return CircleAvatar(
      radius: radius,
      backgroundImage: NetworkImage(iconUrl),
      onBackgroundImageError: (_, __) {},
    );
  }
  return CircleAvatar(
    radius: radius,
    child: Icon(
      voiceIconFor(id: id, displayName: title),
      size: radius,
    ),
  );
}
