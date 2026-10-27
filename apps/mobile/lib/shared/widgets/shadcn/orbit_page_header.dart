import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';
import 'orbit_progressive_blur.dart';

/// 页头（渐进磨砂玻璃表面）
///
/// 布局口径逐像素沿用 v3（只换表面材质，不换信息层级）：
/// `[返回/菜单键 | leading 插槽] [标题] ... [actions 插槽]`；
/// 行高 [rowHeight] = [AppDimens.titleBarHeight]，水平内边距 [AppDimens.space16]；
/// 标题 titleLarge 字阶、左对齐、单行省略。
///
/// 表面材质（三层 Stack）：
/// ```
/// ├─ 层 A：OrbitProgressiveBlur —— 顶强底弱的磨砂 + surface tint 渐变
/// ├─ 层 B：主题色玻璃渐变（顶强底弱，白底页面也有一条可见的头部质感）
/// └─ 层 C：SafeArea + 标题行（Material 透明承载水波，不挡下方模糊）
/// ```
///
/// 不画底边分隔线：磨砂 + tint 渐变已经能交代页头边界，再加实线会像
/// 「老式 AppBar 下边框」；进度线（传 [progress] 时）仍落在页头底缘。
///
/// 玻璃层要求页面内容从页头下方滚过才能看到磨砂（各页滚动区顶部留白
/// 已按 `状态栏 + rowHeight` 计入，滚动中内容自然进入页头背后）。
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
    // 功能槽
    this.actions,
    // 完成进度线（0..1；null 不渲染）
    this.progress,
  });

  /// 行高（页面内容区让位基准；与各页 `OrbitPageHeader.rowHeight` 同值同义）
  static const double rowHeight = AppDimens.titleBarHeight;

  /// 玻璃模糊强度（逻辑像素 sigma）：与移动端设计基准同档，改这里即全站页头同步
  static const double glassSigma = 5;

  /// 返回回调；为 null 时默认 `Navigator.maybePop`
  final VoidCallback? onBack;

  /// 菜单键回调（showMenu 优先于 showBack）
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;

  /// 纯文本标题
  final String? title;

  /// 自定义标题（与 [title] 二选一，优先）
  final Widget? titleWidget;

  /// 无返回/菜单键时的左槽位（如首页的同步状态按钮）
  final Widget? leading;

  /// 尾随动作插槽（多个自由控件）
  final List<Widget>? actions;

  /// 完成进度线（0..1）：落在页头底缘的 2px 主题色线，
  /// 覆在 1px 描边之上；null 不渲染。进度变化走隐式动画补间。
  final double? progress;

  @override
  Size get preferredSize => const Size.fromHeight(rowHeight);

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // 实例字段进闭包前先落本地：Dart 流分析不提升成员字段可空性
    final headerProgress = progress;
    return Stack(
      children: [
        // 层 A：渐进磨砂 + surface tint（铺满状态栏区域，与页头连成一片）
        const Positioned.fill(
          child: OrbitProgressiveBlur(sigma: glassSigma),
        ),
        // 层 B：主题色玻璃渐变（顶强底弱）。白底页面下方没有内容滚过时，
        // 模糊后仍是纯色，白 tint 叠白底不可见——这层才是常驻的玻璃质感来源；
        // 有内容滚过时同时给磨砂加一层品牌色调。
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  OrbitAccents.themeAccent
                      .withValues(alpha: isDark ? 0.10 : 0.08),
                  OrbitAccents.themeAccent.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
        // 层 C：标题行（Material 透明：只承载水波，不画底色/挡住下方模糊）。
        // 状态栏避让：表面铺满状态栏区域，标题行整体下移状态栏高度，
        // 因此页头实际占高 = `状态栏 + rowHeight`，与各页内容区让位口径一致。
        SafeArea(
          bottom: false,
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: double.infinity,
              height: rowHeight,
              child: Stack(
                // passthrough：标题行保持满高（默认 loose 会把 Row 收缩到内容高，
                // 标题垂直居中基准整体上移——页头避让几何测试拦下的回归）
                fit: StackFit.passthrough,
                children: [
                  // 内边距挂在标题行上而不是外层：进度线要通栏，
                  // 收进 padding 会两头各缩 16px
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppDimens.space16,
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
                  // 进度线：钳在 [0,1] 防脏入参溢出；TweenAnimationBuilder 隐式
                  // 补间进度变化（首次构建 begin=end，不播从 0 涨过来的入场动画）
                  if (headerProgress != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(end: headerProgress.clamp(0.0, 1.0)),
                        duration: AppMotion.normal,
                        curve: AppMotion.standard,
                        builder: (context, value, _) => FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: value,
                          child: Container(
                            height: 2,
                            color: OrbitAccents.themeAccent,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
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
