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

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import 'orbit_popup_glass.dart';
import 'orbit_sheet_glass_motion.dart';

/// 玻璃背景快照的录制倍率（2026-11-07，性能口径）
///
/// `MiuixLayerBackdropCapture` 每重绘一次就把**整棵捕获子树**（壳层里就是整页）
/// `OffsetLayer.toImageSync` 成一张图：列表滚动是逐帧、弹层开场/退场各一次，按
/// 设备 DPR 录制时 1080×2400 的屏一次就是 2.6MP——这是全项目最重的玻璃开销，
/// 也是「滚一下掉帧」「点开菜单卡一下」的共同根因。
///
/// 而取样端 `_RenderGlass.prepare` 的纹理倍率是 `dpr/4`（clamp 到 ≤1，手机上是
/// 0.75–0.875），即玻璃真正需要的源分辨率只有 DPR 的 1/4 上下。这里按**半个
/// DPR**（不小于 1）录制：快照面积降到 1/4，玻璃仍有 2 倍以上余量，观感无差。
double orbitBackdropPixelRatio(BuildContext context) =>
    math.max(1, MediaQuery.devicePixelRatioOf(context) / 2);

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
    // 滚动期冻结快照（见 [OrbitScrollAwareBackdropCapture]）
    child: OrbitScrollAwareBackdropCapture(
      backdrop: _backdrop,
      child: widget.child,
    ),
  );
}

/// 滚动期冻结的背景捕获（2026-11-08）
///
/// 库内 [MiuixLayerBackdropCapture] 的机制是「子树每次重绘 → 帧末
/// `toImageSync` 整页快照」——列表滚动时逐帧重录，是玻璃链路在真机上最大的
/// 持续开销（x64 模拟器 GPU 加速量不出来，真机按 dpr/2 录制一次就是百万像素级）。
/// 本件复刻同一机制并加暂停档：滚动活跃期不再录新快照，消费方（底栏/FAB/
/// 弹层的玻璃）沿用最后一帧；滚动 settle 后恢复录制并补录一次。玻璃内内容在
/// 滚动期轻微滞后——玻璃拟态系统的标准权衡（iOS 同款行为），可接受。
///
/// **为什么不用 RepaintBoundary 包滚动列表「顺带」挡住重录**：图层脏标记沿
/// Layer 链向上传播（`Layer.markNeedsAddToScene` 逐级上抛），边界挡不住内容
/// 层的 `addToScene` 钩子；且页头实时模糊会被隔离边界弄瞎（见
/// `orbit_progressive_blur.dart` 的调用约定）。
class OrbitScrollAwareBackdropCapture extends StatefulWidget {
  const OrbitScrollAwareBackdropCapture({
    super.key,
    required this.backdrop,
    required this.child,
  });

  /// OS4 玻璃背景采样器（快照录给它）
  final MiuixLayerBackdrop backdrop;

  /// 被捕获的页面内容（滚动通知从这里冒泡）
  final Widget child;

  @override
  State<OrbitScrollAwareBackdropCapture> createState() =>
      _OrbitScrollAwareBackdropCaptureState();
}

class _OrbitScrollAwareBackdropCaptureState
    extends State<OrbitScrollAwareBackdropCapture> {
  /// 最后一帧滚动通知之后的静默期：静满即认为滚动已 settle
  ///
  /// 惯性滚动期间 update 通知逐帧不断，恢复只会发生在真正停手之后。
  static const _resumeDelay = Duration(milliseconds: 120);

  Timer? _resume;
  bool _paused = false;

  @override
  void dispose() {
    _resume?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    _resume?.cancel();
    if (!_paused) setState(() => _paused = true);
    _resume = Timer(_resumeDelay, () {
      if (mounted) setState(() => _paused = false);
    });
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollNotification>(
    onNotification: _onScroll,
    child: _OrbitLayerBackdropCapture(
      backdrop: widget.backdrop,
      paused: _paused,
      pixelRatio: orbitBackdropPixelRatio(context),
      child: widget.child,
    ),
  );
}

/// 带暂停档的图层背景捕获（[OrbitScrollAwareBackdropCapture] 的承载层）
///
/// 机制与 flutter_miuix `miuix_layer_backdrop.dart`（Apache-2.0）逐项同构：
/// 重绘边界 + 内容层 `addToScene` 钩子 + 帧末 `toImageSync`。差异仅在
/// [paused] 为 true 时 `_scheduleCapture` 直接短路——快照冻结在最后一帧，
/// 恢复时本节点重绘一次触发补录。
class _OrbitLayerBackdropCapture extends SingleChildRenderObjectWidget {
  const _OrbitLayerBackdropCapture({
    required this.backdrop,
    required this.paused,
    this.pixelRatio,
    required super.child,
  });

  final MiuixLayerBackdrop backdrop;
  final bool paused;
  final double? pixelRatio;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderOrbitLayerBackdropCapture(
        initialBackdrop: backdrop,
        initialDevicePixelRatio:
            pixelRatio ?? MediaQuery.devicePixelRatioOf(context),
        initialPaused: paused,
      );

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderOrbitLayerBackdropCapture)
      ..backdrop = backdrop
      ..devicePixelRatio = pixelRatio ?? MediaQuery.devicePixelRatioOf(context)
      ..paused = paused;
  }
}

