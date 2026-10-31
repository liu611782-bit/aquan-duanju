import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/reader/reader_font_registrar.dart';
import '../../core/reader/reader_page_metrics.dart';
import '../../core/reader/reader_settings.dart';
import '../../core/reader/reader_theme.dart';
import '../../core/reader/reader_typography.dart';
import '../../store/stores.dart';
import '../common.dart';
import 'reader_click_zone_editor.dart';

/// 打开阅读设置面板。
Future<void> showReaderSettingsSheet(
  BuildContext context, {
  required ReaderSettingsStore store,
  String? bookId,
  String previewText = '春江潮水连海平，海上明月共潮生。滟滟随波千万里，何处春江无月明。',
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 600),
    builder: (_) => FractionallySizedBox(
      heightFactor: 0.86,
      child: ReaderSettingsSheet(
          store: store, bookId: bookId, previewText: previewText),
    ),
  );
}

class ReaderSettingsSheet extends StatefulWidget {
  const ReaderSettingsSheet({
    super.key,
    required this.store,
    this.bookId,
    this.previewText = '',
  });

  final ReaderSettingsStore store;

  /// 非空时显示「本书单独设置」段（VenHM 分层语义：覆盖优先，清除回全局）。
  final String? bookId;
  final String previewText;

  @override
  State<ReaderSettingsSheet> createState() => _ReaderSettingsSheetState();
}

class _ReaderSettingsSheetState extends State<ReaderSettingsSheet> {
  static const List<int> _indentChars = <int>[0, 1, 2, 4];
  static const List<int> _fontWeights = <int>[300, 400, 500, 700];
  static const List<int> _bgColors = <int>[
    0xFFF6F1E4,
    0xFFFFFFFF,
    0xFFF2F2F2,
    0xFFC7EDCC,
    0xFFDCE8F5,
    0xFFF7E8C8,
    0xFF1F1F1F,
    0xFF121212,
    0xFF1A2418,
    0xFF2B2118,
  ];
  static const List<int> _textColors = <int>[
    0xFF2E2A24,
    0xFF1A1A1A,
    0xFF4A4A4A,
    0xFFC9C6C0,
    0xFFE8E4DC,
  ];

  int _tab = 0;

  ReaderSettings get _settings => widget.store.value;

  Future<void> _apply(ReaderSettings next) => widget.store.update(next);

  Future<void> _applyType(ReaderTypography next) => _apply(
        _settings.withActiveTheme(
          _settings.activeThemeConfig.copyWith(typography: next),
        ),
      );

