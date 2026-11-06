import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';

/// 悬浮主操作按钮（flutter_miuix `MiuixFloatingActionButton` 承载）
///
/// **2026-11-01 换承载**：shadcn `Button.primary`（圆形变体 + 组件级主题
/// 覆盖填色）换成 miuix FAB——squircle 引擎同源的 `StadiumBorder`（正方形
/// bounds 下为正圆）、`MiuixPressable` 弹簧按压遮罩与库内阴影公式（HyperOS
/// 规格：elevation 4、黑 15% 投影），按实例填色走 [MiuixFloatingActionButton.containerColor]
/// 直接传强调色，不再需要绕组件主题。
///
/// **2026-11-05 玻璃档**（[glass]）：与悬浮底栏同一套 OS4 液态玻璃——底栏是
/// `MiuixGlassMaterials.puredThinGlass` + 999 圆角胶囊，本钮同材质、同圆角
/// （圆形钮取 999 即正圆；材质档差异见下方 2026-11-06 第三条）。玻璃版
/// **不填强调色**，图标转主题色（玻璃卡面上白字会糊掉），按压/长按语义不变。
///
/// **2026-11-06 玻璃档三态收口**：原先 `glass && backdrop != null` 才走玻璃，
/// 且不监听采样器快照——首帧（快照未就绪）或裸页（无采样器）会定格成实心
/// 主题色圆片，之后也不会自己变玻璃（真机反馈「怎么没有玻璃效果」）。
/// 现与 [OrbitGlassSurface] 同口径分三态：
/// - 采样器就绪 → `MiuixGlassPanel` + `puredThinGlass`（OS4 真玻璃）；
/// - 采样器存在但快照未就绪（首帧）→ 实时 `BackdropFilter` 玻璃；
/// - 无采样器（裸页 / 测试）→ 同一条实时模糊路径。
///
/// 三态都可透出背后内容，**不会**再退回实心强调色圆片；快照就绪后经
/// `ListenableBuilder` 自动切到 OS4 玻璃。
///
/// **2026-11-06 玻璃钮「没有玻璃感」二次收口**（真机反馈：白底上就是一坨白雾，
/// 看不出是一枚浮起的玻璃钮）。三条根因，都在本文件：
/// - **投影被裁掉**：`MiuixPressable(borderRadius:)` 会把 child 整体裁到圆形
///   （按压遮罩要跟着圆走），而 `MiuixGlassPanel` 的 OS4 阴影画在面板矩形之外
///   （`paintBounds` 外扩），于是阴影 100% 被裁掉——钮只剩一层没有厚度的白。
///   现在阴影挪到裁切层**之外**（外层 `DecoratedBox`，按库内 FAB 的 elevation 4
///   口径：黑 15%、blur 16、下移 6），玻璃面板本身 `shadow: null`（省一次
///   shadow shader 绘制）。
/// - **没有描边**：底栏/菜单都挂了 `MiuixGlassStrokes.forTheme` 的那圈高光，
///   本钮漏了，白卡上连轮廓都读不出来。现补齐同档描边（同底栏，不再另设档）。
/// - **材质档选错**：原来跟着底栏走 `shading: false`（**栏体档**：只做高斯模糊
///   + 混色）。栏体横在页面底部、背后是与页面背景同色的连续内容，混色就够；
///   而本钮是**小面积按钮**，四周全是白色卡片，只混色 = 一枚纯白圆片。按钮档
///   是 `shading: true`（仿生折射：`glass` shader 做边缘折射 + 内层白 + 光照
///   反射），白底上能读出「透镜边缘那圈高光」，这才是 OS4 玻璃钮的观感。
///   性能无虞：56dp 圆面、位置静止，纹理缓存键不再逐帧变化，一次绘制后常驻。
///
/// 长按语义（模板新建）miuix FAB 无此参数，经外层 `GestureDetector` 补上：
/// FAB 内部的 `MiuixPressable` 不注册长按手势（onLongPress 传 null 不进
/// 手势竞技场），外层识别器无竞争、正常触发。
class OrbitFab extends StatelessWidget {
  const OrbitFab({
    super.key,
    required this.onPressed,
    required this.accentColor,
    this.onLongPress,
    this.icon = OrbitIcons.add,
    this.dimension = AppDimens.fabSize,
    this.glass = false,
    this.backdrop,
  });

  /// 点击回调
  final VoidCallback onPressed;

  /// 长按回调（可空；无长按语义的调用点不传即无长按）
  final VoidCallback? onLongPress;