class _CaptureContentLayer extends OffsetLayer {
  _CaptureContentLayer(this.onContentChanged);

  final VoidCallback onContentChanged;

  @override
  void addToScene(ui.SceneBuilder builder) {
    super.addToScene(builder);
    onContentChanged();
  }
}

class _RenderOrbitLayerBackdropCapture extends RenderProxyBox {
  _RenderOrbitLayerBackdropCapture({
    required MiuixLayerBackdrop initialBackdrop,
    required double initialDevicePixelRatio,
    required bool initialPaused,
  }) : _backdrop = initialBackdrop,
       _devicePixelRatio = initialDevicePixelRatio,
       _paused = initialPaused;

  MiuixLayerBackdrop _backdrop;
  MiuixLayerBackdrop get backdrop => _backdrop;
  set backdrop(MiuixLayerBackdrop value) {
    if (identical(_backdrop, value)) return;
    _backdrop.unregisterCapture(this);
    _backdrop = value;
    if (attached) _backdrop.registerCapture(this);
    markNeedsPaint();
  }

  double _devicePixelRatio;
  double get devicePixelRatio => _devicePixelRatio;
  set devicePixelRatio(double value) {
    if (_devicePixelRatio == value) return;
    _devicePixelRatio = value;
    markNeedsPaint();
  }

  bool _paused;
  bool get paused => _paused;
  set paused(bool value) {
    if (_paused == value) return;
    _paused = value;
    // 恢复录制：重绘一次触发补录（暂停期内容层钩子被短路，最后一帧的
    // 子树变化不会再排期）
    if (!value) markNeedsPaint();
  }

  @override
  bool get isRepaintBoundary => true;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _backdrop.registerCapture(this);
  }

  @override
  void detach() {
    _backdrop.unregisterCapture(this);
    super.detach();
  }

  final _contentLayer = LayerHandle<_CaptureContentLayer>();
  bool _capturing = false;

  @override
  void dispose() {
    _contentLayer.layer = null;
    super.dispose();
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    _contentLayer.layer ??= _CaptureContentLayer(_scheduleCapture);
    context.pushLayer(_contentLayer.layer!, super.paint, offset);
    // 本节点是重绘边界，super.paint 会把子树画进本节点的 OffsetLayer。
    // 帧结束后异步快照该图层（暂停期短路，见 [_scheduleCapture]）。
    _scheduleCapture();
  }

  bool _captureScheduled = false;

  void _scheduleCapture() {
    if (_paused ||
        _capturing ||
        !attached ||
        _captureScheduled ||
        !hasSize ||
        size.isEmpty) {
      return;
    }
    _captureScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _captureScheduled = false;
      if (!attached || !hasSize || size.isEmpty) return;
      _capture();
    });
  }

  void _capture() {
    final offsetLayer = layer;
    if (offsetLayer is! OffsetLayer) return;
    final dpr = _devicePixelRatio;
    _capturing = true;
    try {
      final image = offsetLayer.toImageSync(Offset.zero & size, pixelRatio: dpr);
      final global = localToGlobal(Offset.zero);
      _backdrop.updateSnapshot(image, global, dpr);
    } finally {
      _capturing = false;
    }
  }
}

/// 圆角玻璃表面（见文件头）
class OrbitGlassSurface extends StatelessWidget {
  const OrbitGlassSurface({
    super.key,
    required this.child,
    this.backdrop,
    this.solid = false,
    this.borderRadius = BorderRadius.zero,
    this.realtimeSigma = 14,
    this.realtimeSurfaceOpacity = 0.72,
  });

  /// 表面内容（玻璃画在它之下）
  final Widget child;

  /// OS4 玻璃背景采样器（通常传 `OrbitGlassScope.maybeOf(context)`）；
  /// null → 实时模糊路径（无壳、测试裸页、首帧快照未就绪）
  final MiuixLayerBackdrop? backdrop;

