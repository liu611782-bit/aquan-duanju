import 'package:flutter_test/flutter_test.dart';

import 'package:aquan_duanju/core/image_key.dart';

void main() {
  group('stableImageKey', () {
    test('剔除签名与过期参数', () {
      expect(
        stableImageKey(
            'https://p3.douyinpic.com/a.heic?x-expires=1700000000&x-signature=abc'),
        'https://p3.douyinpic.com/a.heic',
      );
      expect(
        stableImageKey('https://cdn.example.com/b.jpg?sign=1&expires=2&token=3'),
        'https://cdn.example.com/b.jpg',
      );
    });

    test('保留业务参数', () {
      expect(
        stableImageKey(
            'https://cdn.example.com/c.jpg?from=84211&x-signature=abc&w=300'),
        'https://cdn.example.com/c.jpg?from=84211&w=300',
      );
    });

    test('同一图片不同签名产生相同 key', () {
      const first =
          'https://p3.douyinpic.com/x.heic?x-expires=1&x-signature=aaa';
      const second =
          'https://p3.douyinpic.com/x.heic?x-expires=9&x-signature=bbb';
      expect(stableImageKey(first), stableImageKey(second));
    });

    test('参数顺序稳定（不做排序，保持原始顺序）', () {
      expect(
        stableImageKey('https://cdn.example.com/d.jpg?w=300&h=400'),
        'https://cdn.example.com/d.jpg?w=300&h=400',
      );
      expect(
        stableImageKey('https://cdn.example.com/d.jpg?h=400&w=300'),
        'https://cdn.example.com/d.jpg?h=400&w=300',
      );
    });

    test('无查询串原样返回', () {
      expect(
        stableImageKey('https://cdn.example.com/e.jpg'),
        'https://cdn.example.com/e.jpg',
      );
    });

    test('空串与非法输入原样返回', () {
      expect(stableImageKey(''), '');
      expect(stableImageKey('/local/path.jpg'), '/local/path.jpg');
    });

    test('参数名大小写不敏感', () {
      expect(
        stableImageKey('https://cdn.example.com/f.jpg?X-Signature=abc&keep=1'),
        'https://cdn.example.com/f.jpg?keep=1',
      );
    });
  });
}
