import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';

/// 骨架占位块（首屏加载态专用，设计系统 v3 原语层）
///
/// 自绘呼吸块，不引入第三方骨架库：
/// - 颜色取 `surfaceSecondary`（与分层表面同源，亮暗自适应）；
/// - 呼吸周期与曲线走 [AppMotion.skeletonPulse] / [AppMotion.breathe]
///  （视图内禁裸 Duration / Curves）；
/// - 仅首屏四处使用（详情 / 统计 / 主列表 / 侧栏的初次加载），且只在
///   "无旧值可守"时出现（有旧值走旧内容，不闪骨架）；次级页与按钮内
///   loading 一律保持 spinner，避免整站闪烁感。
class OrbitSkeleton extends StatefulWidget {
  const OrbitSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.borderRadius = AppShapes.radiusSmall,
  });

  /// 文本行占位（默认宽 120；胶囊圆角）
  const OrbitSkeleton.line({
    super.key,
    this.width = 120,
    this.height = 14,
  }) : borderRadius = height / 2;

  /// 块占位（卡片 / 图区）
  const OrbitSkeleton.block({
    super.key,
    this.width,
    this.height = 96,
    this.borderRadius = AppShapes.radiusMedium,
  });

  /// 圆形占位（复选框 / 色点 / 头像）
  const OrbitSkeleton.circle({
    super.key,
    double size = 20,
  })  : width = size,
        height = size,
        borderRadius = size / 2;

  final double? width;
  final double height;
  final double borderRadius;

  @override
  State<OrbitSkeleton> createState() => _OrbitSkeletonState();
}

class _OrbitSkeletonState extends State<OrbitSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: AppMotion.skeletonPulse,
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return FadeTransition(
      opacity: Tween<double>(begin: 0.45, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: AppMotion.breathe),
      ),
      child: Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: colors.surfaceSecondary,
          borderRadius: BorderRadius.circular(widget.borderRadius),
        ),
      ),
    );
  }
}
