import 'package:flutter/painting.dart';

/// 阅读排版参数。翻页模式与滚动模式共用同一份，杜绝两条渲染路径各自硬编码。
class ReaderTypography {
  const ReaderTypography({
    this.fontSize = 19,
    this.fontWeight = 400,
    this.italic = false,
    this.fontFamily,
    this.fontFilePath,
    this.letterSpacing = 0,
    this.lineHeight = 1.8,
    this.paragraphSpacing = 12,
    this.paragraphIndent = '　　',
    this.paddingTop = 64,
    this.paddingBottom = 96,
    this.paddingLeft = 22,
    this.paddingRight = 22,
    this.includeChapterTitle = true,
  });

  static const double minFontSize = 14;
  static const double maxFontSize = 34;
  static const double minLineHeight = 1.2;
  static const double maxLineHeight = 2.6;
  static const double minParagraphSpacing = 0;
  static const double maxParagraphSpacing = 40;
  static const double maxPadding = 160;

  /// 正文字号（逻辑像素，未乘系统字体缩放）。
  final double fontSize;

  /// 100..900。
  final int fontWeight;
  final bool italic;

  /// 系统族名或内置字体 family（如 `LXGWWenKai`）。
  final String? fontFamily;

  /// 本地导入字体的文件路径（仅用于 UI 展示与重装；渲染走动态注册的 family）。
  final String? fontFilePath;

  /// 字间距，单位 em。
  final double letterSpacing;

  /// 行高倍数。
  final double lineHeight;

  /// 段间距（逻辑像素）。
  final double paragraphSpacing;

  /// 首行缩进字符串（默认两个全角空格）。
  final String paragraphIndent;

  final double paddingTop;
  final double paddingBottom;
  final double paddingLeft;
  final double paddingRight;

  /// 章节标题是否占正文首屏。
  final bool includeChapterTitle;

  FontWeight get fontWeightValue {
    final index = (fontWeight / 100).round() - 1;
    return FontWeight.values[index.clamp(0, FontWeight.values.length - 1)];
  }

  /// 单行行高（逻辑像素）。渲染时用 `SizedBox(height: lineHeightPx)` 强制，
  /// 保证与分页器的测量结果逐像素一致。
  double lineHeightPx({TextScaler? textScaler}) =>
      scaledFontSize(textScaler) * lineHeight;

  double scaledFontSize(TextScaler? textScaler) =>
      textScaler == null ? fontSize : textScaler.scale(fontSize);

  TextStyle bodyStyle({
    required Color color,
    TextScaler? textScaler,
    bool withHeight = true,
  }) =>
      TextStyle(
        color: color,
        fontSize: scaledFontSize(textScaler),
        fontWeight: fontWeightValue,
        fontStyle: italic ? FontStyle.italic : FontStyle.normal,
        fontFamily: fontFamily,
        letterSpacing: letterSpacing * scaledFontSize(textScaler),
        height: withHeight ? lineHeight : null,
        leadingDistribution: TextLeadingDistribution.even,
      );

  TextStyle titleStyle({
    required Color color,
    TextScaler? textScaler,
  }) =>
      TextStyle(
        color: color,
        fontSize: scaledFontSize(textScaler) + 4,
        fontWeight: FontWeight.w700,
        fontFamily: fontFamily,
        height: 1.4,
        leadingDistribution: TextLeadingDistribution.even,
      );

  /// 按书字号缩放（VenHM 分层设置语义）：只放大字号并钳到合法区间，
  /// 行距系数/边距/字重不动——避免按书克隆整套主题。
  ReaderTypography scale(double factor) =>
      copyWith(fontSize: fontSize * factor);

