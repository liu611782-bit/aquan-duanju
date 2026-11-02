import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/book_markup.dart';

void main() {
  group('decodeMarkupBytes', () {
    test('UTF-8 无声明：严格解码，无有损标记', () {
      final bytes = Uint8List.fromList(utf8.encode('<html>轻小说文库</html>'));
      final r = decodeMarkupBytes(bytes);
      expect(r.text, '<html>轻小说文库</html>');
      expect(r.charset, 'utf-8');
      expect(r.lossy, isFalse);
    });

    test('UTF-8 BOM：去 BOM 且不误判编码', () {
      final bytes = Uint8List.fromList([
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('第一章 起点'),
      ]);
      final r = decodeMarkupBytes(bytes);
      expect(r.text, '第一章 起点');
      expect(r.charset, 'utf-8');
      expect(r.text.startsWith('\uFEFF'), isFalse);
    });

    test('UTF-16LE BOM：按码元解码', () {
      final payload = '轻小说';
      final bytes = BytesBuilder();
      bytes.add([0xFF, 0xFE]);
      for (final cu in payload.codeUnits) {
        bytes.add([cu & 0xFF, (cu >> 8) & 0xFF]);
      }
      final r = decodeMarkupBytes(bytes.toBytes());
      expect(r.text, payload);
      expect(r.charset, 'utf-16le');
    });

    test('GBK + meta 声明：正确解出中文', () {
      const body = '<meta charset="gbk"><div>魔法禁书目录</div>';
      final bytes = Uint8List.fromList(gbk.encode(body));
      final r = decodeMarkupBytes(bytes);
      expect(r.text, body);
      expect(r.charset, 'gbk');
      expect(r.lossy, isFalse);
    });

    test('GBK 无声明：严格 UTF-8 失败后回落 GBK', () {
      const body = '<html><body>文学少女与她的忧郁</body></html>';
      final bytes = Uint8List.fromList(gbk.encode(body));
      final r = decodeMarkupBytes(bytes);
      expect(r.text, body);
      expect(r.charset, 'gbk');
    });

    test('HTTP Content-Type 声明优先于文档嗅探', () {
      const body = '<html><body>灼眼的夏娜</body></html>';
      final bytes = Uint8List.fromList(gbk.encode(body));
      final r = decodeMarkupBytes(
        bytes,
        contentType: 'text/html; charset=gb2312',
      );
      expect(r.text, body);
      expect(r.charset, 'gbk');
    });

    test('XML 声明 encoding 也能识别', () {
      const body = '<?xml version="1.0" encoding="gb18030"?><r>凉宫春日的忧郁</r>';
      final bytes = Uint8List.fromList(gbk.encode(body));
      final r = decodeMarkupBytes(bytes);
      expect(r.text, body);
      expect(r.charset, 'gbk');
    });

    test('坏字节：兜底有损解码并标记 lossy', () {
      final bytes = Uint8List.fromList([0x3C, 0x70, 0x3E, 0xFF, 0xFF, 0x3C]);
      final r = decodeMarkupBytes(bytes);
      expect(r.text.contains('<p>'), isTrue);
      expect(r.lossy, isTrue);
    });

    test('空字节：返回空文本且不抛', () {
      final r = decodeMarkupBytes(Uint8List(0));
      expect(r.text, '');
      expect(r.lossy, isFalse);
    });

    test('纯 ASCII 大页仍按 UTF-8（不误判 GBK）', () {
      final bytes = Uint8List.fromList(utf8.encode('a' * 5000));
      final r = decodeMarkupBytes(bytes);
      expect(r.text.length, 5000);
      expect(r.charset, 'utf-8');
    });
  });

  group('sniffMarkupCharset', () {
    test('BOM 优先', () {
      expect(
        sniffMarkupCharset(Uint8List.fromList([0xFF, 0xFE, 0x41, 0x00])),
        'utf-16le',
      );
    });

    test('contentType 优先于文档', () {
      final bytes = Uint8List.fromList(utf8.encode('<meta charset="utf-8">'));
      expect(
        sniffMarkupCharset(bytes, contentType: 'text/html; charset=gbk'),
        'gbk',
      );
    });

    test('无任何声明返回 null', () {
      expect(sniffMarkupCharset(Uint8List.fromList(utf8.encode('plain'))), isNull);
    });
  });

  test('decodeMarkupText 便捷入口与主入口一致', () {
    const body = '<html>狼与香辛料</html>';
    final bytes = Uint8List.fromList(gbk.encode(body));
    expect(decodeMarkupText(bytes), body);
  });
}
