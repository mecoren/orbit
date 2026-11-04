/// 玻璃表面原语（OS4 液态玻璃，2026-11-03）
///
/// 浮层类表面（底部弹层、悬浮面板）的材质承载：有 [backdrop]（壳层
/// `OrbitGlassScope` 暴露的采样器）时走 flutter_miuix 的 `MiuixGlassPanel`
/// + `puredThinGlass` 材质——与页头/底栏同一档栏体玻璃（`shading: false`
/// 表示不做仿生折射着色，那是按钮/菜单这类小面积表面的档位）；没有采样器
/// 或采样快照尚未就绪（首帧）时退回实时 `BackdropFilter`，避免库内在
/// 「无快照」分支退化成一整块实色。
///
/// 两条路径观感同档，差别只在「采样快照」与「实时背景滤镜」——与
/// `orbit_page_header.dart` 的 `_Os4GlassSurface` 判据一致；页头未复用本
/// 原语是因为它是 `Positioned.fill` 的直角填充层（无圆角、无阴影），与
/// 「浮起圆角面板」职责不同档，强行合并会把页头版式拖进来。
///
/// **性能口径**：`MiuixGlassPanel` 每次重绘都是「离屏模糊 + 混色 +
/// toImageSync」，纹理缓存键含面板 origin/size——尺寸/位置逐帧变化时
/// （弹层入场动画、键盘抬升）缓存逐帧失效。故材质固定取 `puredThinGlass`
/// （blurRadius 20 → sigma≈9），**不要**换成 `popupViewGlass`（60，菜单档）
/// 或自行调大 blurRadius；降采样（dpr/4）由库内 `_RenderGlass.prepare` 负责。
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';

/// OS4 玻璃采样器的向下传递通道
///
/// 壳层（`HomeShell`）把页面内容包进 `MiuixLayerBackdropCapture` 并把同一个
/// [MiuixLayerBackdrop] 从这里向下暴露。玻璃消费方必须在捕获树**之外**取这份
/// 实例（页头是页面 Stack 的顶层兄弟、弹层挂在路由/Overlay 上），否则会形成
/// 自采样反馈循环——玻璃把自己也拍进背景，越糊越实。
class OrbitGlassScope extends InheritedWidget {
  const OrbitGlassScope({
    super.key,
    required this.backdrop,
    required super.child,
  });

  /// 当前壳的玻璃背景采样器
  final MiuixLayerBackdrop backdrop;

  /// 取最近的采样器（无壳/测试裸页时返回 null，消费方自动回落实时模糊）
  static MiuixLayerBackdrop? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<OrbitGlassScope>()?.backdrop;

  @override
  bool updateShouldNotify(OrbitGlassScope oldWidget) =>
      backdrop != oldWidget.backdrop;
}

/// 页面级玻璃作用域（根级推入页专用，2026-11-04）
///
/// 根级推入页（`/settings/*`、任务详情等）挂在 Navigator 的 Overlay 上，与
/// `HomeShell` 是**兄弟**，向下取不到壳层的 [OrbitGlassScope]——页内玻璃弹层
/// 只能退到实时模糊，而实时模糊叠在白底页面上等于一块灰白板（2026-11-04
/// 外观页下拉截图）。本组件给这类页面自建一份采样器：内容包进
/// [MiuixLayerBackdropCapture]，同一实例经 [OrbitGlassScope] 向下暴露。
///
/// **消费方必须在捕获树之外**：页内弹层经 `OverlayPortal` 挂到根 Overlay
/// （捕获树的兄弟层），拿到的快照不含弹层自己；页头这类**在捕获树内**的
/// 玻璃件仍应走实时模糊（传 backdrop 会把自己拍进背景，越糊越实）。
class OrbitGlassPage extends StatefulWidget {
  const OrbitGlassPage({super.key, required this.child});

  /// 页面本体（通常直接是 `Scaffold`）
  final Widget child;

  @override
  State<OrbitGlassPage> createState() => _OrbitGlassPageState();
}

class _OrbitGlassPageState extends State<OrbitGlassPage> {
  /// 采样器随 State 生命周期持有（dispose 释放快照图像）
  final MiuixLayerBackdrop _backdrop = MiuixLayerBackdrop();

