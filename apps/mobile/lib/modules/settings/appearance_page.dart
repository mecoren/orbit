import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../services/appearance.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';
import '../../shared/widgets/select_bottom_sheet.dart';
import '../../shared/widgets/wait_toast.dart';

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
            padding: const EdgeInsets.fromLTRB(
              AppDimens.space16,
              96,
              AppDimens.space16,
              AppDimens.space24,
            ),
            children: [
              ListTile(
                title: const Text('主题模式'),
                subtitle: Text(Appearance.themeLabel()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickTheme,
              ),
              ListTile(
                title: const Text('字号'),
                subtitle: Text(Appearance.fontSizeLabel()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickFontSize,
              ),
              ListTile(
                title: const Text('字重'),
                subtitle: Text(Appearance.fontWeightLabel()),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _pickFontWeight,
              ),
              const SizedBox(height: AppDimens.space12),
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
            child: LiquidGlassTitleBar(
              title: '外观',
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
            ),
          ),
        ],
      ),
    );
  }
}
