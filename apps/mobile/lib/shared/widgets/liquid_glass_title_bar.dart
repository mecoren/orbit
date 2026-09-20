import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import 'gradient_backdrop_filter.dart';

/// 液态玻璃单行标题栏（orbit 版）
///
/// 自 wait-home/mobile 的两行版裁剪而来，对齐 orbit docs/05 §三规格
/// （56px 单行；React 版 liquid-glass-title-bar.tsx 同构）：
///
/// ```
/// [返回/菜单键 | leading 插槽] [标题] ... [actions 插槽] [功能键(可选)]
/// ```
///
/// 玻璃配方（三件套）：
/// - 层 A：[GradientBackdropFilter]（σ20 + tint 渐变 0.20→0），
///   支持 [scrollOffsetListenable] 滚动驱动渐显——offset=0 时跳过
///   BackdropFilter 计算（性能纪律）；
/// - 层 B：内容行，始终完全显示；
/// - 层 C：底部 1px 五段 alpha 折射高光线，跟随模糊层同步显隐。
class LiquidGlassTitleBar extends StatelessWidget
    implements PreferredSizeWidget {
  const LiquidGlassTitleBar({
    super.key,
    // 左侧导航
    this.onBack,
    this.onMenuTap,
    this.showBack = true,
    this.showMenu = false,
    this.backIcon,
    // 标题
    this.title,
    this.titleWidget,
    this.leading,
    // 功能区
    this.actionsIcon,
    this.onActionsTap,
    this.actions,
    // 玻璃背景
    this.blur = true,
    this.maxSigma = AppDimens.blurTitleBarMax,
    this.backgroundColor,
    this.showHighlightLine = true,
    // 动态模糊：滚动偏移驱动渐显
    this.scrollOffsetListenable,
    this.blurFadeDistance = AppDimens.blurScrollFadeDistance,
  });

  // ===== 左侧导航 =====

  /// 返回回调；为 null 时默认 `Navigator.maybePop`
  final VoidCallback? onBack;

  /// 菜单键回调（showMenu 优先于 showBack）
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;
  final Widget? backIcon;

  /// 左侧自定义插槽（仅 [showBack] / [showMenu] 均为 false 时生效；
  /// 返回/菜单键优先，避免插槽顶掉既有导航键）。首页云同步图标用。
  final Widget? leading;

  // ===== 标题 =====
  final String? title;
  final Widget? titleWidget;

  // ===== 功能区 =====

  /// 功能键图标（默认 more_vert），点击触发 [onActionsTap]
  final Widget? actionsIcon;
  final VoidCallback? onActionsTap;

  /// 额外的功能按钮列表（在功能键左侧）
  final List<Widget>? actions;

  // ===== 玻璃背景 =====
  final bool blur;
  final double maxSigma;
  final Color? backgroundColor;

  /// 是否显示底部高光线。纯色背景场景（底部抽屉内）应设为 false。
  final bool showHighlightLine;

  // ===== 动态模糊（滚动驱动渐显） =====

  /// 滚动偏移监听器。offset <= 0 完全透明，>= [blurFadeDistance] 完全显示。
  /// 为 null 时模糊层始终完全显示。
  final ValueListenable<double>? scrollOffsetListenable;

  /// 模糊层从透明到完全显示的滚动偏移区间（像素），默认 32px。
  final double blurFadeDistance;

  /// 第一行高度（不含状态栏）
  static const double rowHeight = AppDimens.titleBarHeight;

  @override
  Size get preferredSize => const Size.fromHeight(rowHeight);

  /// 将滚动偏移映射为模糊层不透明度（0.0→1.0 线性渐显）
  static double mapOffsetToBlurOpacity(double offset, double fadeDistance) {
    if (offset <= 0.0) return 0.0;
    if (offset >= fadeDistance) return 1.0;
    return offset / fadeDistance;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final statusBarHeight = MediaQuery.of(context).padding.top;

    return RepaintBoundary(
      child: SizedBox(
        height: statusBarHeight + rowHeight,
        child: Stack(
          children: [
            // 层 A：渐变毛玻璃背景（动态模糊时跟随滚动渐显）
            if (!blur)
              Positioned.fill(
                child: ColoredBox(
                  color: backgroundColor ?? colorScheme.surface,
                ),
              )
            else if (scrollOffsetListenable != null)
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: scrollOffsetListenable!,
                  builder: (context, offset, _) {
                    return GradientBackdropFilter(
                      maxSigma: maxSigma,
                      opacity:
                          mapOffsetToBlurOpacity(offset, blurFadeDistance),
                    );
                  },
                ),
              )
            else
              Positioned.fill(
                child: GradientBackdropFilter(maxSigma: maxSigma),
              ),
            // 层 B：内容行
            Positioned(
              top: statusBarHeight,
              left: 0,
              right: 0,
              bottom: 0,
              child: _buildRow(context, colorScheme),
            ),
            // 层 C：底部折射高光线（跟随模糊层同步显隐）
            if (showHighlightLine) _buildHighlightLine(context, isDark),
          ],
        ),
      ),
    );
  }

  Widget _buildRow(BuildContext context, ColorScheme colorScheme) {
    final leading = _buildLeading(context);
    final title = _buildTitle(context, colorScheme);

    final hasActions = actions != null && actions!.isNotEmpty;
    final hasActionButton = onActionsTap != null;
    final trailing = (hasActions || hasActionButton)
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasActions) ...actions!,
              if (hasActionButton)
                IconButton(
                  icon: actionsIcon ??
                      const Icon(Icons.more_vert_rounded,
                          size: AppDimens.iconSizeMd),
                  onPressed: onActionsTap,
                ),
            ],
          )
        : null;

    return Container(
      height: rowHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppDimens.space16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ?leading,
          Expanded(child: title),
          trailing ?? const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget? _buildLeading(BuildContext context) {
    if (showMenu) {
      return IconButton(
        padding: const EdgeInsets.only(right: AppDimens.space8),
        icon: backIcon ??
            const Icon(Icons.menu_rounded, size: AppDimens.iconSizeLg),
        onPressed: onMenuTap,
      );
    }
    if (showBack) {
      return IconButton(
        padding: const EdgeInsets.only(right: AppDimens.space8),
        icon: backIcon ??
            const Icon(Icons.arrow_back_rounded, size: AppDimens.iconSizeLg),
        onPressed: onBack ?? () => Navigator.of(context).maybePop(),
      );
    }
    return leading;
  }

  Widget _buildTitle(BuildContext context, ColorScheme colorScheme) {
    // 字号走设计系统字阶（titleLarge），不再硬编码 17
    final titleStyle = Theme.of(context).textTheme.titleLarge?.copyWith(
          color: colorScheme.onSurface,
        );
    return titleWidget ??
        Text(
          title ?? '',
          style: titleStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );
  }

  /// 层 C：底部分隔线（跟随模糊层同步显隐）
  ///
  /// v2 改为"场景自适应"：
  /// - 亮色：极浅灰细线（[AppColorSet.outline]）——白玻璃在浅灰底上原本无边界，
  ///   需一条克制的分隔线定义栏底（对齐 iOS 导航栏做法）；纯白高光线在浅底上
  ///   完全不可见，旧配方等于白画一层。
  /// - 暗色：保留白色微光渐变（深底上高光才成立）。
  ///
  /// 注意：分隔线仅占底部 1px，绝不能用 Positioned.fill 包裹；
  /// Positioned 必须是 Stack 直接子节点，Opacity 只能包内部 Container。
  Widget _buildHighlightLine(BuildContext context, bool isDark) {
    final colors = AppColors.ofContext(context);
    final lineContainer = Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.22),
                  Colors.white.withValues(alpha: 0.32),
                  Colors.white.withValues(alpha: 0.22),
                  Colors.white.withValues(alpha: 0.0),
                ]
              : [
                  colors.outline.withValues(alpha: 0.0),
                  colors.outline.withValues(alpha: 0.9),
                  colors.outline.withValues(alpha: 1.0),
                  colors.outline.withValues(alpha: 0.9),
                  colors.outline.withValues(alpha: 0.0),
                ],
        ),
      ),
    );

    if (scrollOffsetListenable != null) {
      return ValueListenableBuilder<double>(
        valueListenable: scrollOffsetListenable!,
        builder: (context, offset, _) {
          final opacity = mapOffsetToBlurOpacity(offset, blurFadeDistance);
          if (opacity <= 0.0) return const SizedBox.shrink();
          return Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: opacity >= 1.0
                ? lineContainer
                : Opacity(opacity: opacity, child: lineContainer),
          );
        },
      );
    }
    return Positioned(bottom: 0, left: 0, right: 0, child: lineContainer);
  }
}
