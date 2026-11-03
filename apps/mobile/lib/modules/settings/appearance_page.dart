import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../services/appearance.dart';
import '../../shared/widgets/shadcn/orbit_arrow_tile.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../shared/widgets/shadcn/orbit_button.dart';
import '../../shared/widgets/shadcn/orbit_text_field.dart';
import '../../core/theme/icon_map.dart';
import '../../modules/todo/logic/task_logic.dart' show labelPaletteHexes;
import '../../shared/utils/hex_color.dart';

/// 外观设置页 /settings/appearance
///
/// 主题模式三态（跟随系统/浅色/深色）+ 字号三档（小/标准/大）+
/// 字重三档（常规/适中/加粗），全走 LocalPrefs 字符串读写，
/// 写后即时经 Appearance.revision 重建应用主题。
class AppearancePage extends StatefulWidget {
  const AppearancePage({super.key});

  @override
  State<AppearancePage> createState() => _AppearancePageState();
}

class _AppearancePageState extends State<AppearancePage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _pickTheme() async {
    await showSelectBottomSheet<String>(
      context,
      title: '主题模式',
      current: Appearance.themeValue(),
      items: const [
        SelectItem(value: 'system', label: '跟随系统'),
        SelectItem(value: 'light', label: '浅色'),
        SelectItem(value: 'dark', label: '深色'),
      ],
      onSelect: (v) async {
        await Appearance.setTheme(v);
        if (mounted) {
          setState(() {});
          WaitToast.success('主题已切换');
        }
      },
    );
  }

  Future<void> _pickFontSize() async {
    await showSelectBottomSheet<String>(
      context,
      title: '字号',
      current: Appearance.fontSizeValue(),
      items: const [
        SelectItem(value: 'small', label: '小'),
        SelectItem(value: 'standard', label: '标准'),
        SelectItem(value: 'large', label: '大'),
      ],
      onSelect: (v) async {
        await Appearance.setFontSize(v);
        if (mounted) {
          setState(() {});
          WaitToast.success('字号已切换');
        }
      },
    );
  }

  Future<void> _pickFontWeight() async {
    await showSelectBottomSheet<String>(
      context,
      title: '字重',
      current: Appearance.fontWeightValue(),
      items: const [
        SelectItem(value: 'regular', label: '常规'),
        SelectItem(value: 'medium', label: '适中'),
        SelectItem(value: 'bold', label: '加粗'),
      ],
      onSelect: (v) async {
        await Appearance.setFontWeight(v);
        if (mounted) {
          setState(() {});
          WaitToast.success('字重已切换');
        }
      },
    );
  }

  /// 强调色选择（#107）：10 色预设与桌面 PRESET_10 同源 + 自定义 #RRGGBB。
  /// 选中即落盘并 bump revision；待办复选框/图表色（todoAccent）不跟随。
  Future<void> _pickAccent() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => const _AccentPickerSheet(),
    );
    if (picked == null || !mounted) return;
    await Appearance.setAccent(picked);
    if (!mounted) return;
    setState(() {});
    WaitToast.success('强调色已更新');
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
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
                    // 四行统一走 miuix `MiuixArrowPreference`（HyperOS 标准
                    // 值行：左标题 / 右强调色值 / 右箭头），与设置页其余
                    // 值行同构（2026-11-03 收口，此前是手搓 14px 行）
                    OrbitArrowTile(
                      title: '主题模式',
                      value: Appearance.themeLabel(),
                      valueColor: OrbitAccents.themeAccent,
                      onClick: _pickTheme,
                    ),
                    OrbitArrowTile(
                      title: '字号',
                      value: Appearance.fontSizeLabel(),
                      valueColor: OrbitAccents.themeAccent,
                      onClick: _pickFontSize,
                    ),
                    OrbitArrowTile(
                      title: '字重',
                      value: Appearance.fontWeightLabel(),
                      valueColor: OrbitAccents.themeAccent,
                      onClick: _pickFontWeight,
                    ),
                    // #107：强调色（桌面早已有 10 色板 + 自定义，移动此前只能用默认蓝）
                    OrbitArrowTile(
                      title: '强调色',
                      value: colorToHex(OrbitAccents.themeAccent),
                      valueColor: OrbitAccents.themeAccent,
                      onClick: _pickAccent,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimens.cardGap),
              Text(
                '预览：字号与字重即时作用于全文，主题即时切换亮暗（默认跟随系统）。',
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
    );
  }

}

/// 强调色抽屉（#107）：10 色预设 + 自定义十六进制
///
/// 用 Material 底部抽屉（项目统一圆角口径 `showModalBottomSheet`），
/// 返回 `#RRGGBB`；预设值与桌面 `PRESET_10` 同源（[labelPaletteHexes]）。
class _AccentPickerSheet extends StatefulWidget {
  const _AccentPickerSheet();

  @override
  State<_AccentPickerSheet> createState() => _AccentPickerSheetState();
}

class _AccentPickerSheetState extends State<_AccentPickerSheet> {
  late final TextEditingController _hex = TextEditingController(
    text: colorToHex(OrbitAccents.themeAccent),
  );

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _applyHex() {
    final raw = _hex.text.trim();
    if (!RegExp(r'^#?[0-9a-fA-F]{6}$').hasMatch(raw)) {
      WaitToast.destructive('请输入 #RRGGBB 格式的颜色');
      return;
    }
    final normalized = raw.startsWith('#') ? raw.substring(1) : raw;
    Navigator.of(context).pop('#${normalized.toUpperCase()}');
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final current = colorToHex(OrbitAccents.themeAccent);
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: AppDimens.pageInline,
            right: AppDimens.pageInline,
            top: AppDimens.space16,
            bottom: MediaQuery.viewInsetsOf(context).bottom + AppDimens.space16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '强调色',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: colors.bodyText,
                ),
              ),
              const SizedBox(height: AppDimens.space4),
              Text(
                '只作用于 Fab、载入指示与链接等全局强调色；'
                '任务复选框与图表色保持独立。',
                style: TextStyle(fontSize: 12, color: colors.secondaryText),
              ),
              const SizedBox(height: AppDimens.space16),
              Wrap(
                spacing: AppDimens.space12,
                runSpacing: AppDimens.space12,
                children: [
                  for (final hex in labelPaletteHexes)
                    _swatch(colors, hex, current),
                ],
              ),
              const SizedBox(height: AppDimens.space16),
              Row(
                children: [
                  Expanded(
                    child: OrbitTextField(
                      controller: _hex,
                      textCapitalization: TextCapitalization.characters,
                      label: '自定义 #RRGGBB',
                      onSubmitted: (_) => _applyHex(),
                    ),
                  ),
                  const SizedBox(width: AppDimens.space8),
                  OrbitButton.primary(onPressed: _applyHex, child: const Text('应用')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _swatch(AppColorSet colors, String hex, String current) {
    final selected = current.toUpperCase() == hex.toUpperCase();
    return InkWell(
      borderRadius: BorderRadius.circular(24),
      onTap: () => Navigator.of(context).pop(hex),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: hexToColor(hex, fallback: OrbitAccents.defaultThemeAccent),
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: colors.bodyText, width: 2)
              : null,
        ),
        child: selected
            ? const Icon(OrbitIcons.check, size: 20, color: Colors.white)
            : null,
      ),
    );
  }
}

