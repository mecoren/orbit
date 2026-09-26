import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../services/appearance.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../shared/widgets/shadcn/orbit_section_card.dart';
import '../../shared/widgets/shadcn/orbit_select_sheet.dart';
import '../../shared/widgets/shadcn/orbit_toast.dart';
import '../../core/theme/icon_map.dart';

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
      current: Appearance.themeLabel(),
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
      current: Appearance.fontSizeLabel(),
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
      current: Appearance.fontWeightLabel(),
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

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: Stack(
        children: [
          ListView(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
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
                    _valueRow(
                      colors,
                      label: '主题模式',
                      value: Appearance.themeLabel(),
                      onTap: _pickTheme,
                    ),
                    _valueRow(
                      colors,
                      label: '字号',
                      value: Appearance.fontSizeLabel(),
                      onTap: _pickFontSize,
                    ),
                    _valueRow(
                      colors,
                      label: '字重',
                      value: Appearance.fontWeightLabel(),
                      onTap: _pickFontWeight,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppDimens.cardGap),
              Text(
                '预览：字号与字重即时作用于全文，主题即时切换亮暗（默认跟随系统）。',
                style: TextStyle(
                  fontSize: 12,
                  color: colors.secondaryText,
                ),
              ),
            ],
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '外观',
            ),
          ),
        ],
      ),
    );
  }

  /// 值行：左标签 + 右值（强调色）+ 右箭头，点行弹选择抽屉
  /// （形制与设置页「保留时间」行一致，热区同 `touchTarget`）
  Widget _valueRow(
    AppColorSet colors, {
    required String label,
    required String value,
    required VoidCallback onTap,
  }) =>
      InkWell(
        borderRadius: AppShapes.medium,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
          child: Row(
            children: [
              Text(label,
                  style: TextStyle(fontSize: 14, color: colors.bodyText)),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  fontSize: 14,
                  color: OrbitAccents.themeAccent,
                ),
              ),
              Icon(
                OrbitIcons.chevronRight,
                size: AppDimens.iconSizeMd,
                color: colors.secondaryText,
              ),
            ],
          ),
        ),
      );
}
