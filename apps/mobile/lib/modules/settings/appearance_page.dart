import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../modules/todo/logic/task_logic.dart' show labelPaletteHexes;
import '../../services/appearance.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_color_picker.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_preference.dart';
import '../../shared/widgets/shadcn/orbit_glass_surface.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';

/// 外观设置页 /settings/appearance
///
/// 页面结构与 flutter_miuix `example/lib/showcase/menus.dart` 的「下拉偏好
/// DropdownPreference」分区**逐像素同构**（2026-11-04 对齐）：
/// - 分组标题走库内 [MiuixSmallTitle]（卡外小标题，28×8 内边距）；
/// - 卡体 = `Padding(h:12)` + [MiuixCard]（insideMargin 归零，行自带内边距），
///   行间 [MiuixHorizontalDivider] 左缩进 56（示例 [IndentDivider] 同款）；
/// - 行走 [OrbitDropdownPreference]，insideMargin 16×14 与示例 `_itemMargin`
///   同值，标题 + 摘要 → 尾随当前值 + 上下双箭头，点行就地展开弹层。
///
/// **弹层口径（2026-11-05 起）**：不再直用库内 `MiuixWindowDropdownPreference`
/// （白卡 + `MiuixDropdownImpl` 行），统一走 [OrbitDropdownPreference] 的
/// 玻璃菜单承载——与任务列表页头 ⋮ 菜单同一套 24 圆角玻璃卡 +
/// `MiuixGlassPopupItem` 行（44 行高、24 图标位、选中强调色打勾）。
///
/// 主题三态（跟随系统/浅色/深色）+ 字号三档（小/标准/大）+ 字重三档
/// （常规/适中/加粗）+ 强调色（10 色预设 + 自定义取色）全走 LocalPrefs
/// 字符串读写，写后即时经 [Appearance.revision] 重建应用主题。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  final _scrollController = ScrollController();

  /// 强调色「自定义…」项的哨兵值（真实值都是 `#RRGGBB`，不会撞）
  static const String _customAccent = '__custom__';

  /// 行内边距：与示例 menus.dart 的 `_itemMargin` 同值
  static const EdgeInsets _itemMargin = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 14,
  );

  /// 三档选项（档位键 + 中文标签）：下拉 items 用标签，选中回调换算回档位键
  static const List<(String, String)> _themeOptions = [
    ('system', '跟随系统'),
    ('light', '浅色'),
    ('dark', '深色'),
  ];
  static const List<(String, String)> _fontSizeOptions = [
    ('small', '小'),
    ('standard', '标准'),
    ('large', '大'),
  ];
  static const List<(String, String)> _fontWeightOptions = [
    ('regular', '常规'),
    ('medium', '适中'),
    ('bold', '加粗'),
  ];

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickTheme(String value) async {
    await Appearance.setTheme(value);
    _afterWrite('主题已切换');
  }

  Future<void> _pickFontSize(String value) async {
    await Appearance.setFontSize(value);
    _afterWrite('字号已切换');
  }

  Future<void> _pickFontWeight(String value) async {
    await Appearance.setFontWeight(value);
    _afterWrite('字重已切换');
  }

  /// 强调色：预设直接落盘；「自定义…」转 [showOrbitColorPickerSheet]
  /// （HSV 三滑杆 + HEX 精确输入，与项目/标签取色同源）。
  Future<void> _pickAccent(String value) async {
    if (value == _customAccent) {
      final picked = await showOrbitColorPickerSheet(
        context,
        initial: OrbitAccents.themeAccent,
      );
      if (picked == null || !mounted) return;
      await Appearance.setAccent(colorToHex(picked));
    } else {
      await Appearance.setAccent(value);
    }
    _afterWrite('强调色已更新');
  }

  /// 偏好已落盘（revision 已 bump，根级重建由 app.dart 监听）→ 本页刷新尾随值
  void _afterWrite(String message) {
    if (!mounted) return;
    setState(() {});
    WaitToast.success(message);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accentHex = colorToHex(OrbitAccents.themeAccent);
    // 当前色若不在预设板里（默认 #4E8CFF 就不在）补一行「当前」：否则尾随
    // 值取不到文案、弹层里也一项都不打勾
    final accentItems = <SelectItem<String>>[
      if (!labelPaletteHexes.contains(accentHex))
        SelectItem(
          value: accentHex,
          label: accentHex,
          colorDot: hexToColor(accentHex),
        ),
      // 预设 10 色 + 自定义入口（行首色点即语义，自定义行用铅笔图标区分）
      for (final hex in labelPaletteHexes)
        SelectItem(value: hex, label: hex, colorDot: hexToColor(hex)),
      const SelectItem(
        value: _customAccent,
        label: '自定义…',
        icon: OrbitIcons.edit,
      ),
    ];
    // 根级推入页取不到壳层 OrbitGlassScope：本页自建采样器，取色弹层
    // （OrbitGlassSheet）才有真玻璃
    return OrbitGlassPage(
      child: Scaffold(
        body: Stack(
          children: [
            ListView(
              controller: _scrollController,
              padding: EdgeInsets.only(
                top:
                    MediaQuery.of(context).padding.top +
                    OrbitPageHeader.rowHeight +
                    AppDimens.space16,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                // 示例同构：卡外小标题 + 卡体（h:12 外距、零内边距）
                const MiuixSmallTitle('外观'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: MiuixCard(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OrbitDropdownPreference<String>(
                          title: '主题模式',
                          summary: '亮暗随系统或手动指定',
                          items: [
                            for (final o in _themeOptions)
                              SelectItem(value: o.$1, label: o.$2),
                          ],
                          current: Appearance.themeValue(),
                          onSelect: _pickTheme,
                          insideMargin: _itemMargin,
                        ),
                        const _IndentDivider(),
                        OrbitDropdownPreference<String>(
                          title: '字号',
                          summary: '全文文本缩放档位',
                          items: [
                            for (final o in _fontSizeOptions)
                              SelectItem(value: o.$1, label: o.$2),
                          ],
                          current: Appearance.fontSizeValue(),
                          onSelect: _pickFontSize,
                          insideMargin: _itemMargin,
                        ),
                        const _IndentDivider(),
                        OrbitDropdownPreference<String>(
                          title: '字重',
                          summary: '标题与正文的笔画粗细',
                          items: [
                            for (final o in _fontWeightOptions)
                              SelectItem(value: o.$1, label: o.$2),
                          ],
                          current: Appearance.fontWeightValue(),
                          onSelect: _pickFontWeight,
                          insideMargin: _itemMargin,
                        ),
                        const _IndentDivider(),
                        // 桌面早已有 10 色板 + 自定义，移动此前只能用默认蓝；
                        // 逐项带色点/图标（行首信息位由原语按 SelectItem 渲染）
                        OrbitDropdownPreference<String>(
                          title: '强调色',
                          summary: 'Fab、载入指示与链接',
                          items: accentItems,
                          current: accentHex,
                          onSelect: _pickAccent,
                          insideMargin: _itemMargin,
                        ),
                      ],
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
                  child: Text(
                    '预览：字号与字重即时作用于全文，主题即时切换亮暗'
                    '（默认跟随系统）。',
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.secondaryText,
                    ),
                  ),
                ),
              ],
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: OrbitPageHeader(title: '外观'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 带左侧缩进的水平分隔线（flutter_miuix 示例 `IndentDivider` 同款：
/// 缩进 56 对齐列表项标题，避开起始图标槽位）
class _IndentDivider extends StatelessWidget {
  const _IndentDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 56),
      child: const MiuixHorizontalDivider(),
    );
  }
}
