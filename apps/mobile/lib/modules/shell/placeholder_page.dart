import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/glass_fab.dart';
import '../../shared/widgets/liquid_glass_title_bar.dart';
import '../../shared/widgets/scroll_offset_listenable.dart';

/// Phase 3 占位页：验证设计系统装配（玻璃标题栏滚动渐显 + GlassFab + 双色板）
///
/// Phase 6 将由四屏链路真实页面替换。
class PlaceholderPage extends StatefulWidget {
  const PlaceholderPage({super.key, required this.label});

  final String label;

  @override
  State<PlaceholderPage> createState() => _PlaceholderPageState();
}

class _PlaceholderPageState extends State<PlaceholderPage> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Scaffold(
      body: Stack(
        children: [
          ListView.builder(
            controller: _scrollController,
            padding: EdgeInsets.only(
              top: MediaQuery.of(context).padding.top +
                  LiquidGlassTitleBar.rowHeight +
                  AppDimens.space16,
              bottom: AppDimens.gestureInsetFallback + AppDimens.space32,
            ),
            itemCount: 40,
            itemBuilder: (context, i) => ListTile(
              title: Text('${widget.label} 条目 $i'),
              subtitle: Text('副标题文本', style: TextStyle(color: colors.secondaryText)),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LiquidGlassTitleBar(
              title: widget.label,
              onBack: null,
              showBack: false,
              showMenu: true,
              scrollOffsetListenable: ScrollOffsetListenable(_scrollController),
              actions: [
                IconButton(
                  icon: const Icon(Icons.settings_rounded,
                      size: AppDimens.iconSizeMd),
                  onPressed: () {},
                ),
              ],
            ),
          ),
          Positioned(
            right: AppDimens.space16,
            bottom: AppDimens.gestureInsetFallback + AppDimens.space16,
            child: GlassFab(
              accentColor: OrbitAccents.themeAccent,
              onPressed: () {},
            ),
          ),
        ],
      ),
    );
  }
}
