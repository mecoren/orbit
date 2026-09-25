import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';

/// 底部导航栏（设计系统 v3：实色表面 + 上缘 1px 描边 + 五页签均分）
///
/// 对齐竞品主导航形态：页签均分整栏（末位固定「更多」动作页签，点击不切页
/// 而是弹出来源锚定面板——面板内是次级目的地），「新建」上收页面右下悬浮钮
/// （宿主 Scaffold 的 floatingActionButton，见 `home_shell.dart`）。
/// 页签选中态 = 主题强调色（图标 + 文字 + w600），未选中 = 次要文字色；
/// 页签可挂计数角标（红色小胶囊，<=0 不显示）。
class OrbitBottomNav extends StatefulWidget {
  const OrbitBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    this.moreTabIndex,
    this.onMoreTap,
    this.badges = const <int, int>{},
  });

  /// 栏体内容高度（不含底部手势区）
  static const double barHeight = 56;

  /// 页签（末位 [moreTabIndex] 为「更多」动作位，不参与路由切换）
  final List<OrbitBottomNavItem> items;

  /// 当前选中下标
  final int currentIndex;

  /// 页签点击（下标；「更多」位不走此回调）
  final ValueChanged<int> onTap;

  /// 「更多」动作位下标（null = 无动作位）
  final int? moreTabIndex;

  /// 「更多」位点击（参数 = 该页签的全局矩形，供来源锚定面板定位）
  final ValueChanged<Rect>? onMoreTap;

  /// 页签角标计数（下标 → 数量；<=0 不显示）
  final Map<int, int> badges;

  @override
  State<OrbitBottomNav> createState() => _OrbitBottomNavState();
}

class _OrbitBottomNavState extends State<OrbitBottomNav> {
  /// 「更多」页签的锚点 key：点击时读全局矩形给面板定位
  final GlobalKey _moreKey = GlobalKey();

  void _handleTap(int index) {
    if (index == widget.moreTabIndex) {
      HapticFeedback.selectionClick();
      final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.attached) {
        widget.onMoreTap?.call(box.localToGlobal(Offset.zero) & box.size);
      }
      return;
    }
    if (index != widget.currentIndex) HapticFeedback.selectionClick();
    widget.onTap(index);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: Container(
          height: OrbitBottomNav.barHeight,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.outline),
            ),
          ),
          child: Row(
            children: [
              for (var i = 0; i < widget.items.length; i++)
                Expanded(child: _buildTab(context, colors, i)),
            ],
          ),
        ),
      ),
    );
  }

  /// 页签：图标 + 文字纵向排布，整格可点（InkWell 水波溢出格内裁圆角）
  Widget _buildTab(BuildContext context, AppColorSet colors, int index) {
    final item = widget.items[index];
    final selected = index == widget.currentIndex;
    final color =
        selected ? OrbitAccents.themeAccent : colors.secondaryText;
    final badge = widget.badges[index] ?? 0;
    return InkWell(
      onTap: () => _handleTap(index),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        key: index == widget.moreTabIndex ? _moreKey : null,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(item.icon, size: AppDimens.iconSizeLg, color: color),
              // 角标贴图标右上角（允许溢出 Stack 绘制，不参与命中）
              if (badge > 0)
                Positioned(top: -5, right: -12, child: _buildBadge(badge)),
            ],
          ),
          const SizedBox(height: AppDimens.space2),
          Text(
            item.label,
            style: TextStyle(
              fontSize: 10,
              height: 1,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// 计数角标：红色胶囊（>99 折叠为 99+），白字加粗保对比度
  Widget _buildBadge(int n) {
    return Container(
      constraints: const BoxConstraints(minHeight: 14),
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: OrbitAccents.overdueRed,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        n > 99 ? '99+' : '$n',
        style: const TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
          color: Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}

/// 底部导航页签描述（图标 + 文案）
class OrbitBottomNavItem {
  const OrbitBottomNavItem({required this.icon, required this.label});

  final IconData icon;
  final String label;
}
