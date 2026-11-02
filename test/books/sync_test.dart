import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquan_duanju/core/sync/book_sync.dart';
import 'package:aquan_duanju/core/sync/remote_store.dart';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存远端（测试替身）。
class _MemoryStore implements RemoteStore {
  final Map<String, Uint8List> objects = {};

  @override
  String get label => 'Memory';

  @override
  Future<Uint8List?> get(String path) async => objects[path];

  @override
  Future<List<RemoteObject>> list(String prefix) async => [
        for (final e in objects.entries)
          RemoteObject(
            path: e.key,
            size: e.value.length,
            modified: DateTime(2026, 11, 2),
          ),
      ];

  @override
  Future<void> ping() async {}

  @override
  Future<void> put(String path, Uint8List bytes) async {
    objects[path] = bytes;
  }
}

void main() {
  group('进度合并', () {
    test('远端较新则覆盖，较旧则保留本地', () {
      final local = jsonEncode({
        'a': {'title': 'A', 'chapter_index': 1, 'updated_at': '2026-11-01T00:00:00.000Z'},
        'b': {'title': 'B', 'chapter_index': 5, 'updated_at': '2026-11-02T00:00:00.000Z'},
      });
      final remote = jsonEncode({
        'a': {'title': 'A', 'chapter_index': 3, 'updated_at': '2026-11-02T00:00:00.000Z'},
        'b': {'title': 'B', 'chapter_index': 2, 'updated_at': '2026-10-01T00:00:00.000Z'},
        'c': {'title': 'C', 'chapter_index': 0, 'updated_at': '2026-11-02T00:00:00.000Z'},
      });

      final merged = mergeProgressJson(local, remote);
      expect(merged.changed, isTrue);
      expect(merged.changedCount, 2); // a 覆盖 + c 新增
      final json = jsonDecode(merged.json) as Map<String, dynamic>;
      expect((json['a'] as Map)['chapter_index'], 3);
      expect((json['b'] as Map)['chapter_index'], 5);
      expect(json.containsKey('c'), isTrue);
    });

    test('本地为空：全部采用远端', () {
      final remote = jsonEncode({
        'x': {'updated_at': '2026-11-02T00:00:00.000Z'},
      });
      final merged = mergeProgressJson('', remote);
      expect(merged.changedCount, 1);
    });

    test('坏 JSON 不抛异常', () {
      final merged = mergeProgressJson('{not json', '');
      expect(merged.changed, isFalse);
    });
  });

  group('书签/划线合并', () {
    test('按 id 取并集，同 id 取较新', () {
      final local = jsonEncode({
        'b1': [
          {'id': 'm1', 'excerpt': '旧', 'created_at': '2026-11-01T00:00:00.000Z'},
        ],
      });
      final remote = jsonEncode({
        'b1': [
          {'id': 'm1', 'excerpt': '新', 'created_at': '2026-11-02T00:00:00.000Z'},
          {'id': 'm2', 'excerpt': '另一条', 'created_at': '2026-11-02T00:00:00.000Z'},
        ],
        'b2': [
          {'id': 'm3', 'excerpt': '别的书', 'created_at': '2026-11-02T00:00:00.000Z'},
        ],
      });

      final merged = mergeListJson(local, remote);
      // m1 更新 + m2 新增 + b2 的 m3 新增
      expect(merged.changedCount, 3);
      final json = jsonDecode(merged.json) as Map<String, dynamic>;
      final b1 = (json['b1'] as List).cast<Map>();
      expect(b1, hasLength(2));
      expect(b1.firstWhere((m) => m['id'] == 'm1')['excerpt'], '新');
      expect((json['b2'] as List), hasLength(1));
    });

    test('结构不合法的条目被忽略（不崩）', () {
      final merged = mergeListJson(
        jsonEncode({'b': []}),
        jsonEncode({
          'b': [1, 'x', null],
        }),
      );
      expect(merged.changed, isFalse);
    });
  });

  group('备份包', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('aquan_sync');
    });

    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('打包 → 合并：进度/书签写入，本地书只补缺失', () async {
      final support = Directory('${tmp.path}/support')..createSync();
      final library = Directory('${tmp.path}/support/book_library')..createSync();
      await File('${support.path}/${BookSyncService.progressFile}').writeAsString(
        jsonEncode({
          'a': {'title': 'A', 'chapter_index': 1, 'updated_at': '2026-11-01T00:00:00.000Z'},
        }),
      );

      final bundle = buildBundle({
        BookSyncService.progressFile: utf8.encode(jsonEncode({
          'a': {'title': 'A', 'chapter_index': 9, 'updated_at': '2026-11-02T00:00:00.000Z'},
        })),
        BookSyncService.bookmarksFile: utf8.encode(jsonEncode({
          'a': [
            {'id': 'm1', 'excerpt': '摘录', 'created_at': '2026-11-02T00:00:00.000Z'},
          ],
        })),
        'books/abc123/meta.json': utf8.encode('{"id":"abc123","title":"书"}'),
        'books/abc123/book.txt': utf8.encode('正文'),
      });

      final service = BookSyncService(
        supportDir: support,
        libraryDir: library,
        store: _MemoryStore(),
      );
      final report = await service.mergeBundle(Uint8List.fromList(bundle));

      expect(report.progressUpdated, 1);
      expect(report.bookmarksAdded, 1);
      expect(report.booksAdded, 1);
      expect(report.summary, contains('重启后生效'));

      final progress = jsonDecode(
              await File('${support.path}/${BookSyncService.progressFile}')
                  .readAsString())
          as Map<String, dynamic>;
      expect((progress['a'] as Map)['chapter_index'], 9);

      expect(File('${library.path}/abc123/book.txt').existsSync(), isTrue);
    });

    test('本地已有同 id 书目录时不覆盖', () async {
      final support = Directory('${tmp.path}/support2')..createSync();
      final library = Directory('${support.path}/book_library')..createSync();
      final existing = Directory('${library.path}/abc')..createSync();
      await File('${existing.path}/book.txt').writeAsString('本地版');

      final service = BookSyncService(
        supportDir: support,
        libraryDir: library,
        store: _MemoryStore(),
      );
      final report = await service.mergeBundle(
        Uint8List.fromList(buildBundle({
          'books/abc/book.txt': utf8.encode('远端版'),
          'books/abc/meta.json': utf8.encode('{}'),
        })),
      );

      expect(report.booksAdded, 0);
      expect(await File('${existing.path}/book.txt').readAsString(), '本地版');
    });

    test('损坏的包 → 明确报错', () async {
      final service = BookSyncService(
        supportDir: tmp,
        libraryDir: tmp,
        store: _MemoryStore(),
      );
      await expectLater(
        service.mergeBundle(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<RemoteStoreException>()),
      );
    });

    test('backup → restore 全链路（内存远端）', () async {
      final support = Directory('${tmp.path}/support3')..createSync();
      final library = Directory('${support.path}/book_library')..createSync();
      await File('${support.path}/${BookSyncService.progressFile}')
          .writeAsString(jsonEncode({'a': {'updated_at': '2026-11-02T00:00:00.000Z'}}));

      final store = _MemoryStore();
      final service = BookSyncService(
        supportDir: support,
        libraryDir: library,
        store: store,
      );
      final path = await service.backup();
      expect(store.objects.containsKey(path), isTrue);

      // 本地清空后再恢复
      await File('${support.path}/${BookSyncService.progressFile}').writeAsString('{}');
      final report = await service.restore();
      expect(report.progressUpdated, 1);
    });

    test('没有数据时备份诚实报错', () async {
      final support = Directory('${tmp.path}/empty')..createSync();
      final service = BookSyncService(
        supportDir: support,
        libraryDir: Directory('${support.path}/none'),
        store: _MemoryStore(),
      );
      await expectLater(service.backup(), throwsA(isA<RemoteStoreException>()));
    });

    test('远端没有备份时恢复诚实报错', () async {
      final service = BookSyncService(
        supportDir: tmp,
        libraryDir: tmp,
        store: _MemoryStore(),
      );
      await expectLater(service.restore(), throwsA(isA<RemoteStoreException>()));
    });

    test('打包内容可被 ZipDecoder 读回', () {
      final bytes = buildBundle({'a.txt': utf8.encode('hello')});
      final archive = ZipDecoder().decodeBytes(bytes);
      expect(archive.files.single.name, 'a.txt');
      expect(utf8.decode(archive.files.single.content), 'hello');
    });
  });

  group('同步配置', () {
    test('JSON 往返保真（含密码/前缀/region）', () {
      const config = SyncConfig(
        type: SyncBackendType.s3,
        url: 'https://s3.example.com',
        username: 'AK',
        password: 'SK',
        bucket: 'books',
        region: 'ap-east-1',
        prefix: 'backup/',
      );
      final restored = SyncConfig.fromJson(config.toJson());
      expect(restored.type, SyncBackendType.s3);
      expect(restored.bucket, 'books');
      expect(restored.region, 'ap-east-1');
      expect(restored.prefix, 'backup/');
      expect(restored.password, 'SK');
      expect(restored.isConfigured, isTrue);
    });

    test('未填地址视为未配置', () {
      expect(const SyncConfig().isConfigured, isFalse);
      expect(
        const SyncConfig(type: SyncBackendType.s3, url: 'https://x').isConfigured,
        isFalse,
        reason: 'S3 还需要 bucket',
      );
    });

    test('按类型构造对应远端实现', () {
      expect(const SyncConfig(type: SyncBackendType.webdav, url: 'https://dav').buildStore(),
          isA<WebDavStore>());
      expect(
        const SyncConfig(
          type: SyncBackendType.s3,
          url: 'https://s3',
          bucket: 'b',
        ).buildStore(),
        isA<S3Store>(),
      );
    });
  });

  group('S3 SigV4', () {
    const signer = S3Signer(
      accessKey: 'AKIDEXAMPLE',
      secretKey: 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY',
      region: 'us-east-1',
    );

    test('签名头齐全且同输入同输出', () {
      final uri = Uri.parse('https://s3.example.com/bucket/a.zip');
      final now = DateTime.utc(2026, 11, 2, 12, 0, 0);
      final payload = Uint8List.fromList(utf8.encode('x'));
      final first = signer.sign(
        method: 'PUT',
        uri: uri,
        headers: const {'content-type': 'application/octet-stream'},
        now: now,
        payload: payload,
      );
      final second = signer.sign(
        method: 'PUT',
        uri: uri,
        headers: const {'content-type': 'application/octet-stream'},
        now: now,
        payload: payload,
      );

      expect(first['Authorization'], second['Authorization']);
      final auth = first['Authorization']!;
      expect(auth, startsWith('AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/'));
      expect(auth, contains('/us-east-1/s3/aws4_request'));
      expect(auth, contains('SignedHeaders='));
      expect(auth, contains('Signature='));
      expect(first['x-amz-date'], '20261102T120000Z');
      expect(first['x-amz-content-sha256'], isNotEmpty);
      expect(first['host'], 's3.example.com');
    });

    test('payload 不同则签名不同', () {
      final uri = Uri.parse('https://s3.example.com/bucket/a.zip');
      final now = DateTime.utc(2026, 11, 2);
      final a = signer.sign(
        method: 'PUT',
        uri: uri,
        headers: const {},
        now: now,
        payload: Uint8List.fromList([1]),
      );
      final b = signer.sign(
        method: 'PUT',
        uri: uri,
        headers: const {},
        now: now,
        payload: Uint8List.fromList([2]),
      );
      expect(a['Authorization'], isNot(b['Authorization']));
    });

    test('非默认端口写进 host', () {
      final headers = signer.sign(
        method: 'GET',
        uri: Uri.parse('http://minio.local:9000/bucket'),
        headers: const {},
        now: DateTime.utc(2026, 11, 2),
      );
      expect(headers['host'], 'minio.local:9000');
    });
  });
}
