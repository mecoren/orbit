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
import '../../shared/widgets/shadcn/orbit_glass_surface.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_select_popup.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';

/// 外观设置页 /settings/appearance
///
/// 页面结构与 flutter_miuix `example/lib/showcase/menus.dart` 的「下拉偏好
/// DropdownPreference」分区**逐像素同构**（2026-11-04 对齐）：
/// - 分组标题走库内 [MiuixSmallTitle]（卡外小标题，28×8 内边距）；
/// - 卡体 = `Padding(h:12)` + [MiuixCard]（insideMargin 归零，行自带内边距），
///   行间 [MiuixHorizontalDivider] 左缩进 56（示例 [IndentDivider] 同款）；
/// - 行走库内 [MiuixWindowDropdownPreference]，insideMargin 16×14 与示例
///   `_itemMargin` 同值，标题 + 摘要 → 尾随当前值 + 上下双箭头，点行就地
///   展开库内下拉弹层，当前档转主题色并打勾。
///
/// **为什么是 Window 变体而非 Overlay 变体**：Overlay 变体的弹层注册到
/// `MiuixPopupScope`/`MiuixPopupHost`，本壳（与示例 app 不同）没有装配该
/// 宿主，弹层会落进进程级 fallback 注册表而无人渲染；Window 变体直接挂根
/// Overlay（`OverlayEntry`），自带点外部/返回键收起，观感与 Overlay 变体
/// 逐像素一致（示例里两者本就同款，仅挂载层不同）。
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

  /// 档位键 → items 下标；脏数据（不在档位表里）回 0
  static int _indexOf(List<(String, String)> options, String value) {
    final index = options.indexWhere((o) => o.$1 == value);
    return index < 0 ? 0 : index;
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

  /// 强调色弹层项的前置图标位：语义图标优先，其次 12px 色点
  /// （库内图标格最小 26 见方并自带 12 尾距，这里只给内容）
  Widget? _accentLeading(SelectItem<String> item) {
    if (item.icon != null) {
      return Icon(item.icon, size: 20, color: item.iconColor);
    }
    if (item.colorDot != null) {
      return SizedBox(
        width: 24,
        height: 24,
        child: Center(
          child: Container(
            width: AppDimens.colorDotSize,
            height: AppDimens.colorDotSize,
            decoration: BoxDecoration(
              color: item.colorDot,
              shape: BoxShape.circle,
            ),
          ),
        ),
      );
    }
    return null;
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
                        MiuixWindowDropdownPreference(
                          title: '主题模式',
                          summary: '亮暗随系统或手动指定',
                          items: [
                            for (final o in _themeOptions) o.$2,
                          ],
                          selectedIndex: _indexOf(
                            _themeOptions,
                            Appearance.themeValue(),
                          ),
                          insideMargin: _itemMargin,
                          onSelectedIndexChange: (i) =>
                              _pickTheme(_themeOptions[i].$1),
                        ),
                        const _IndentDivider(),
                        MiuixWindowDropdownPreference(
                          title: '字号',
                          summary: '全文文本缩放档位',
                          items: [
                            for (final o in _fontSizeOptions) o.$2,
                          ],
                          selectedIndex: _indexOf(
                            _fontSizeOptions,
                            Appearance.fontSizeValue(),
                          ),
                          insideMargin: _itemMargin,
                          onSelectedIndexChange: (i) =>
                              _pickFontSize(_fontSizeOptions[i].$1),
                        ),
                        const _IndentDivider(),
                        MiuixWindowDropdownPreference(
                          title: '字重',
                          summary: '标题与正文的笔画粗细',
                          items: [
                            for (final o in _fontWeightOptions) o.$2,
                          ],
                          selectedIndex: _indexOf(
                            _fontWeightOptions,
                            Appearance.fontWeightValue(),
                          ),
                          insideMargin: _itemMargin,
                          onSelectedIndexChange: (i) =>
                              _pickFontWeight(_fontWeightOptions[i].$1),
                        ),
                        const _IndentDivider(),
                        // 桌面早已有 10 色板 + 自定义，移动此前只能用默认蓝；
                        // 逐项带色点/图标走 entry 构造（选中态与点击逐项挂）
                        MiuixWindowDropdownPreference.entry(
                          title: '强调色',
                          summary: 'Fab、载入指示与链接',
                          entry: MiuixDropdownEntry(
                            items: [
                              for (final item in accentItems)
                                MiuixDropdownItem(
                                  text: item.label,
                                  icon: _accentLeading(item),
                                  selected: item.value == accentHex,
                                  onClick: () => _pickAccent(item.value),
                                ),
                            ],
                          ),
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
