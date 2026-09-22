import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';

/// 页头（设计系�?v3：替换原「液态玻璃标题栏」）
///
/// **为什么改�?*：旧类名 `OrbitPageHeader` 与实现的玻璃配方（BackdropFilter +
/// 渐变 tint + 滚动驱动模糊渐显）强绑定；v3 已删除玻璃三件套，标题栏改为
/// 「实色表�?+ 底边 1px 描边定界」的 shadcn 语言，名称必须同步改�?
/// 否则名实不符�?
///
/// 布局口径**逐像素沿用旧实现**（只换表面材质，不换信息层级）：
/// `[返回/菜单�?| leading 插槽] [标题] ... [actions 插槽 (+功能�?]`�?
/// 行高 [rowHeight] = [AppDimens.titleBarHeight]，水平内边距 [AppDimens.space16]�?
/// 标题走设计系�?`titleLarge` 字阶、左对齐、单行省略�?
///
/// 删除的玻璃参数：`blur` / `maxSigma` / `backgroundColor` / `showHighlightLine` /
/// `scrollOffsetListenable` / `blurFadeDistance`——滚动驱动模糊渐显随玻璃层一并移除，
/// 页头恒为实色（滚动时不再有材质变化）�?
class OrbitPageHeader extends StatelessWidget implements PreferredSizeWidget {
  const OrbitPageHeader({
    super.key,
    // 左侧导航
    this.onBack,
    this.onMenuTap,
    this.showBack = true,
    this.showMenu = false,
    // 标题
    this.title,
    this.titleWidget,
    this.leading,
    // 功能�?
    this.actions,
  });

  /// 行高（页面内容区让位基准；与�?`OrbitPageHeader.rowHeight` 同值同义）
  static const double rowHeight = AppDimens.titleBarHeight;

  /// 返回回调；为 null 时默�?`Navigator.maybePop`
  final VoidCallback? onBack;

  /// 菜单键回调（showMenu 优先�?showBack�?
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;

  /// 纯文本标�?
  final String? title;

  /// 自定义标题（�?[title] 二选一，优先）
  final Widget? titleWidget;

  /// 无返�?菜单键时的左槽位（如首页的同步状态按钮）
  final Widget? leading;

  /// 尾随动作插槽（多个自由控件）
  final List<Widget>? actions;

  @override
  Size get preferredSize => const Size.fromHeight(rowHeight);

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Material(
      color: colors.surface,
      // 状态栏避让：表面铺满状态栏区域（同页头色，与页头连成一片不露页面底色），
      // 标题行整体下移状态栏高度。因此页头实际占高 = `状态栏 + rowHeight`，
      // 与各页内容区让位口径一致（SafeArea 内空出 rowHeight，或滚动区 padding
      // 手动加 `MediaQuery.padding.top + rowHeight`）——缺少这层避让时标题会被
      // 状态栏压到顶部（页头自身却只有 56px，视觉上「标题太靠上」）
      child: SafeArea(
        bottom: false,
        child: Container(
          height: rowHeight,
          padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.outline, width: 1),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ?_buildLeading(context, colors),
              Expanded(child: _buildTitle(context, colors)),
              _buildTrailing(),
            ],
          ),
        ),
      ),
    );
  }

  Widget? _buildLeading(BuildContext context, AppColorSet colors) {
    if (showMenu) {
      return IconButton(
        tooltip: '菜单',
        padding: const EdgeInsets.only(right: AppDimens.space8),
        icon: Icon(
          OrbitIcons.menu,
          size: AppDimens.iconSizeLg,
          color: colors.titleText,
        ),
        onPressed: onMenuTap,
      );
    }
    if (showBack) {
      return IconButton(
        tooltip: '返回',
        padding: const EdgeInsets.only(right: AppDimens.space8),
        icon: Icon(
          OrbitIcons.back,
          size: AppDimens.iconSizeLg,
          color: colors.titleText,
        ),
        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
      );
    }
    return leading;
  }

  Widget _buildTitle(BuildContext context, AppColorSet colors) {
    return titleWidget ??
        Text(
          title ?? '',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: colors.titleText,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
  }

  Widget _buildTrailing() {
    if (actions == null || actions!.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: [...actions!]);
  }
}
