import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/bili/api.dart';
import 'package:aquan_duanju/core/bili/wbi.dart';

void main() {
  group('WbiSigner', () {
    // B 站文档同款示例 key（社区标准用例）。
    const img = 'https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png';
    const sub = 'https://i0.hdslb.com/bfs/wbi/4932caff0ff746eab6f01bf08b70ac45.png';
    const raw =
        '7cd084941338484aae1ad9425b84077c4932caff0ff746eab6f01bf08b70ac45';

    test('从 img/sub URL 提取文件名拼原始表', () {
      expect(WbiSigner.rawMixinKey(img, sub), raw);
    });

    test('deriveMixinKey：按重排表取 32 位（逐位对照表映射）', () {
      final mixin = WbiSigner.deriveMixinKey(raw);
      expect(mixin.length, 32);
      for (var i = 0; i < 32; i++) {
        expect(mixin[i], raw[WbiSigner.mixinKeyEncTab[i]], reason: 'index $i');
      }
      // 每日轮换后的 key 与原始表不同（表不是恒等映射）。
      expect(mixin, isNot(raw.substring(0, 32)));
    });

    test('sign：固定 wts 下 w_rid 确定；参数按 key 排序', () {
      final signed = WbiSigner.sign(
        {'keyword': '三体', 'search_type': 'video'},
        WbiSigner.deriveMixinKey(raw),
        wts: 1700000000,
      );
      expect(signed['wts'], '1700000000');
      expect(signed['w_rid'], hasLength(32));
      // 相同输入 → 相同签名。
      final again = WbiSigner.sign(
        {'search_type': 'video', 'keyword': '三体'},
        WbiSigner.deriveMixinKey(raw),
        wts: 1700000000,
      );
      expect(again['w_rid'], signed['w_rid'],
          reason: 'key 顺序不影响签名（内部会排序）');
      // 不同 wts → 不同签名。
      final other = WbiSigner.sign(
        {'keyword': '三体', 'search_type': 'video'},
        WbiSigner.deriveMixinKey(raw),
        wts: 1700000001,
      );
      expect(other['w_rid'], isNot(signed['w_rid']));
    });

    test('sign：值里的特殊字符按社区标准剔除', () {
      final signed = WbiSigner.sign(
        {'q': 'a!b*c(d)'},
        WbiSigner.deriveMixinKey(raw),
        wts: 1,
      );
      expect(signed['q'], 'abcd');
    });
  });

  group('parseDanmakuSegment（protobuf 手解）', () {
    test('两个弹幕元素的段', () {
      final bytes = _buildSegment([
        (progressMs: 1200, text: '前方高能'),
        (progressMs: 60000, text: '三连了'),
      ]);
      final items = parseDanmakuSegment(bytes);
      expect(items.length, 2);
      // 按 progress 排序。
      expect(items[0].text, '前方高能');
      expect(items[0].progressMs, 1200);
      expect(items[1].text, '三连了');
      expect(items[1].progressMs, 60000);
    });

    test('空段与非弹幕字段跳过', () {
      final bytes = BytesBuilder()
        ..add([0x08, 0x2a]); // field 1 varint 42（不是 message）→ 跳过
      final items = parseDanmakuSegment(bytes.takeBytes());
      expect(items, isEmpty);
    });

    test('中文 UTF-8 解码', () {
      final bytes = _buildSegment([
        (progressMs: 3000, text: '弹幕中文✨'),
      ]);
      expect(parseDanmakuSegment(bytes).single.text, '弹幕中文✨');
    });
  });

  group('模型解析', () {
    test('BiliSeason.fromJson 提取剧集', () {
      final season = BiliSeason.fromJson({
        'season_id': 123,
        'title': '某番剧',
        'cover': 'http://i/cover.jpg',
        'evaluate': '<p>简介<b>加粗</b></p>',
        'episodes': [
          {'id': 1, 'cid': 100, 'bvid': 'BV1', 'long_title': '第1话 ', 'title': '1'},
          {'id': 2, 'cid': 200, 'bvid': 'BV1', 'long_title': '第2话', 'title': '2'},
        ],
      });
      expect(season.episodes.length, 2);
      expect(season.episodes[0].title, '第1话');
      expect(season.episodes[0].index, 1);
      expect(season.description, '简介加粗');
    });

    test('封面协议相对路径（//host）补全为 https（搜索结果全部无封面的根因）', () {
      final video = BiliSearchItem.fromJson(
          {'bvid': 'BV1', 'title': 't', 'pic': '//i0.hdslb.com/bfs/x.jpg'},
          'video');
      expect(video.coverUrl, 'https://i0.hdslb.com/bfs/x.jpg');
      final bangumi = BiliSearchItem.fromJson(
          {'season_id': 1, 'title': 't', 'cover': '//i0.hdslb.com/bfs/y.jpg'},
          'media_bangumi');
      expect(bangumi.coverUrl, 'https://i0.hdslb.com/bfs/y.jpg');
      // 已带协议的 URL 原样保留。
      final kept = BiliSearchItem.fromJson(
          {'bvid': 'BV1', 'title': 't', 'pic': 'http://i/cover.jpg'}, 'video');
      expect(kept.coverUrl, 'http://i/cover.jpg');
    });

    test('BiliStream.fromJson 取 baseUrl，缺失时回退 backupUrl', () {
      final s1 = BiliStream.fromJson({
        'baseUrl': 'http://a/main.m4s',
        'bandwidth': 2000000,
        'width': 1920,
        'height': 1080,
      });
      expect(s1.url, 'http://a/main.m4s');
      final s2 = BiliStream.fromJson({
        'backupUrl': ['http://b/backup.m4s'],
        'bandwidth': 1,
      });
      expect(s2.url, 'http://b/backup.m4s');
    });
  });
}

/// 手工构造 seg.so：Segment{ elems=1 } ← DanmakuElem{ progress=2 varint, text=4 string }。
Uint8List _buildSegment(List<({int progressMs, String text})> elems) {
  final out = BytesBuilder();
  void writeVarint(BytesBuilder b, int v) {
    while (v >= 0x80) {
      b.add([0x80 | (v & 0x7f)]);
      v >>= 7;
    }
    b.add([v]);
  }

  for (final e in elems) {
    final elem = BytesBuilder();
    // field 2 varint: (2<<3)|0 = 0x10
    elem.add([0x10]);
    writeVarint(elem, e.progressMs);
    // field 4 string: (4<<3)|2 = 0x22
    final textBytes = utf8.encode(e.text);
    elem.add([0x22]);
    writeVarint(elem, textBytes.length);
    elem.add(textBytes);
    // segment field 1 length-delimited: (1<<3)|2 = 0x0a
    out.add([0x0a]);
    writeVarint(out, elem.length);
    out.add(elem.takeBytes());
  }
  return out.takeBytes();
}
