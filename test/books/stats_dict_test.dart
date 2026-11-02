import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/dict/dictionary_store.dart';
import 'package:aquan_duanju/core/dict/stardict.dart';
import 'package:aquan_duanju/core/stats/reading_stats.dart';
import 'package:aquan_duanju/widgets/quote_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('阅读统计', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<ReadingStatsStore> newStore() async {
      final store = ReadingStatsStore(prefs: await SharedPreferences.getInstance());
      await store.ensureLoaded();
      return store;
    }

    test('按天累计 + 按书累计', () async {
      final store = await newStore();
      final day = DateTime(2026, 11, 2, 10);
      await store.addDuration('b1', const Duration(minutes: 5), at: day);
      await store.addDuration('b1', const Duration(minutes: 3), at: day);
      await store.addDuration('b2', const Duration(minutes: 2), at: day);

      final snapshot = store.snapshot();
      expect(snapshot.secondsOn(day), 600);
      expect(snapshot.books['b1'], 480);
      expect(snapshot.books['b2'], 120);
      expect(snapshot.totalSeconds, 600);
    });

    test('跨天分开记，热力图缺失补零', () async {
      final store = await newStore();
      final today = DateTime.now();
      await store.addDuration('b1', const Duration(minutes: 10), at: today);
      final recent = store.snapshot().recentDays(7);
      expect(recent, hasLength(7));
      expect(recent.last.seconds, 600);
      expect(recent.first.seconds, 0);
    });

    test('连续天数：今天+昨天有记录 = 2', () async {
      final store = await newStore();
      final now = DateTime.now();
      await store.addDuration('b1', const Duration(minutes: 1), at: now);
      await store.addDuration(
          'b1', const Duration(minutes: 1), at: now.subtract(const Duration(days: 1)));
      expect(store.snapshot().streakDays, 2);
    });

    test('连续天数：只有昨天也算 1（今天还没读）', () async {
      final store = await newStore();
      await store.addDuration(
          'b1', const Duration(minutes: 1), at: DateTime.now().subtract(const Duration(days: 1)));
      expect(store.snapshot().streakDays, 1);
    });

    test('重启后统计仍在；clear 清空', () async {
      final prefs = await SharedPreferences.getInstance();
      final first = ReadingStatsStore(prefs: prefs);
      await first.addDuration('b1', const Duration(minutes: 2));
      final second = ReadingStatsStore(prefs: prefs);
      await second.ensureLoaded();
      expect(second.snapshot().totalSeconds, 120);

      await second.clear();
      expect(second.snapshot().totalSeconds, 0);
    });

    test('零/负时长不入账', () async {
      final store = await newStore();
      await store.addDuration('b1', Duration.zero);
      await store.addDuration('b1', const Duration(seconds: -5));
      expect(store.snapshot().totalSeconds, 0);
    });

    test('ReadingStatsTicker 在非活跃时不计时', () async {
      final store = await newStore();
      final ticker = ReadingStatsTicker(
        store: store,
        bookId: 'b1',
        interval: const Duration(seconds: 30),
        isActive: () => false,
      );
      await ticker.tick();
      expect(store.snapshot().totalSeconds, 0);
    });
  });

  group('StarDict 词典', () {
    late Directory dir;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dir = await Directory.systemTemp.createTemp('aquan_dict');
    });

    tearDown(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    Future<String> buildDict({
      Map<String, String> entries = const {
        'apple': '苹果',
        'appetite': '食欲',
        'banana': '香蕉',
      },
      String type = 'm',
    }) async {
      final words = entries.keys.toList()..sort();
      final data = BytesBuilder();
      final idx = BytesBuilder();
      for (final word in words) {
        final definition = entries[word]!;
        final offset = data.length;
        data.add(utf8.encode(definition));
        final size = data.length - offset;
        idx.add(utf8.encode(word));
        idx.addByte(0);
        idx.add([
          (offset >> 24) & 0xFF,
          (offset >> 16) & 0xFF,
          (offset >> 8) & 0xFF,
          offset & 0xFF,
          (size >> 24) & 0xFF,
          (size >> 16) & 0xFF,
          (size >> 8) & 0xFF,
          size & 0xFF,
        ]);
      }
      await File('${dir.path}/test.ifo').writeAsString(
        "StarDict's dict ifo file\nversion=2.4.2\n"
        'wordcount=${words.length}\n'
        'idxfilesize=${idx.length}\nsametypesequence=$type\n'
        'bookname=测试词典\n',
      );
      await File('${dir.path}/test.idx').writeAsBytes(idx.toBytes());
      await File('${dir.path}/test.dict').writeAsBytes(data.toBytes());
      return dir.path;
    }

    test('精确查词（大小写不敏感）', () async {
      final dict = await StarDict.open(await buildDict());
      expect((await dict.lookup('apple'))!.definition, '苹果');
      expect((await dict.lookup('APPLE'))!.word, 'apple');
      expect(await dict.lookup('notexist'), isNull);
      expect(dict.info.name, '测试词典');
      await dict.close();
    });

    test('前缀建议按字母序', () async {
      final dict = await StarDict.open(await buildDict());
      // 词表按字母序：appetite < apple（'e' < 'l'）
      expect(await dict.suggestions('app'), ['appetite', 'apple']);
      expect(await dict.suggestions('zzz'), isEmpty);
      await dict.close();
    });

    test('sametypesequence=h：HTML 标记被剥离', () async {
      final dict = await StarDict.open(await buildDict(
        entries: {'html': '<b>粗体</b><br>换行'},
        type: 'h',
      ));
      final hit = await dict.lookup('html');
      expect(hit!.definition, contains('粗体'));
      expect(hit.definition, isNot(contains('<b>')));
      expect(hit.definition, contains('\n'));
      await dict.close();
    });

    test('缺 .idx → FormatException', () async {
      await File('${dir.path}/broken.ifo').writeAsString('bookname=x\n');
      await expectLater(
        StarDict.open(dir.path),
        throwsA(isA<FormatException>()),
      );
    });

    test('仓库：导入 → 查词 → 删除', () async {
      final dictDir = await buildDict();
      final store = DictionaryStore(
        root: Directory('${dir.path}/store'),
        prefs: await SharedPreferences.getInstance(),
      );
      await store.ensureLoaded();

      final result = await store.importIfo('$dictDir/test.ifo');
      expect(result.ok, isTrue, reason: result.error);
      expect(store.dictionaries, hasLength(1));

      final hits = await store.lookup('banana');
      expect(hits.single.definition, '香蕉');

      expect(await store.remove(store.dictionaries.first.id), isTrue);
      expect(store.dictionaries, isEmpty);
      expect(await store.lookup('banana'), isEmpty);
      await store.close();
    });

    test('仓库：非 .ifo 文件被拒绝', () async {
      final store = DictionaryStore(
        root: Directory('${dir.path}/store2'),
        prefs: await SharedPreferences.getInstance(),
      );
      final txt = File('${dir.path}/x.txt')..writeAsStringSync('hi');
      final result = await store.importIfo(txt.path);
      expect(result.ok, isFalse);
      expect(result.error, contains('.ifo'));
    });
  });

  group('摘录卡', () {
    test('季节点缀按月份切换', () {
      expect(QuoteSeason.of(DateTime(2026, 4, 1)).label, '春');
      expect(QuoteSeason.of(DateTime(2026, 7, 1)).label, '夏');
      expect(QuoteSeason.of(DateTime(2026, 10, 1)).label, '秋');
      expect(QuoteSeason.of(DateTime(2026, 1, 1)).label, '冬');
    });

    testWidgets('渲染摘录正文并可截图为 PNG', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 400,
              child: RepaintBoundary(
                key: key,
                child: QuoteCard(
                  excerpt: '夏天的空很蓝，我们把故事留在手边。',
                  bookTitle: '魔法禁书目录',
                  chapterTitle: '第一章',
                  createdAt: DateTime(2026, 11, 2),
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.textContaining('夏天的空很蓝'), findsOneWidget);
      expect(find.textContaining('魔法禁书目录'), findsOneWidget);

      // toImage 需要真实异步位图编码，必须在 runAsync 里跑。
      final png = await tester.runAsync(
        () => QuoteCardExporter.capture(key, pixelRatio: 1),
      );
      expect(png, isNotNull);
      expect(png!.length, greaterThan(100));
      // PNG magic
      expect(png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    testWidgets('空摘录给出占位而不崩', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 400,
            child: QuoteCard(excerpt: '   ', bookTitle: '书'),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.textContaining('没有正文'), findsOneWidget);
    });
  });
}