  Future<void> _applyTheme(ReaderThemeConfig next) =>
      _apply(_settings.withActiveTheme(next));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final theme = Theme.of(context);
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text('阅读设置', style: theme.textTheme.titleMedium),
                  const Spacer(),
                  Text(
                    _settings.activeThemeConfig.name,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            if (widget.bookId != null) _buildBookOverrideSection(theme),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                children: [
                  for (var i = 0; i < 5; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
                        label: Text(const ['排版', '主题', '翻页', '交互', '更多'][i]),
                        selected: _tab == i,
                        onSelected: (_) => setState(() => _tab = i),
                      ),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                child: switch (_tab) {
                  0 => _typographyTab(),
                  1 => _themeTab(),
                  2 => _pagingTab(),
                  3 => _interactionTab(),
                  _ => _moreTab(),
                },
              ),
            ),
          ],
        );
      },
    );
  }

  // ---------------- 排版 ----------------

  Widget _typographyTab() {
    final type = _settings.activeThemeConfig.typography;
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Color(_settings.nightMode
                ? _settings.activeThemeConfig.backgroundColorNight
                : _settings.activeThemeConfig.backgroundColor),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            widget.previewText,
            style: type.bodyStyle(
              color: Color(_settings.nightMode
                  ? _settings.activeThemeConfig.textColorNight
                  : _settings.activeThemeConfig.textColor),
            ),
          ),
        ),
        const SizedBox(height: 10),
        _slider(
          label: '字号',
          value: type.fontSize,
          min: ReaderTypography.minFontSize,
          max: ReaderTypography.maxFontSize,
          divisions: 20,
          display: type.fontSize.toStringAsFixed(0),
          onChanged: (v) => _applyType(type.copyWith(fontSize: v)),
        ),
        _slider(
          label: '行距',
          value: type.lineHeight,
          min: ReaderTypography.minLineHeight,
          max: ReaderTypography.maxLineHeight,
          divisions: 14,
          display: type.lineHeight.toStringAsFixed(1),
          onChanged: (v) => _applyType(type.copyWith(lineHeight: v)),
        ),
        _slider(
          label: '段间距',
          value: type.paragraphSpacing,
          min: 0,
          max: ReaderTypography.maxParagraphSpacing,
          divisions: 20,
          display: type.paragraphSpacing.toStringAsFixed(0),
          onChanged: (v) => _applyType(type.copyWith(paragraphSpacing: v)),
        ),
        _slider(
          label: '左右边距',
          value: type.paddingLeft,
          min: 0,
          max: 64,
          divisions: 16,
          display: type.paddingLeft.toStringAsFixed(0),
          onChanged: (v) => _applyType(
            type.copyWith(paddingLeft: v, paddingRight: v),
          ),
        ),
        _slider(
          label: '上边距',
          value: type.paddingTop,
          min: 0,
          max: 160,
          divisions: 32,
          display: type.paddingTop.toStringAsFixed(0),
          onChanged: (v) => _applyType(type.copyWith(paddingTop: v)),
        ),
        _slider(
          label: '下边距',
          value: type.paddingBottom,
          min: 0,
          max: 160,
          divisions: 32,
          display: type.paddingBottom.toStringAsFixed(0),
          onChanged: (v) => _applyType(type.copyWith(paddingBottom: v)),
        ),
        _slider(
          label: '字间距',
          value: type.letterSpacing,
          min: 0,
          max: 0.5,
          divisions: 10,
          display: type.letterSpacing.toStringAsFixed(2),
          onChanged: (v) => _applyType(type.copyWith(letterSpacing: v)),
        ),
        const SizedBox(height: 6),
        _sectionTitle('字重'),
        Wrap(
          spacing: 8,
          children: [
            for (final weight in _fontWeights)
              ChoiceChip(
                label: Text(_weightLabel(weight)),
                selected: type.fontWeight == weight,
                onSelected: (_) =>
                    _applyType(type.copyWith(fontWeight: weight)),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _sectionTitle('首行缩进'),
        Wrap(
          spacing: 8,
          children: [
            for (final count in _indentChars)
              ChoiceChip(
                label: Text(count == 0 ? '无' : '$count 字'),
                selected:
                    type.paragraphIndent.length == count,
                onSelected: (_) => _applyType(
                  type.copyWith(paragraphIndent: '　' * count),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        _sectionTitle('字体'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            ChoiceChip(
              label: const Text('系统黑体'),
              selected: type.fontFamily == null,
              onSelected: (_) => _applyType(
                type.copyWith(fontFamily: null, fontFilePath: null),
              ),
            ),
            ChoiceChip(
              label: const Text(kReaderBuiltinFontLabel),
              selected: type.fontFamily == kReaderBuiltinFontFamily,
              onSelected: (_) => _applyType(
                type.copyWith(
                  fontFamily: kReaderBuiltinFontFamily,
                  fontFilePath: null,
                ),
              ),
            ),
            if (type.fontFilePath != null)
              ChoiceChip(
                label: const Text('本地字体'),
                selected: true,
                onSelected: (_) {},
              ),
            ActionChip(
              avatar: const Icon(Icons.folder_open, size: 18),
              label: const Text('导入本地字体'),
              onPressed: _importFont,
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('斜体'),
          value: type.italic,
          onChanged: (v) => _applyType(type.copyWith(italic: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('显示章节标题'),
          subtitle: Text('关闭后正文从第一页开始，能多放几行',
              style: theme.textTheme.bodySmall),
          value: type.includeChapterTitle,
          onChanged: (v) =>
              _applyType(type.copyWith(includeChapterTitle: v)),
        ),
      ],
    );
  }

  String _weightLabel(int weight) => switch (weight) {
        300 => '细',
        400 => '常规',
        500 => '中粗',
        _ => '加粗',
      };

  Future<void> _importFont() async {
    const group = XTypeGroup(
      label: '字体文件',
      extensions: <String>['ttf', 'otf', 'ttc'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    final family = await ReaderFontRegistrar.register(file.path);
    if (family == null) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(const SnackBar(content: Text('字体加载失败，已保留系统字体')));
      return;
    }
    final type = _settings.activeThemeConfig.typography;
    await _applyType(type.copyWith(
      fontFamily: family,
      fontFilePath: file.path,
    ));
  }


  // ---------------- 本书单独设置 ----------------

  /// 按书覆盖段：主题 / 模式 / 字号缩放；「跟随全局」= 清除覆盖。
  Widget _buildBookOverrideSection(ThemeData theme) {
    final bookId = widget.bookId!;
    final settings = _settings;
    final override = settings.bookOverrideOf(bookId) ?? const <String, Object?>{};
    final hasOverride = override.isNotEmpty;
    final themeIndex = settings.themeIndexFor(bookId);
    final themes = settings.effectiveThemes;
    final mode = settings.modeFor(bookId);
    final scale = settings.fontScaleFor(bookId);
    final baseFont = themes[themeIndex.clamp(0, themes.length - 1)].typography.fontSize;

    Future<void> write(String field, Object? value) =>
        widget.store.setBookOverride(bookId, field, value);

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.menu_book_rounded,
                  size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Text('本书单独设置',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const Spacer(),
              if (hasOverride)
                TextButton(
                  onPressed: () async {
                    for (final field in [
                      ReaderSettings.bookFieldTheme,
                      ReaderSettings.bookFieldMode,
                      ReaderSettings.bookFieldFontScale,
                    ]) {
                      await write(field, null);
                    }
                  },
                  child: const Text('恢复跟随全局'),
                ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('主题跟随全局'),
                selected: override[ReaderSettings.bookFieldTheme] == null,
                onSelected: (_) =>
                    write(ReaderSettings.bookFieldTheme, null),
              ),
              for (var i = 0; i < themes.length; i++)
                ChoiceChip(
                  label: Text(themes[i].name),
                  selected: override[ReaderSettings.bookFieldTheme] != null &&
                      themeIndex == i,
                  onSelected: (_) =>
                      write(ReaderSettings.bookFieldTheme, i),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              ChoiceChip(
                label: const Text('模式跟随全局'),
                selected: override[ReaderSettings.bookFieldMode] == null,
                onSelected: (_) => write(ReaderSettings.bookFieldMode, null),
              ),
              for (final m in ReaderMode.values)
                ChoiceChip(
                  label: Text(m.label),
                  selected: override[ReaderSettings.bookFieldMode] != null &&
                      mode == m,
                  onSelected: (_) =>
                      write(ReaderSettings.bookFieldMode, m.name),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Text('字号 ${(baseFont * scale).round()}',
                  style: theme.textTheme.bodySmall),
              Expanded(
                child: Slider(
                  value: scale,
                  min: ReaderSettings.minFontScale,
                  max: ReaderSettings.maxFontScale,
                  divisions: 14,
                  label: '×${scale.toStringAsFixed(2)}',
                  onChanged: (v) =>
                      write(ReaderSettings.bookFieldFontScale, v),
                ),
              ),
              TextButton(
                onPressed: override[ReaderSettings.bookFieldFontScale] == null
                    ? null
                    : () => write(ReaderSettings.bookFieldFontScale, null),
                child: const Text('跟随全局'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------- 主题 ----------------

  Widget _themeTab() {
    final settings = _settings;
    final config = settings.activeThemeConfig;
    final themes = settings.effectiveThemes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('排版主题'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (var i = 0; i < themes.length; i++)
              ChoiceChip(
                label: Text(themes[i].name),
                selected: settings.activeTheme == i,
                onSelected: (_) => _apply(
                  settings.copyWith(
                    activeTheme: i,
                    nightMode: themes[i].backgroundColorNight > 0xFF202020 &&
                        themes[i].id == 'theme_night',
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: _duplicateTheme,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('复制当前'),
            ),
            OutlinedButton.icon(
              onPressed: _renameTheme,
              icon: const Icon(Icons.drive_file_rename_outline, size: 18),
              label: const Text('重命名'),
            ),
            OutlinedButton.icon(
              onPressed: themes.length <= 1 ? null : _deleteTheme,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
            ),
          ],
        ),
        const Divider(height: 24),
        _sectionTitle('背景类型'),
        SegmentedButton<ReaderBackgroundKind>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
                value: ReaderBackgroundKind.color, label: Text('纯色')),
            ButtonSegment(
                value: ReaderBackgroundKind.asset, label: Text('内置图')),
            ButtonSegment(
                value: ReaderBackgroundKind.file, label: Text('本地图')),
          ],
          selected: {config.backgroundKind},
          onSelectionChanged: (values) =>
              _applyTheme(config.copyWith(backgroundKind: values.first)),
        ),
        if (config.backgroundKind == ReaderBackgroundKind.asset) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              for (final asset in kReaderBackgrounds)
                InkWell(
                  onTap: () => _applyTheme(
                    config.copyWith(backgroundAsset: asset.path),
                  ),
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 84,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            width: 2,
                            color: config.backgroundAsset == asset.path
                                ? Theme.of(context).colorScheme.primary
                                : Colors.transparent,
                          ),
                          image: DecorationImage(
                            image: AssetImage(asset.path),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(asset.label,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
          _slider(
            label: '纹理强度',
            value: config.backgroundAlpha,
            min: 0,
            max: 1,
            divisions: 10,
            display: (config.backgroundAlpha * 100).toStringAsFixed(0),
            onChanged: (v) => _applyTheme(config.copyWith(backgroundAlpha: v)),
          ),
        ],
        if (config.backgroundKind == ReaderBackgroundKind.file) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickBackgroundFile,
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(config.backgroundFile == null ? '选择图片' : '重新选择'),
          ),
        ],
        const SizedBox(height: 8),
        _sectionTitle('背景色'),
        _colorRow(
          colors: _bgColors,
          // 夜间开关开着时选的就是夜间底色：所见即所选，否则改白天字段毫无反馈。
          selected: settings.nightMode
              ? config.backgroundColorNight
              : config.backgroundColor,
          onPick: (v) => _applyTheme(settings.nightMode
              ? config.copyWith(backgroundColorNight: v)
              : config.copyWith(backgroundColor: v)),
        ),
        const SizedBox(height: 10),
        _sectionTitle('文字色'),
        _colorRow(
          colors: _textColors,
          selected: settings.nightMode
              ? config.textColorNight
              : config.textColor,
          onPick: (v) => _applyTheme(settings.nightMode
              ? config.copyWith(textColorNight: v)
              : config.copyWith(textColor: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('夜间配色'),
          subtitle: const Text('页眉页脚与正文同时切换夜间色'),
          value: settings.nightMode,
          onChanged: (v) => _apply(settings.copyWith(nightMode: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('朗读高亮'),
          subtitle: const Text('听书时高亮正在朗读的段落'),
          value: AppScope.read(context).settings.listenHighlight,
          onChanged: (v) =>
              AppScope.read(context).settings.listenHighlight = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('朗读自动跟随'),
          subtitle: const Text('朗读推进时自动翻页或滚动到当前段'),
          value: AppScope.read(context).settings.listenFollow,
          onChanged: (v) => AppScope.read(context).settings.listenFollow = v,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('页眉分隔线'),
          value: config.showHeaderLine,
          onChanged: (v) => _applyTheme(config.copyWith(showHeaderLine: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('页脚分隔线'),
          value: config.showFooterLine,
          onChanged: (v) => _applyTheme(config.copyWith(showFooterLine: v)),
        ),
      ],
    );
  }

  Widget _colorRow({
    required List<int> colors,
    required int selected,
    required ValueChanged<int> onPick,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final color in colors)
          InkWell(
            onTap: () => onPick(color),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: Color(color),
                shape: BoxShape.circle,
                border: Border.all(
                  width: 2,
                  color: color == selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).dividerColor,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _pickBackgroundFile() async {
    const group = XTypeGroup(
      label: '图片',
      extensions: <String>['jpg', 'jpeg', 'png', 'webp'],
    );
    final file = await openFile(acceptedTypeGroups: const [group]);
    if (file == null) return;
    await _applyTheme(
      _settings.activeThemeConfig.copyWith(backgroundFile: file.path),
    );
  }

  Future<void> _duplicateTheme() async {
    final settings = _settings;
    final source = settings.activeThemeConfig;
    final copy = ReaderThemeConfig(
      id: 'theme_${DateTime.now().millisecondsSinceEpoch}',
      name: '${source.name} 副本',
      typography: source.typography,
      backgroundKind: source.backgroundKind,
      backgroundColor: source.backgroundColor,
      textColor: source.textColor,
      backgroundColorNight: source.backgroundColorNight,
      textColorNight: source.textColorNight,
      backgroundAsset: source.backgroundAsset,
      backgroundFile: source.backgroundFile,
      backgroundAlpha: source.backgroundAlpha,
      darkStatusIcon: source.darkStatusIcon,
      headerLeft: source.headerLeft,
      headerMiddle: source.headerMiddle,
      headerRight: source.headerRight,
      footerLeft: source.footerLeft,
      footerMiddle: source.footerMiddle,
      footerRight: source.footerRight,
      headerCustomLeft: source.headerCustomLeft,
      headerCustomMiddle: source.headerCustomMiddle,
      headerCustomRight: source.headerCustomRight,
      footerCustomLeft: source.footerCustomLeft,
      footerCustomMiddle: source.footerCustomMiddle,
      footerCustomRight: source.footerCustomRight,
      showHeaderLine: source.showHeaderLine,
      showFooterLine: source.showFooterLine,
      headerMode: source.headerMode,
      footerMode: source.footerMode,
    );
    final themes = [...settings.effectiveThemes, copy];
    await _apply(
      settings.copyWith(themes: themes, activeTheme: themes.length - 1),
    );
  }

  Future<void> _renameTheme() async {
    final controller =
        TextEditingController(text: _settings.activeThemeConfig.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名主题'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: '名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _applyTheme(_settings.activeThemeConfig.copyWith(name: name));
  }

  Future<void> _deleteTheme() async {
    final settings = _settings;
    final themes = List<ReaderThemeConfig>.of(settings.effectiveThemes);
    if (themes.length <= 1) return;
    final index = settings.activeTheme.clamp(0, themes.length - 1);
    themes.removeAt(index);
    await _apply(
      settings.copyWith(
        themes: themes,
        activeTheme: index >= themes.length ? themes.length - 1 : index,
      ),
    );
  }

  // ---------------- 翻页 ----------------

  Widget _pagingTab() {
    final settings = _settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('阅读模式'),
        SegmentedButton<ReaderMode>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ReaderMode.scroll, label: Text('滚动')),
            ButtonSegment(value: ReaderMode.paged, label: Text('翻页')),
          ],
          selected: {settings.mode},
          onSelectionChanged: (values) =>
              _apply(settings.copyWith(mode: values.first)),
        ),
        const SizedBox(height: 14),
        _sectionTitle('翻页动画'),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final anim in ReaderPageAnim.values)
              ChoiceChip(
                label: Text(anim.label),
                selected: settings.anim == anim,
                onSelected: (_) => _apply(settings.copyWith(anim: anim)),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _sectionTitle('动画速度'),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('很快')),
            ButtonSegment(value: 1, label: Text('快')),
            ButtonSegment(value: 2, label: Text('标准')),
            ButtonSegment(value: 3, label: Text('慢')),
          ],
          selected: {settings.animSpeed},
          onSelectionChanged: (values) =>
              _apply(settings.copyWith(animSpeed: values.first)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('双页并排'),
          subtitle: const Text('横屏/平板一屏两页；宽度不足 600 自动单页'),
          value: settings.doublePage,
          onChanged: (v) => _apply(settings.copyWith(doublePage: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('翻页震动'),
          subtitle: const Text('每次翻页给一次轻触反馈'),
          value: settings.hapticOnTurn,
          onChanged: (v) => _apply(settings.copyWith(hapticOnTurn: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('翻页音效'),
          value: settings.soundOnTurn,
          onChanged: (v) => _apply(settings.copyWith(soundOnTurn: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('自动翻页'),
          subtitle: const Text('只在翻页模式生效'),
          value: settings.autoTurn,
          onChanged: (v) => _apply(settings.copyWith(autoTurn: v)),
        ),
        if (settings.autoTurn)
          _slider(
            label: '翻页间隔',
            value: settings.autoIntervalSec.toDouble(),
            min: 15,
            max: 300,
            divisions: 19,
            display: '${settings.autoIntervalSec}s',
            onChanged: (v) => _apply(
              settings.copyWith(autoIntervalSec: v.round()),
            ),
          ),
      ],
    );
  }

  // ---------------- 交互 ----------------

  Widget _interactionTab() {
    final settings = _settings;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            showDragHandle: true,
            isScrollControlled: true,
            builder: (_) => ReaderClickZoneEditor(store: widget.store),
          ),
          icon: const Icon(Icons.touch_app_outlined),
          label: const Text('点击区域（3×3 九宫格）'),
        ),
        const SizedBox(height: 8),
        _slider(
          label: '边缘内缩',
          value: settings.zoneLayout.edgeInset,
          min: 0,
          max: 64,
          divisions: 16,
          display: '${settings.zoneLayout.edgeInset.round()}px',
          onChanged: (v) => _apply(
            settings.copyWith(
              zoneLayout: settings.zoneLayout.copyWith(edgeInset: v),
            ),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('手势左右滑动翻页'),
          value: settings.swipeEnabled,
          onChanged: (v) => _apply(settings.copyWith(swipeEnabled: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('音量键翻页'),
          subtitle: const Text('桌面端与外接键盘生效'),
          value: settings.volumeKeyPage,
          onChanged: (v) => _apply(settings.copyWith(volumeKeyPage: v)),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('阅读时常亮'),
          value: settings.keepAwake,
          onChanged: (v) {
            if (v) {
              WakelockPlus.enable();
            } else {
              WakelockPlus.disable();
            }
            _apply(settings.copyWith(keepAwake: v));
          },
        ),
        _slider(
          label: '屏幕亮度',
          value: settings.brightness < 0 ? 0.6 : settings.brightness,
          min: 0.05,
          max: 1,
          divisions: 19,
          display: settings.brightness < 0
              ? '跟随系统'
              : '${(settings.brightness * 100).round()}%',
          onChanged: (v) {
            // Linux 等平台没有亮度插件，失败时不打断阅读。
            ScreenBrightness()
                .setApplicationScreenBrightness(v)
                .catchError((_) {});
            _apply(settings.copyWith(brightness: v));
          },
        ),
        Row(
          children: [
            const Text('恢复跟随系统亮度'),
            const Spacer(),
            TextButton(
              onPressed: () {
                ScreenBrightness().resetApplicationScreenBrightness();
                _apply(settings.copyWith(brightness: -1));
              },
              child: const Text('恢复'),
            ),
          ],
        ),
      ],
    );
  }

  // ---------------- 更多 ----------------

  Widget _moreTab() {
    final settings = _settings;
    final config = settings.activeThemeConfig;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('简繁转换'),
        SegmentedButton<ChineseConvert>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: ChineseConvert.off, label: Text('不转')),
            ButtonSegment(value: ChineseConvert.t2s, label: Text('繁→简')),
            ButtonSegment(value: ChineseConvert.s2t, label: Text('简→繁')),
          ],
          selected: {settings.convert},
          onSelectionChanged: (values) =>
              _apply(settings.copyWith(convert: values.first)),
        ),
        const Divider(height: 24),
        _sectionTitle('页眉'),
        _tipRow(
          header: true,
          values: [config.headerLeft, config.headerMiddle, config.headerRight],
          custom: [
            config.headerCustomLeft,
            config.headerCustomMiddle,
            config.headerCustomRight,
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('显示方式'),
            const Spacer(),
            SegmentedButton<ReaderTipMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: ReaderTipMode.followMenu, label: Text('跟随菜单')),
                ButtonSegment(value: ReaderTipMode.always, label: Text('常显')),
                ButtonSegment(value: ReaderTipMode.never, label: Text('常隐')),
              ],
              selected: {config.headerMode},
              onSelectionChanged: (values) =>
                  _applyTheme(config.copyWith(headerMode: values.first)),
            ),
          ],
        ),
        const Divider(height: 24),
        _sectionTitle('页脚'),
        _tipRow(
          header: false,
          values: [config.footerLeft, config.footerMiddle, config.footerRight],
          custom: [
            config.footerCustomLeft,
            config.footerCustomMiddle,
            config.footerCustomRight,
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            const Text('显示方式'),
            const Spacer(),
            SegmentedButton<ReaderTipMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: ReaderTipMode.followMenu, label: Text('跟随菜单')),
                ButtonSegment(value: ReaderTipMode.always, label: Text('常显')),
                ButtonSegment(value: ReaderTipMode.never, label: Text('常隐')),
              ],
              selected: {config.footerMode},
              onSelectionChanged: (values) =>
                  _applyTheme(config.copyWith(footerMode: values.first)),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '自定义模板可用变量：{BookName} {ChapterTitle} {Time} {BatteryPercent} '
          '{ChapterIndex} {ChapterSize} {PageIndex} {PageSize} '
          '{PageRemaining} {ReadProgress} {FullPageIndex} {FullPageSize}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const Divider(height: 24),
        _sectionTitle('恢复'),
        OutlinedButton.icon(
          onPressed: () => _apply(const ReaderSettings()),
          icon: const Icon(Icons.restart_alt),
          label: const Text('恢复默认设置'),
        ),
      ],
    );
  }

  Widget _tipRow({
    required bool header,
    required List<ReaderTipValue> values,
    required List<String> custom,
  }) {
    final config = _settings.activeThemeConfig;
    return Column(
      children: [
        for (var slot = 0; slot < 3; slot++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                SizedBox(
                  width: 44,
                  child: Text(const ['左', '中', '右'][slot]),
                ),
                Expanded(
                  child: DropdownButton<ReaderTipValue>(
                    isExpanded: true,
                    value: values[slot],
                    items: [
                      for (final value in ReaderTipValue.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      var next = config;
                      if (header) {
                        next = switch (slot) {
                          0 => next.copyWith(headerLeft: value),
                          1 => next.copyWith(headerMiddle: value),
                          _ => next.copyWith(headerRight: value),
                        };
                      } else {
                        next = switch (slot) {
                          0 => next.copyWith(footerLeft: value),
                          1 => next.copyWith(footerMiddle: value),
                          _ => next.copyWith(footerRight: value),
                        };
                      }
                      _applyTheme(next);
                    },
                  ),
                ),
                if (values[slot] == ReaderTipValue.custom) ...[
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 130,
                    child: TextFormField(
                      initialValue: custom[slot],
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: '{PageIndex}',
                      ),
                      onFieldSubmitted: (text) {
                        var next = config;
                        if (header) {
                          next = switch (slot) {
                            0 => next.copyWith(headerCustomLeft: text),
                            1 => next.copyWith(headerCustomMiddle: text),
                            _ => next.copyWith(headerCustomRight: text),
                          };
                        } else {
                          next = switch (slot) {
                            0 => next.copyWith(footerCustomLeft: text),
                            1 => next.copyWith(footerCustomMiddle: text),
                            _ => next.copyWith(footerCustomRight: text),
                          };
                        }
                        _applyTheme(next);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  // ---------------- 通用 ----------------

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 2),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    final clamped = value.clamp(min, max);
    return Row(
      children: [
        SizedBox(width: 64, child: Text(label)),
        Expanded(
          child: Slider(
            value: clamped,
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 58,
          child: Text(display, textAlign: TextAlign.end),
        ),
      ],
    );
  }
}

/// 供阅读页读取的电量（页眉页脚 `{BatteryPercent}`）。
int? readerBatteryPercent() => BatteryLevelReader.read();
