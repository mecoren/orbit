import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/icon_map.dart';
import '../../core/theme/orbit_accents.dart';
import '../../modules/todo/logic/task_logic.dart' show labelPaletteHexes;
import '../../services/appearance.dart';
import '../../shared/utils/hex_color.dart';
import '../../shared/widgets/shadcn/orbit_color_picker.dart';
import '../../shared/widgets/shadcn/orbit_dropdown_tile.dart';
import '../../shared/widgets/shadcn/orbit_glass_surface.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_select_popup.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';

/// 外观设置页 /settings/appearance
///
/// 四行统一走 [OrbitDropdownTile]（miuix 下拉偏好口径）：标题 + 摘要 → 尾随
/// 当前值 + 上下双箭头，点行**就地**弹出贴着本行的 OS4 玻璃下拉面板（库内
/// [MiuixGlassDropdownPopup]），当前档在面板里转强调色并打勾（不再用
/// 「右箭头」——那是跳页语义，不是选项切换）。
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
    // 根级推入页取不到壳层 OrbitGlassScope：本页自建采样器，下拉弹层才有
    // 真玻璃（否则库内无快照分支退成实色白卡）
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
                left: AppDimens.pageInline,
                right: AppDimens.pageInline,
                bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
              ),
              children: [
                SectionCard(
                  title: '外观',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OrbitDropdownTile<String>(
                        title: '主题模式',
                        summary: '亮暗随系统或手动指定',
                        items: const [
                          SelectItem(value: 'system', label: '跟随系统'),
                          SelectItem(value: 'light', label: '浅色'),
                          SelectItem(value: 'dark', label: '深色'),
                        ],
                        current: Appearance.themeValue(),
                        onSelect: _pickTheme,
                      ),
                      OrbitDropdownTile<String>(
                        title: '字号',
                        summary: '全文文本缩放档位',
                        items: const [
                          SelectItem(value: 'small', label: '小'),
                          SelectItem(value: 'standard', label: '标准'),
                          SelectItem(value: 'large', label: '大'),
                        ],
                        current: Appearance.fontSizeValue(),
                        onSelect: _pickFontSize,
                      ),
                      OrbitDropdownTile<String>(
                        title: '字重',
                        summary: '标题与正文的笔画粗细',
                        items: const [
                          SelectItem(value: 'regular', label: '常规'),
                          SelectItem(value: 'medium', label: '适中'),
                          SelectItem(value: 'bold', label: '加粗'),
                        ],
                        current: Appearance.fontWeightValue(),
                        onSelect: _pickFontWeight,
                      ),
                      // 桌面早已有 10 色板 + 自定义，移动此前只能用默认蓝
                      OrbitDropdownTile<String>(
                        title: '强调色',
                        summary: 'Fab、载入指示与链接',
                        items: accentItems,
                        current: accentHex,
                        onSelect: _pickAccent,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: AppDimens.cardGap),
                Text(
                  '预览：字号与字重即时作用于全文，主题即时切换亮暗'
                  '（默认跟随系统）。',
                  style: TextStyle(fontSize: 12, color: colors.secondaryText),
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
