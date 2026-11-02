import 'dart:convert';
import 'dart:io';

import 'package:aquan_duanju/core/books/formats/default_registry.dart';
import 'package:aquan_duanju/core/books/library/book_library.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

late Directory _tmp;
late BookLibrary _library;

Future<void> _write(String name, List<int> bytes) async {
  await File('${_tmp.path}/$name').writeAsBytes(bytes);
}

BookLibrary _newLibrary(Directory root, SharedPreferences prefs) => BookLibrary(
      root: root,
      registry: standardBookFormatRegistry(),
      prefs: prefs,
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _tmp = await Directory.systemTemp.createTemp('aquan_lib_test');
    final prefs = await SharedPreferences.getInstance();
    _library = _newLibrary(Directory('${_tmp.path}/library'), prefs);
  });

  tearDown(() async {
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('导入即复制', () {
    test('复制进书库，删原文件仍可读', () async {
      await _write('源书.txt', utf8.encode('第一章 起点\n正文一\n第二章 继续\n正文二'));
      final result = await _library.importPath('${_tmp.path}/源书.txt');

      expect(result.ok, isTrue);
      final entry = result.entry!;
      expect(entry.title, '源书');
      expect(entry.format, 'txt');
      expect(entry.chapterCount, 2);
      expect(entry.sourcePath, contains('源书.txt'));

      // 书库内副本存在
      final copy = File('${_library.root.path}/${entry.relativePath}');
      expect(copy.existsSync(), isTrue);

      // 删除原文件后仍能打开
      await File('${_tmp.path}/源书.txt').delete();
      final doc = await _library.open(entry.id);
      expect(doc, isNotNull);
      expect(doc!.chapterAt(0).plainText, '正文一');
    });

    test('同内容二次导入去重（不同路径/不同文件名）', () async {
      final bytes = utf8.encode('第一章 甲\n内容');
      await _write('a.txt', bytes);
      await _write('b.txt', bytes);

      final first = await _library.importPath('${_tmp.path}/a.txt');
      final second = await _library.importPath('${_tmp.path}/b.txt');

      expect(first.duplicated, isFalse);
      expect(second.duplicated, isTrue);
      expect(second.entry!.id, first.entry!.id);
      expect(_library.entries, hasLength(1));
    });

    test('不支持的格式诚实报错且不留目录', () async {
      await _write('书.mobi', [1, 2, 3]);
      final result = await _library.importPath('${_tmp.path}/书.mobi');
      expect(result.ok, isFalse);
      expect(result.error, contains('暂不支持'));
      final dirs = _library.root.existsSync()
          ? _library.root.listSync().whereType<Directory>()
          : <Directory>[];
      expect(dirs, isEmpty);
    });

    test('损坏 EPUB：报错并清掉半成品目录', () async {
      await _write('坏.epub', [1, 2, 3, 4, 5]);
      final result = await _library.importPath('${_tmp.path}/坏.epub');
      expect(result.ok, isFalse);
      expect(result.error, contains('EPUB'));
      final dirs = _library.root.listSync().whereType<Directory>();
      expect(dirs, isEmpty);
    });

    test('EPUB 导入：封面落盘 + 章节索引 + 资源可读', () async {
      final archive = Archive();
      void add(String name, String text) {
        final data = utf8.encode(text);
        archive.addFile(ArchiveFile(name, data.length, data));
      }

      add('META-INF/container.xml',
          '<container><rootfiles><rootfile full-path="o.opf"/></rootfiles></container>');
      add('o.opf', '''<package><metadata><title>书名</title><creator>作者</creator></metadata>
<manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/>
<item id="cov" href="cov.jpg" media-type="image/jpeg" properties="cover-image"/></manifest>
<spine><itemref idref="c"/></spine></package>''');
      add('c.xhtml', '<html><body><h1>第一章</h1><p>正文</p></body></html>');
      // 封面字节用 png 头占位
      final cover = <int>[0x89, 0x50, 0x4E, 0x47, 1, 2];
      archive.addFile(ArchiveFile('cov.jpg', cover.length, cover));

      await _write('书.epub', ZipEncoder().encode(archive));
      final result = await _library.importPath('${_tmp.path}/书.epub');
      expect(result.ok, isTrue, reason: result.error);
      final entry = result.entry!;
      expect(entry.title, '书名');
      expect(entry.author, '作者');
      expect(entry.hasCover, isTrue);
      expect(File('${_library.root.path}/${entry.coverPath}').existsSync(), isTrue);
      expect(entry.chapterTitles.single, '第一章');
    });
  });

  group('目录扫描与删除', () {
    test('递归扫描导入，跳过隐藏目录', () async {
      final sub = Directory('${_tmp.path}/子目录')..createSync();
      await File('${sub.path}/a.txt').writeAsString('第一章 甲\n内容');
      final hidden = Directory('${_tmp.path}/.cache')..createSync();
      await File('${hidden.path}/b.txt').writeAsString('第一章 乙\n内容');
      await File('${_tmp.path}/c.md').writeAsString('# 第一章\n\n正文');

      final results = await _library.importFolder(_tmp.path);
      expect(results.where((r) => r.ok), hasLength(2));
      expect(_library.entries, hasLength(2));
    });

    test('删除条目会清掉书库目录', () async {
      await _write('d.txt', utf8.encode('第一章\n内容'));
      final entry = (await _library.importPath('${_tmp.path}/d.txt')).entry!;
      final dir = Directory('${_library.root.path}/${entry.id}');
      expect(dir.existsSync(), isTrue);

      expect(await _library.remove(entry.id), isTrue);
      expect(dir.existsSync(), isFalse);
      expect(_library.entries, isEmpty);
      expect(await _library.remove('不存在'), isFalse);
    });
  });

  group('索引持久化与自愈', () {
    test('重启后（同一 root/prefs 新实例）索引仍在', () async {
      await _write('e.txt', utf8.encode('第一章\n内容'));
      await _library.importPath('${_tmp.path}/e.txt');

      final prefs = await SharedPreferences.getInstance();
      final reopened = _newLibrary(_library.root, prefs);
      await reopened.ensureLoaded();
      expect(reopened.entries, hasLength(1));
      expect(reopened.entries.values.single.title, 'e');
    });

    test('索引被清空时从 meta.json 自愈', () async {
      await _write('f.txt', utf8.encode('第一章\n内容'));
      await _library.importPath('${_tmp.path}/f.txt');

      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final healed = _newLibrary(_library.root, prefs);
      await healed.ensureLoaded();
      expect(healed.entries, hasLength(1));
      expect(healed.entries.values.single.title, 'f');
    });

    test('旧版 localBooks（外部路径）自动迁移入库', () async {
      await _write('legacy.txt', utf8.encode('第一章 旧\n旧内容'));
      SharedPreferences.setMockInitialValues({
        'localBooks': jsonEncode([
          {
            'id': 'oldid',
            'title': '旧书',
            'path': '${_tmp.path}/legacy.txt',
            'chapterTitles': ['第一章 旧'],
            'charCounts': [3],
            'importedAt': '2026-01-01T00:00:00.000',
          },
        ]),
      });
      final prefs = await SharedPreferences.getInstance();
      final migrated = _newLibrary(Directory('${_tmp.path}/lib2'), prefs);
      await migrated.ensureLoaded();

      expect(migrated.entries, hasLength(1));
      final entry = migrated.entries.values.single;
      expect(entry.chapterCount, 1);
      // 迁移后的书能打开（读的是书库副本而不是原路径）
      await File('${_tmp.path}/legacy.txt').delete();
      final doc = await migrated.open(entry.id);
      expect(doc, isNotNull);
    });
  });
}
