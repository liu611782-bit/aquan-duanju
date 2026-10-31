import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/reader/reader_page_metrics.dart';
import 'package:aquan_duanju/core/reader/reader_theme.dart';

void main() {
  const ctx = ReaderTipContext(
    bookName: '斗破苍穹',
    chapterTitle: '第一章 陨落的天才',
    chapterIndex: 0,
    chapterSize: 100,
    pageIndex: 2,
    pageSize: 10,
    batteryPercent: 88,
    progress: 0.25,
  );

  group('renderTipTemplate', () {
    test('标准 PascalCase 变量替换', () {
      expect(renderTipTemplate('{BookName}', ctx), '斗破苍穹');
      expect(
        renderTipTemplate('{BookName}·{ChapterTitle}', ctx),
        '斗破苍穹·第一章 陨落的天才',
      );
      expect(renderTipTemplate('{PageIndex}/{PageSize}', ctx), '3/10');
      expect(renderTipTemplate('{BatteryPercent}', ctx), '88');
      expect(renderTipTemplate('{ReadProgress}', ctx), '25.0');
    });

    test('大小写与下划线变体同样命中（页脚一堆变量原文的根因）', () {
      expect(renderTipTemplate('{bookname}', ctx), '斗破苍穹');
      expect(renderTipTemplate('{book_name}', ctx), '斗破苍穹');
      expect(renderTipTemplate('{chapter_title}', ctx), '第一章 陨落的天才');
      expect(renderTipTemplate('{page_index}', ctx), '3');
      expect(renderTipTemplate('{PAGEINDEX}', ctx), '3');
    });

    test('未知变量原样保留（排错契约）', () {
      expect(renderTipTemplate('{Foo}', ctx), '{Foo}');
      expect(renderTipTemplate('第{NoSuch}页', ctx), '第{NoSuch}页');
    });

    test('花括号外的文本原样保留', () {
      expect(renderTipTemplate('第 {PageIndex} 页', ctx), '第 3 页');
    });
  });

  group('buildTipLayout', () {
    test('custom 槽位走模板渲染', () {
      final layout = buildTipLayout(
        left: ReaderTipValue.none,
        middle: ReaderTipValue.custom,
        right: ReaderTipValue.pageIndex,
        ctx: ctx,
        customMiddle: '{BookName} {page_index}',
      );
      expect(layout.middle, '斗破苍穹 3');
      expect(layout.right, '3/10');
    });
  });
}
