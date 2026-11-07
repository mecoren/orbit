/// 底部弹层玻璃壳的形变期材质闸门（2026-11-08）
///
/// 与锚定弹层的 [OrbitPopupGlassMotion] 同源、不同手法：这里**只降材质，
/// 不冻结 ticker**。原因写在 `orbit_popup_glass.dart` 文件头——那边的冻结是
/// 「停掉库内形变弹簧」，而底部弹层的入场/退场由 `ModalBottomSheetRoute` 自己
/// 的 `AnimationController` 驱动，冻结会把它停在半空。
///
/// 要解决的问题（与锚定弹层同一根因）：
/// `MiuixGlassPanel` 每次重绘都是「离屏模糊 + 两趟混色 + `toImageSync`」，
/// 纹理缓存键含面板 `origin/size`。底部弹层入场 220ms（`bottomSheetMotion`）
/// 期间面板位置逐帧变化 → 缓存逐帧全盘失效 → 每帧重跑全量模糊；
/// **快速添加面板还叠一层键盘抬升**（`autofocus: true`），`viewInsets` 逐帧变
/// 卡面高度，入场结束后依然在逐帧重录——2026-11-08 实测这是全 App 唯一
/// raster 超预算的动画场景（worst ≈ 25ms，预算 16.7ms）。
///
/// 本件在下列三个窗口内把卡面切成实色（`OrbitPopupGlass.fill`，与锚定弹层
/// 形变期同一档 97% 白/炭黑），窗口结束**同帧**切回真玻璃：
/// 1. 挂载起的 [OrbitPopupGlass.morphWindow]（320ms，覆盖 220ms 入场）；
/// 2. 键盘每次变化的 [OrbitPopupGlass.morphWindow]（`viewInsets.bottom` 变化）；
/// 3. 路由反向（退场，150ms）—— 退场立刻回实色，不等计时器。
///
/// **不要**把 `TickerMode` 加进来：那会冻住弹层自身的入场/退场。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'orbit_popup_glass.dart';

/// 底部弹层玻璃壳的形变期闸门（用法见文件头）
///
/// ```dart
/// OrbitSheetGlassMotion(
///   builder: (context, solid) => OrbitGlassSurface(
///     backdrop: solid ? null : backdrop,
///     solid: solid,
///     child: child,
///   ),
/// )
/// ```
class OrbitSheetGlassMotion extends StatefulWidget {
  const OrbitSheetGlassMotion({super.key, required this.builder});

  /// 承载构建；`solid = true` 表示此刻卡面该走实色（不采样背景）
  final Widget Function(BuildContext context, bool solid) builder;

  @override
  State<OrbitSheetGlassMotion> createState() => _OrbitSheetGlassMotionState();
}

class _OrbitSheetGlassMotionState extends State<OrbitSheetGlassMotion> {
  /// 挂载即处于形变窗（入场第一帧必须已经是实色，晚一帧就会先录一次快照）
  bool _solid = true;

  Timer? _timer;

  /// 上一次的键盘底沿（null = 尚未记录，首帧不触发重臂）
  double? _lastInset;

  /// 路由动画：反向（退场）时立刻回实色
  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (!identical(route?.animation, _routeAnimation)) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = route?.animation;
      _routeAnimation?.addStatusListener(_onRouteStatus);
    }
    // `viewInsetsOf` 建立依赖：键盘抬升/回落会逐帧走到这里
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (_lastInset != null && inset != _lastInset) {
      // 卡面高度变了 → 纹理缓存键也变了 → 重新进入实色窗
      _arm();
    }
    _lastInset = inset;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    super.dispose();
  }

  void _onRouteStatus(AnimationStatus status) {
    // 退场：库内的反向动画只有 150ms，立刻回实色，别等 320ms 计时器
    if (status == AnimationStatus.reverse) _setSolid(true);
  }

  /// 开一个形变窗：现在回实色，[OrbitPopupGlass.morphWindow] 后切真玻璃
  void _arm() {
    _timer?.cancel();
    _setSolid(true);
    _timer = Timer(OrbitPopupGlass.morphWindow, () {
      if (!mounted) return;
      _setSolid(false);
    });
  }

  void _setSolid(bool next) {
    if (next == _solid) return;
    // initState 首帧 `_solid` 已是 true，这里不会走到 setState
    setState(() => _solid = next);
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _solid);
}
