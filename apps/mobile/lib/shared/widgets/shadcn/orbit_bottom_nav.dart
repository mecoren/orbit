import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';
import 'orbit_fab.dart';

/// 底部导航栏（设计系统 v3：实色表面 + 上缘 1px 描边 + 中央主操作钮）
///
/// 结构：中央添加钮两侧各两个页签，主导航与「新建」收进同一条拇指区栏位，
/// 页面右下不再另设悬浮钮。页签选中态 = 主题强调色（图标 + 文字 + w600），
/// 未选中 = 次要文字色；页签可挂计数角标（红色小胶囊，<=0 不显示）。
/// 中央添加钮凸出栏顶 [addOverhang]（带投影的主操作视觉），点击/长按回调
/// 由宿主装配（落点上下文见 `logic/quick_add_context.dart`）。
class OrbitBottomNav extends StatelessWidget {
  const OrbitBottomNav({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onTap,
    required this.onAddTap,
    this.onAddLongPress,
    this.badges = const <int, int>{},
  });

  /// 中央添加钮凸出栏顶的距离
  static const double addOverhang = 14;

  /// 栏体内容高度（不含底部手势区）
  static const double barHeight = 56;

  /// 页签（恒 4 个：中央添加钮两侧各两个）
  final List<OrbitBottomNavItem> items;

  /// 当前选中下标
  final int currentIndex;

  /// 页签点击（下标）
  final ValueChanged<int> onTap;

  /// 中央添加钮点击 / 长按（长按可空，无模板等次级语义时不传）
  final VoidCallback onAddTap;
  final VoidCallback? onAddLongPress;

  /// 页签角标计数（下标 → 数量；<=0 不显示）
  final Map<int, int> badges;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Material(
      color: colors.surface,
      child: SafeArea(
        top: false,
        child: Container(
          height: barHeight,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(color: colors.outline),
            ),
          ),
          child: Row(
            children: [
              // 中央添加钮固定插在第 3 个页签之前（4 页签的居中位）
              for (var i = 0; i < items.length; i++) ...[
                if (i == 2) _buildAddButton(colors),
                Expanded(child: _buildTab(context, colors, i)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 页签：图标 + 文字纵向排布，整格可点（InkWell 水波溢出格内裁圆角）
  Widget _buildTab(BuildContext context, AppColorSet colors, int index) {
    final item = items[index];
    final selected = index == currentIndex;
    final color =
        selected ? OrbitAccents.themeAccent : colors.secondaryText;
    final badge = badges[index] ?? 0;
    return InkWell(
      onTap: () {
        if (!selected) HapticFeedback.selectionClick();
        onTap(index);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
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

  /// 中央添加钮：48px 圆钮凸出栏顶，主题强调色填充 + 白色加号
  Widget _buildAddButton(AppColorSet colors) {
    return SizedBox(
      width: 72,
      height: barHeight,
      child: Center(
        child: Transform.translate(
          offset: const Offset(0, -addOverhang),
          child: OrbitFab(
            dimension: 48,
            accentColor: OrbitAccents.themeAccent,
            onPressed: onAddTap,
            onLongPress: onAddLongPress,
          ),
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