  /// 强调色（实心档作填充底色；玻璃档作图标色）
  final Color accentColor;

  /// 图标，默认 plus
  final IconData icon;

  /// 圆钮边长（默认悬浮钮规格 56；底部导航中央凸起钮用 48 小档）
  final double dimension;

  /// 是否走 OS4 玻璃材质（与悬浮底栏同档；见文件头）
  final bool glass;

  /// 玻璃档的背景采样器（null = 实时模糊路径，不会退实心）
  final MiuixLayerBackdrop? backdrop;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final hasGlass = glass;
    // 玻璃档图标转强调色（玻璃卡面上白字会糊）；实心档恒白
    final iconColor = hasGlass ? accentColor : const Color(0xFFFFFFFF);
    final content = Icon(icon, size: AppDimens.iconSizeLg, color: iconColor);
    final button = hasGlass
        // 玻璃档：`MiuixPressable` 承载点击与弹簧按压（与实心档 miuix FAB
        // 同源的 pressDown/pressUp 弹簧），玻璃面板本身不吃手势。
        //
        // 投影必须画在 `MiuixPressable` **之外**：它按 borderRadius 把 child
        // 整体裁成圆形（按压遮罩跟圆走），玻璃面板的 OS4 阴影画在矩形之外，
        // 在裁切层内会被整块裁掉（真机「白底上一坨白雾、没有厚度」的根因）。
        ? DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              // 与实心档 miuix FAB 的 elevation 4 同口径（黑 15%）
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: MiuixPressable(
              onPressed: onPressed,
              borderRadius: BorderRadius.circular(dimension / 2),
              child: SizedBox(
                width: dimension,
                height: dimension,
                child: _FabGlassSurface(
                  backdrop: backdrop,
                  isDark: isDark,
                  radius: dimension / 2,
                  child: Center(child: content),
                ),
              ),
            ),
          )
        : MiuixFloatingActionButton(
            onPressed: onPressed,
            // 圆钮直径 = dimension（minWidth/minHeight 同时钉住）
            minWidth: dimension,
            minHeight: dimension,
            // 内容色不跟随库内 onSurface（miuix FAB 内容色继承 Surface 默认值），
            // 按既有口径恒白
            containerColor: accentColor,
            child: content,
          );
    return GestureDetector(onLongPress: onLongPress, child: button);
  }
}

/// 玻璃圆钮表面（三态见 [OrbitFab] 文件头）
///
/// 与 `OrbitGlassSurface` 同一套判据：有采样器且快照就绪走 OS4 玻璃，
/// 其余走实时模糊；差别只在这是**圆形小表面**且必须监听快照就绪。
class _FabGlassSurface extends StatelessWidget {
  const _FabGlassSurface({
    required this.backdrop,
    required this.isDark,
    required this.radius,
    required this.child,
  });

  final MiuixLayerBackdrop? backdrop;
  final bool isDark;
  final double radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final sampler = backdrop;
    if (sampler == null) return _realtime();
    return ListenableBuilder(
      listenable: sampler,
      builder: (context, _) {
        // 首帧快照未就绪：先实时模糊，就绪后自动切 OS4 玻璃
        if (sampler.snapshot == null) return _realtime();
        return MiuixGlassPanel(
          backdrop: sampler,
          material: MiuixGlassMaterials.puredThinGlass(isDark),
          shape: const MiuixGlassShape(cornerRadius: 999),
          // 与底栏/菜单同一圈高光：缺了描边，白卡上的玻璃钮连轮廓都读不出来
          stroke: MiuixGlassStrokes.forTheme(isDark),
          // 投影由外层 `OrbitFab` 的 DecoratedBox 负责（本面板画在矩形之外，
          // 会被 `MiuixPressable` 的圆角裁切吃掉，见文件头）；这里关掉省一次
          // shadow shader 绘制
          shadow: null,
          // 按钮档：仿生折射着色（栏体档 shading:false 在白卡上只会混成纯白，
          // 见文件头 2026-11-06 第三条）；shader 缺席时库内自动退「模糊 + 混色」
          shading: true,
          child: child,
        );
      },
    );
  }

  /// 实时模糊路径（无采样器 / 首帧）：半透明表面 + 高斯模糊，透得出背后内容
  Widget _realtime() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: ColoredBox(
          color: (isDark ? Colors.black : Colors.white).withValues(alpha: 0.66),
          child: child,
        ),
      ),
    );
  }
}
