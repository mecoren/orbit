import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import 'orbit_capture_pause.dart';

/// 骨架占位块（首屏加载态专用，设计系统 v3 原语层）
///
/// 自绘呼吸块，不引入第三方骨架库：
/// - 颜色取 `surfaceSecondary`（与分层表面同源，亮暗自适应）；
/// - 呼吸周期与曲线走 [AppMotion.skeletonPulse] / [AppMotion.breathe]
///  （视图内禁裸 Duration / Curves）；
/// - 仅首屏骨架使用（主列表 / 详情 / 统计 / 侧栏 / 四象限 / 回收站 /
///   更新日志两页的初次加载，2026-11-08 起全部共享单路呼吸），且只在
///   "无旧值可守"时出现（有旧值走旧内容，不闪骨架）；次级页与按钮内
///   loading 一律保持 spinner，避免整站闪烁感。
class OrbitSkeleton extends StatefulWidget {
  const OrbitSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = AppShapes.radiusSmall,
    this.pulse,
  });

  /// 文本行占位（默认宽 120；胶囊圆角）
  const OrbitSkeleton.line({
    super.key,
    this.width = 120,
    this.height = 14,
    this.pulse,
  }) : borderRadius = height / 2;

  /// 块占位（卡片 / 图区）
  const OrbitSkeleton.block({
    super.key,
    this.width,
    this.height = 96,
    this.borderRadius = AppShapes.radiusMedium,
    this.pulse,
  });

  /// 圆形占位（复选框 / 色点 / 头像）
  const OrbitSkeleton.circle({
    super.key,
    double size = 20,
    this.pulse,
  })  : width = size,
        height = size,
        borderRadius = size / 2;

  final double? width;
  final double height;
  final double borderRadius;

  /// 共享呼吸动画（2026-11-08）
  ///
  /// 非空 = **复用外部动画**，本节不建 controller。列表类骨架一次铺 8 行 ×
  /// 3 块，逐块自建 `AnimationController` 就是 24 路 ticker 同时逐帧驱动
  /// 24 次 opacity 重绘；由外层建一个 controller 向下传，`FadeTransition`
  /// 只求值不 tick，成本降到 1 路。
  ///
  /// 动画应已带 `AppMotion.breathe` 曲线与 0.45→1.0 的 tween（外层照
  /// 本节默认档构造即可，见 `_TaskListSkeleton`）。
  final Animation<double>? pulse;

  @override
  State<OrbitSkeleton> createState() => _OrbitSkeletonState();
}

class _OrbitSkeletonState extends State<OrbitSkeleton>
    with SingleTickerProviderStateMixin {
  /// 自建 ticker（仅 `pulse == null` 时创建）
  AnimationController? _ctrl;

  /// 自建呼吸动画（与 [pulse] 同档：0.45→1.0 + `AppMotion.breathe`）
  Animation<double>? _ownPulse;

  @override
  void initState() {
    super.initState();
    if (widget.pulse != null) return;
    final ctrl = AnimationController(
      vsync: this,
      duration: AppMotion.skeletonPulse,
    )..repeat(reverse: true);
    _ctrl = ctrl;
    _ownPulse = Tween<double>(begin: 0.45, end: 1.0).animate(
      CurvedAnimation(parent: ctrl, curve: AppMotion.breathe),
    );
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    // 呼吸是常驻逐帧动画：挂载期冻结整页背景捕获，加载结束自动放行补录。
    return OrbitCapturePause(
      child: FadeTransition(
        opacity: widget.pulse ?? _ownPulse!,
        child: Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: colors.surfaceSecondary,
            borderRadius: BorderRadius.circular(widget.borderRadius),
          ),
        ),
      ),
    );
  }
}
