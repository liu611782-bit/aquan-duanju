import 'package:flutter_test/flutter_test.dart';
import 'package:aquan_duanju/core/sources/venera/venera_manga_source.dart';

void main() {
  test('comicsOf 分节键值形态', () {
    final r = {
      '编辑推荐': <dynamic>[],
      '最近更新': [
        {'id': 287, 'title': '異人', 'cover': 'https://x/1.jpg'},
      ],
    };
    final out = VeneraComic.comicsOf(r);
    expect(out, hasLength(1));
    expect(out.first.title, '異人');
  });
}