  ReaderTypography copyWith({
    double? fontSize,
    int? fontWeight,
    bool? italic,
    Object? fontFamily = _unset,
    Object? fontFilePath = _unset,
    double? letterSpacing,
    double? lineHeight,
    double? paragraphSpacing,
    String? paragraphIndent,
    double? paddingTop,
    double? paddingBottom,
    double? paddingLeft,
    double? paddingRight,
    bool? includeChapterTitle,
  }) =>
      ReaderTypography(
        fontSize: (fontSize ?? this.fontSize).clamp(minFontSize, maxFontSize),
        fontWeight: (fontWeight ?? this.fontWeight).clamp(100, 900),
        italic: italic ?? this.italic,
        fontFamily:
            identical(fontFamily, _unset) ? this.fontFamily : fontFamily as String?,
        fontFilePath: identical(fontFilePath, _unset)
            ? this.fontFilePath
            : fontFilePath as String?,
        letterSpacing: (letterSpacing ?? this.letterSpacing).clamp(0.0, 1.0),
        lineHeight:
            (lineHeight ?? this.lineHeight).clamp(minLineHeight, maxLineHeight),
        paragraphSpacing: (paragraphSpacing ?? this.paragraphSpacing)
            .clamp(minParagraphSpacing, maxParagraphSpacing),
        paragraphIndent: paragraphIndent ?? this.paragraphIndent,
        paddingTop: (paddingTop ?? this.paddingTop).clamp(0.0, maxPadding),
        paddingBottom:
            (paddingBottom ?? this.paddingBottom).clamp(0.0, maxPadding),
        paddingLeft: (paddingLeft ?? this.paddingLeft).clamp(0.0, maxPadding),
        paddingRight:
            (paddingRight ?? this.paddingRight).clamp(0.0, maxPadding),
        includeChapterTitle: includeChapterTitle ?? this.includeChapterTitle,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'font_size': fontSize,
        'font_weight': fontWeight,
        'italic': italic,
        if (fontFamily != null) 'font_family': fontFamily,
        if (fontFilePath != null) 'font_file': fontFilePath,
        'letter_spacing': letterSpacing,
        'line_height': lineHeight,
        'paragraph_spacing': paragraphSpacing,
        'paragraph_indent': paragraphIndent,
        'padding_top': paddingTop,
        'padding_bottom': paddingBottom,
        'padding_left': paddingLeft,
        'padding_right': paddingRight,
        'include_title': includeChapterTitle,
      };

  factory ReaderTypography.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ReaderTypography();
    final base = const ReaderTypography();
    double num0(Object? v, double fallback) =>
        v is num && v.isFinite ? v.toDouble() : fallback;
    final weight = json['font_weight'];
    return ReaderTypography(
      fontSize: num0(json['font_size'], base.fontSize)
          .clamp(minFontSize, maxFontSize),
      fontWeight: (weight is num ? weight.toInt() : base.fontWeight)
          .clamp(100, 900),
      italic: json['italic'] is bool ? json['italic'] as bool : base.italic,
      fontFamily: json['font_family'] as String?,
      fontFilePath: json['font_file'] as String?,
      letterSpacing: num0(json['letter_spacing'], base.letterSpacing),
      lineHeight: num0(json['line_height'], base.lineHeight)
          .clamp(minLineHeight, maxLineHeight),
      paragraphSpacing: num0(json['paragraph_spacing'], base.paragraphSpacing)
          .clamp(minParagraphSpacing, maxParagraphSpacing),
      paragraphIndent:
          json['paragraph_indent'] as String? ?? base.paragraphIndent,
      paddingTop: num0(json['padding_top'], base.paddingTop)
          .clamp(0.0, maxPadding),
      paddingBottom: num0(json['padding_bottom'], base.paddingBottom)
          .clamp(0.0, maxPadding),
      paddingLeft: num0(json['padding_left'], base.paddingLeft)
          .clamp(0.0, maxPadding),
      paddingRight: num0(json['padding_right'], base.paddingRight)
          .clamp(0.0, maxPadding),
      includeChapterTitle: json['include_title'] is bool
          ? json['include_title'] as bool
          : base.includeChapterTitle,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReaderTypography &&
      other.fontSize == fontSize &&
      other.fontWeight == fontWeight &&
      other.italic == italic &&
      other.fontFamily == fontFamily &&
      other.fontFilePath == fontFilePath &&
      other.letterSpacing == letterSpacing &&
      other.lineHeight == lineHeight &&
      other.paragraphSpacing == paragraphSpacing &&
      other.paragraphIndent == paragraphIndent &&
      other.paddingTop == paddingTop &&
      other.paddingBottom == paddingBottom &&
      other.paddingLeft == paddingLeft &&
      other.paddingRight == paddingRight &&
      other.includeChapterTitle == includeChapterTitle;

  @override
  int get hashCode => Object.hash(
        fontSize,
        fontWeight,
        italic,
        fontFamily,
        fontFilePath,
        letterSpacing,
        lineHeight,
        paragraphSpacing,
        paragraphIndent,
        paddingTop,
        paddingBottom,
        paddingLeft,
        paddingRight,
        includeChapterTitle,
      );
}

/// `copyWith` 区分「不传」与「显式传 null」用的哨兵。
const Object _unset = Object();