  @override
  void dispose() {
    _backdrop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OrbitGlassScope(
    backdrop: _backdrop,
    child: MiuixLayerBackdropCapture(backdrop: _backdrop, child: widget.child),
  );
}

/// 圆角玻璃表面（见文件头）
class OrbitGlassSurface extends StatelessWidget {
  const OrbitGlassSurface({
    super.key,
    required this.child,
    this.backdrop,
    this.borderRadius = BorderRadius.zero,
    this.realtimeSigma = 14,
    this.realtimeSurfaceOpacity = 0.72,
  });

  /// 表面内容（玻璃画在它之下）
  final Widget child;

  /// OS4 玻璃背景采样器（通常传 `OrbitGlassScope.maybeOf(context)`）；
  /// null → 实时模糊路径（无壳、测试裸页、首帧快照未就绪）
  final MiuixLayerBackdrop? backdrop;

  /// 表面圆角（底部弹层给「上圆下直」的 `BorderRadius.vertical`）
  final BorderRadius borderRadius;

  /// 实时模糊路径的高斯 sigma（逻辑像素）；OS4 路径的模糊量由材质档决定
  final double realtimeSigma;

  /// 实时模糊路径的表面色不透明度（OS4 路径的混色由材质档的颜色层承担）
  final double realtimeSurfaceOpacity;

  @override
  Widget build(BuildContext context) {
    final sampler = backdrop;
    if (sampler == null) return _realtime(context);
    return ListenableBuilder(
      listenable: sampler,
      builder: (context, _) {
        // 宿主未接线/首帧尚未录完快照时库内会退实色填充，这里先走实时模糊，
        // 快照就绪后自动切到 OS4 玻璃（与页头同一避坑口径）
        if (sampler.snapshot == null) return _realtime(context);
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return MiuixGlassPanel(
          backdrop: sampler,
          material: MiuixGlassMaterials.puredThinGlass(isDark),
          shape: MiuixGlassShape(borderRadius: borderRadius),
          // 栏体类表面：材质即本体，不叠折射着色；描边/阴影留默认
          shading: false,
          child: child,
        );
      },
    );
  }

  /// 实时模糊路径：均匀高斯 + 半透明表面色（无采样快照时的唯一可选做法）
  Widget _realtime(BuildContext context) {
    final surface = AppColors.ofContext(context).popup;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: realtimeSigma,
          sigmaY: realtimeSigma,
        ),
        child: ColoredBox(
          color: surface.withValues(alpha: realtimeSurfaceOpacity),
          child: child,
        ),
      ),
    );
  }
}

/// 底部弹层玻璃壳（`showModalBottomSheet` 专用，2026-11-03）
///
/// 承载层必须配 `backgroundColor: Colors.transparent` + `elevation: 0`——
/// 否则 Material 会在透明底上再补一圈**直角**阴影，把顶部圆角玻璃的边界弄脏。
///
/// 三件事在这里收口，调用方不必各写一遍：
/// - 浮起卡片：左/右/下各 `space16` 留白、四角 `AppShapes.radiusXl`（28），
///   与 `OrbitFloatingSheetCard` 同形态（2026-11-04 全量收口）；
/// - 键盘避让放在玻璃**之外**（玻璃只覆盖面板本体，键盘高度不进模糊纹理，
///   否则模糊面积近乎翻倍），骨架自带的 `viewInsets` 避让在这里被清零，
///   不会算两遍；
/// - 玻璃弹层里的 `OrbitSheetScaffold` 应传 `floatingCard: false`，避免双层卡面。
class OrbitGlassSheet extends StatelessWidget {
  const OrbitGlassSheet({
    super.key,
    required this.child,
    this.backdrop,
    this.radius = AppShapes.radiusXl,
  });

  /// 面板内容（`OrbitSheetScaffold` 骨架或裸内容列）
  final Widget child;

  /// OS4 玻璃背景采样器（调用方从 `OrbitGlassScope` 取；null = 实时模糊）
  final MiuixLayerBackdrop? backdrop;

  /// 四角圆角半径（浮起卡片档 28）
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Container(
        margin: const EdgeInsets.only(
          left: AppDimens.space16,
          right: AppDimens.space16,
          bottom: AppDimens.space16,
        ),
        child: OrbitGlassSurface(
          backdrop: backdrop,
          borderRadius: BorderRadius.circular(radius),
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: child,
          ),
        ),
      ),
    );
  }
}
