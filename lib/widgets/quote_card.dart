/// 摘录卡：把书签摘录排成一张可导出的卡片（带水印、季节点缀）。
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 季节（按月份取，影响卡片点缀色与文案）。
enum QuoteSeason {
  spring('春', Color(0xFFE7A0B4)),
  summer('夏', Color(0xFF6FB3C8)),
  autumn('秋', Color(0xFFD29A5E)),
  winter('冬', Color(0xFF8FA3C4));

  const QuoteSeason(this.label, this.accent);

  final String label;
  final Color accent;

  static QuoteSeason of(DateTime date) => switch (date.month) {
        3 || 4 || 5 => QuoteSeason.spring,
        6 || 7 || 8 => QuoteSeason.summer,
        9 || 10 || 11 => QuoteSeason.autumn,
        _ => QuoteSeason.winter,
      };
}

/// 一张摘录卡（固定 3:4 比例，导出位图用）。
class QuoteCard extends StatelessWidget {
  const QuoteCard({
    super.key,
    required this.excerpt,
    required this.bookTitle,
    this.chapterTitle = '',
    this.createdAt,
    this.watermark = '阿圈短剧 · 阅读',
    this.season,
  });

  final String excerpt;
  final String bookTitle;
  final String chapterTitle;
  final DateTime? createdAt;
  final String watermark;
  final QuoteSeason? season;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = (season ?? QuoteSeason.of(createdAt ?? DateTime.now())).accent;
    final date = createdAt ?? DateTime.now();
    final text = excerpt.trim().isEmpty ? '（这条摘录没有正文）' : excerpt.trim();

    return AspectRatio(
      aspectRatio: 3 / 4,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              theme.colorScheme.surface,
              Color.alphaBlend(accent.withValues(alpha: 0.16),
                  theme.colorScheme.surface),
            ],
          ),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.fromLTRB(26, 24, 26, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  '${_two(date.month)} · ${_two(date.day)}',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    letterSpacing: 1.2,
                  ),
                ),
                const Spacer(),
                Text(
                  QuoteSeason.of(date).label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SingleChildScrollView(
                  physics: const NeverScrollableScrollPhysics(),
                  child: Text(
                    text,
                    style: theme.textTheme.titleMedium?.copyWith(
                      height: 1.9,
                      letterSpacing: 0.4,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              height: 1,
              color: accent.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              chapterTitle.isEmpty ? bookTitle : '《$bookTitle》 · $chapterTitle',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              watermark,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.outline,
                letterSpacing: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _two(int value) => value.toString().padLeft(2, '0');
}

/// 卡片截图导出。
class QuoteCardExporter {
  const QuoteCardExporter._();

  /// 把 [key] 包住的 RepaintBoundary 截成 PNG；失败返回 null。
  static Future<Uint8List?> capture(
    GlobalKey key, {
    double pixelRatio = 2.4,
  }) async {
    final object = key.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) return null;
    try {
      final image = await object.toImage(pixelRatio: pixelRatio);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
