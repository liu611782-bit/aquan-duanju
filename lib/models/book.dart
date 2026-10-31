/// 书籍相关模型：与 core 的 `bookDetail` / `bookDirectory` 输出一一对应
/// （字段名见 `native/bridge/core/book.go` 的 json tag）。
library;

/// 书籍详情。
class BookDetail {
  const BookDetail({
    required this.id,
    this.title = '',
    this.author = '',
    this.abstractText = '',
    this.coverUrl = '',
    this.wordCount = 0,
    this.chapterCount = 0,
    this.lastChapterTitle = '',
    this.category = '',
    this.score = '',
    this.readCount = 0,
    this.finished = false,
  });

  final String id;
  final String title;
  final String author;

  /// 与 `abstract` 字段对应（`abstract` 是 Dart 保留字）。
  final String abstractText;
  final String coverUrl;
  final int wordCount;
  final int chapterCount;
  final String lastChapterTitle;
  final String category;
  final String score;
  final int readCount;

  /// 上游 `creation_status == 1` 表示完结。
  final bool finished;

  factory BookDetail.fromJson(Map<String, dynamic> json) => BookDetail(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        author: json['author'] as String? ?? '',
        abstractText: json['abstract'] as String? ?? '',
        coverUrl: json['cover_url'] as String? ?? '',
        wordCount: (json['word_count'] as num?)?.toInt() ?? 0,
        chapterCount: (json['chapter_count'] as num?)?.toInt() ?? 0,
        lastChapterTitle: json['last_chapter_title'] as String? ?? '',
        category: json['category'] as String? ?? '',
        score: json['score'] as String? ?? '',
        readCount: (json['read_count'] as num?)?.toInt() ?? 0,
        finished: json['finished'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'author': author,
        'abstract': abstractText,
        'cover_url': coverUrl,
        'word_count': wordCount,
        'chapter_count': chapterCount,
        'last_chapter_title': lastChapterTitle,
        'category': category,
        'score': score,
        'read_count': readCount,
        'finished': finished,
      };
}

/// 目录里的一章。
class BookChapter {
  const BookChapter({
    required this.id,
    this.title = '',
    this.volume = '',
    this.index = 0,
  });

  final String id;
  final String title;

  /// 分卷名；空表示这本书不分卷。
  final String volume;
  final int index;

  factory BookChapter.fromJson(Map<String, dynamic> json) => BookChapter(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        volume: json['volume'] as String? ?? '',
        index: (json['index'] as num?)?.toInt() ?? 0,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'volume': volume,
        'index': index,
      };
}

/// 整本目录。
class BookDirectory {
  const BookDirectory({this.total = 0, this.chapters = const []});

  final int total;
  final List<BookChapter> chapters;

  bool get isEmpty => chapters.isEmpty;

  factory BookDirectory.fromJson(Map<String, dynamic> json) => BookDirectory(
        total: (json['total'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(BookChapter.fromJson)
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'total': total,
        'chapters': [for (final c in chapters) c.toJson()],
      };
}