  /// 形变期实色档（2026-11-08）
  ///
  /// true = **不采样背景**：走 `MiuixGlassPanel` 的「无快照 → 实色填充」分支
  /// （阴影/圆角/描边照旧），零离屏模糊、零 `toImageSync`。仅用于入场/退场/
  /// 键盘抬升这类面板 origin/size 逐帧变化的窗口——此时纹理缓存本就会逐帧
  /// 失效，采样纯属白烧。窗口结束由宿主同帧切回真玻璃。
  ///
  /// 默认 false：其余所有消费方行为零变化。
  final bool solid;

  /// 表面圆角（底部弹层给「上圆下直」的 `BorderRadius.vertical`）
  final BorderRadius borderRadius;

  /// 实时模糊路径的高斯 sigma（逻辑像素）；OS4 路径的模糊量由材质档决定
  final double realtimeSigma;

  /// 实时模糊路径的表面色不透明度（OS4 路径的混色由材质档的颜色层承担）
  final double realtimeSurfaceOpacity;

  @override
  Widget build(BuildContext context) {
    final sampler = backdrop;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (sampler == null) return _realtime(context, isDark: isDark);
    return ListenableBuilder(
      listenable: sampler,
      builder: (context, _) {
        // 宿主未接线/首帧尚未录完快照时库内会退实色填充，这里先走实时模糊，
        // 快照就绪后自动切到 OS4 玻璃（与页头同一避坑口径）
        if (sampler.snapshot == null) return _realtime(context, isDark: isDark);
        return _panel(isDark, sampler: solid ? null : sampler);
      },
    );
  }

  /// OS4 玻璃面板：`sampler == null` 即形变期实色档
  ///
  /// 库内在「无背景快照」分支只画「填色 + 阴影 + 描边」，不跑离屏模糊/混色/
  /// `toImageSync`。**两档必须是同一个 widget 类型**：换成别的容器会把整个
  /// 子树重挂（`EditableText` 重建 = 输入法收起，2026-11-08 踩坑）。
  /// `fill` 只在实色档显式给（与锚定弹层形变期同一档 97% 白/炭黑），
  /// 真玻璃档留 null 让材质自己决定。
  Widget _panel(bool isDark, {required MiuixLayerBackdrop? sampler}) =>
      MiuixGlassPanel(
        backdrop: sampler,
        material: MiuixGlassMaterials.puredThinGlass(isDark),
        fill: sampler == null ? OrbitPopupGlass.fill(isDark) : null,
        shape: MiuixGlassShape(borderRadius: borderRadius),
        // 栏体类表面：材质即本体，不叠折射着色；描边/阴影留默认
        shading: false,
        child: child,
      );

  /// 实时模糊路径：均匀高斯 + 半透明表面色（无采样快照时的唯一可选做法）
  ///
  /// 形变期（[solid]）不换 widget 类型，只把 sigma 归零、表面色换成实色：
  /// 同一条树上切参数，子树不重建。
  Widget _realtime(BuildContext context, {required bool isDark}) {
    final surface = AppColors.ofContext(context).popup;
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(
          sigmaX: solid ? 0 : realtimeSigma,
          sigmaY: solid ? 0 : realtimeSigma,
        ),
        child: ColoredBox(
          color: solid
              ? OrbitPopupGlass.fill(isDark)
              : surface.withValues(alpha: realtimeSurfaceOpacity),
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
    // 形变期（入场 220ms / 键盘抬升 / 退场 150ms）切实色卡面：见
    // `orbit_sheet_glass_motion.dart` 文件头（2026-11-08 实测这是全 App
    // 唯一 raster 超预算的动画场景）
    return OrbitSheetGlassMotion(builder: _buildBody);
  }

  Widget _buildBody(BuildContext context, bool solid) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    // 安全区包在玻璃卡外：卡面整体浮在手势条/导航栏之上，卡内不再多出一截
    // inset 高的空白（骨架在 floatingCard: false 档不再消费安全区，见
    // orbit_sheet_scaffold.dart；与确认弹层同口径，2026-11-07）
    child: SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.only(
          left: AppDimens.space16,
          right: AppDimens.space16,
          bottom: AppDimens.space16,
        ),
        child: OrbitGlassSurface(
          backdrop: backdrop,
          solid: solid,
          borderRadius: BorderRadius.circular(radius),
          child: MediaQuery.removeViewInsets(
            context: context,
            removeBottom: true,
            child: child,
          ),
        ),
      ),
    ),
  );
}
