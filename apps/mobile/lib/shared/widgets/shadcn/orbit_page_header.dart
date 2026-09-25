import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';

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
    // 功能槽
    this.actions,
    // 完成进度线（0..1；null 不渲染）
    this.progress,
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

  /// 完成进度线（0..1，TickTick 列表页头语义）：落在页头底缘的 2px 主题色线，
  /// 覆在 1px 描边之上；null 不渲染。进度变化走隐式动画补间。
  final double? progress;

  @override
  Size get preferredSize => const Size.fromHeight(rowHeight);

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 实例字段进闭包前先落本地：Dart 流分析不提升成员字段可空性
    final headerProgress = progress;
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
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: colors.outline, width: 1),
            ),
          ),
          child: Stack(
            // passthrough：标题行保持满高（默认 loose 会把 Row 收缩到内容高，
            // 标题垂直居中基准整体上移——页头避让几何测试拦下的回归）
            fit: StackFit.passthrough,
            children: [
              // 内边距挂在标题行上而不是 Container 上：进度线要通栏（与它
              // 覆盖的 1px 描边同宽），收进 padding 会两头各缩 16px
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: AppDimens.space16),
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
