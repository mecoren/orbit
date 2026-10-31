import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';
import 'orbit_progressive_blur.dart';
import 'orbit_icon_button.dart';

/// 页头（OS4 液态玻璃表面）
///
/// 布局口径逐像素沿用 v3（**只换表面材质，不换信息层级与几何**）：
/// `[返回/菜单键 | leading 插槽] [标题] ... [actions 插槽]`；
/// 行高 [rowHeight] = [AppDimens.titleBarHeight]，水平内边距 [AppDimens.space16]；
/// 标题 titleLarge 字阶、左对齐、单行省略。
///
/// **为什么不用 `MiuixGlassTopAppBar` 整栏替换**：该组件是 HyperOS 的
/// 「大标题折叠栏」（展开高 52 + 大标题高度 ≈ 104dp、标题居中），与本仓库
/// 28 个页面既有的「56dp 单行、标题左对齐、自定义 titleWidget 槽」几何完全不同
/// ——整栏替换会让所有页面的 `状态栏 + rowHeight` 让位计算失效（内容被栏体
/// 压住或留白翻倍），属于"换组件顺带改了版式"，与本任务「功能与交互保持
/// 一致、无回归」相冲突。故这里**只取 OS4 玻璃材质**（`MiuixGlassPanel`），
/// 布局仍由本组件承担。
///
/// 表面材质两条路径：
/// - 宿主传了 [backdrop]（`MiuixLayerBackdropCapture` 的采样器）→ OS4 液态
///   玻璃：库内 fragment shader 的**模糊 + 混色 + 描边**，材质取
///   `MiuixGlassMaterials.puredThinGlass`（顶栏/导航栏同款，`shading: false`
///   表示不做仿生折射着色，这是栏体类表面的正确材质档）；
/// - 没传 → [OrbitProgressiveBlur]（Impeller 渐进高斯 + surface tint 渐变），
///   即 v3 的实时模糊路径。两条路径观感同档，差别只在「采样快照」与
///   「实时背景滤镜」。
///
/// 表面之下再叠一层主题色玻璃渐变（顶强底弱）：白底页面下方没有内容滚过时，
/// 模糊后仍是纯色，这层才是常驻的玻璃质感来源；有内容滚过时同时给磨砂加一层
/// 品牌色调。
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
    // OS4 玻璃背景采样器（null = 实时背景滤镜路径）
    this.backdrop,
  });

  /// 行高（页面内容区让位基准；与各页 `OrbitPageHeader.rowHeight` 同值同义）
  static const double rowHeight = AppDimens.titleBarHeight;

  /// 实时模糊路径的模糊强度（逻辑像素 sigma）：与移动端设计基准同档，
  /// 改这里即全站页头同步
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
  /// 覆在描边之上；null 不渲染。进度变化走隐式动画补间。
  final double? progress;

  /// OS4 玻璃的背景采样器（与宿主 `MiuixLayerBackdropCapture` 同一个实例）。
  /// null → 走实时 `BackdropFilter` 路径（观感同档，无需宿主接线）。
  final MiuixLayerBackdrop? backdrop;

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
        // 层 A：OS4 玻璃（采样快照）或实时背景模糊（无采样器时）
        Positioned.fill(
          child: backdrop == null
              ? const OrbitProgressiveBlur(sigma: glassSigma)
              : _Os4GlassSurface(backdrop: backdrop!, isDark: isDark),
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
        // 层 C：标题行（Material 透明：只承载水波，不画底色/挡住下方玻璃）。
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
      return OrbitIconButton(
        tooltip: '菜单',
        icon: Icon(
          OrbitIcons.menu,
          size: AppDimens.iconSizeLg,
          color: colors.titleText,
        ),
        onPressed: onMenuTap,
      );
    }
    if (showBack) {
      return OrbitIconButton(
        tooltip: '返回',
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

/// OS4 液态玻璃表面（栏体材质档）
///
/// `MiuixGlassPanel` + `puredThinGlass` 材质 + `shading: false`：这是库内
/// 顶栏/导航栏这类**栏体**的标准材质（高斯模糊 + 至多三层独立混色），
/// 与菜单/按钮的仿生折射玻璃（`shading: true`）区分开。
///
/// 形状取 `cornerRadius: 0`（通栏直角），描边/阴影都不挂——页头边界靠
/// 「玻璃带 + 内容滚过时的模糊」交代，再加描边会像老式 AppBar 下边框。
///
/// **没有采样快照时的降级**：首帧（捕获树尚未录制）或宿主未接线时
/// `backdrop.snapshot` 为 null，库内会退到 `fill` 实色——页头会在第一帧
/// 显示为纯色带。这里在快照就绪前改走实时 `BackdropFilter`（与 v3 同档），
/// 避免首帧闪一下实色；快照就绪后自动切到 OS4 玻璃。
class _Os4GlassSurface extends StatelessWidget {
  const _Os4GlassSurface({required this.backdrop, required this.isDark});

  final MiuixLayerBackdrop backdrop;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: backdrop,
      builder: (context, _) {
        if (backdrop.snapshot == null) {
          return const OrbitProgressiveBlur(sigma: OrbitPageHeader.glassSigma);
        }
        return MiuixGlassPanel(
          backdrop: backdrop,
          material: MiuixGlassMaterials.puredThinGlass(isDark),
          shape: const MiuixGlassShape(cornerRadius: 0),
          stroke: null,
          shadow: null,
          shading: false,
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

