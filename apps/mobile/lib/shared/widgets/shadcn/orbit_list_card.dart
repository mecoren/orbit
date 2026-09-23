import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';

/// 列表卡片分段位置（[OrbitCardSegment.edge] 取值）
enum OrbitCardEdge {
  /// 扁平行：不画卡面与描边（看板 / 表格 / 搜索等非卡片列表沿用）
  none,
  first,
  middle,
  last,
  single;

  /// 按「同卡内下标 / 卡内段数」推段位（单段即 [single]，首末各自圆角）
  static OrbitCardEdge of(int index, int count) {
    if (count <= 1) return OrbitCardEdge.single;
    if (index <= 0) return OrbitCardEdge.first;
    if (index >= count - 1) return OrbitCardEdge.last;
    return OrbitCardEdge.middle;
  }
}

/// 列表卡片分段（设计系统 v3 原语层）
///
/// **为什么按段拼而不整卡包裹**：任务列表是懒加载的 `ListView.builder` /
/// `ReorderableListView`，把整列行塞进一个 `Container` 会让万行任务一次性
/// 建成实体，破坏虚拟化（内存纪律）。故卡片由每行自带的分段拼出——
/// 首段圆上角、末段圆下角、中段只留左右描边，段间 1px `divider`；
/// 外描边用 `outline`（卡片边界）与内部 `divider` 区分开，外缘圆角
/// [AppShapes.radiusMedium] 与 [OrbitCard] 同口径。
///
/// **描边不用 `BoxDecoration.border`**：非均匀 `Border` 与 `borderRadius`
/// 不能共存（Flutter 断言），且相邻两段各自画横边会叠成 2px 实线；
/// 这里用 [CustomPaint] 精确决定每段画哪几条边，内部横线只在下沿画一次。
///
/// [OrbitCardEdge.none] 时原样返回 [child]（零额外层级），非卡片场景无开销。
class OrbitCardSegment extends StatelessWidget {
  const OrbitCardSegment({
    super.key,
    required this.edge,
    required this.child,
    this.radius = AppShapes.radiusMedium,
  });

  final OrbitCardEdge edge;
  final Widget child;

  /// 外缘圆角（默认与 [OrbitCard] 的 medium 同值）
  final double radius;

  @override
  Widget build(BuildContext context) {
    if (edge == OrbitCardEdge.none) return child;
    final colors = AppColors.ofContext(context);
    return CustomPaint(
      painter: _SegmentBorderPainter(
        edge: edge,
        fill: colors.surface,
        outline: colors.outline,
        divider: colors.divider,
        radius: radius,
      ),
      child: child,
    );
  }
}

class _SegmentBorderPainter extends CustomPainter {
  const _SegmentBorderPainter({
    required this.edge,
    required this.fill,
    required this.outline,
    required this.divider,
    required this.radius,
  });

  final OrbitCardEdge edge;
  final Color fill;
  final Color outline;
  final Color divider;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final hasTop = edge == OrbitCardEdge.first || edge == OrbitCardEdge.single;
    final hasBottom =
        edge == OrbitCardEdge.last || edge == OrbitCardEdge.single;
    final r = math.min(radius, math.min(w, h) / 2);

    // 卡面：整段填充，只在外缘切圆角
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(0, 0, w, h),
        topLeft: hasTop ? Radius.circular(r) : Radius.zero,
        topRight: hasTop ? Radius.circular(r) : Radius.zero,
        bottomLeft: hasBottom ? Radius.circular(r) : Radius.zero,
        bottomRight: hasBottom ? Radius.circular(r) : Radius.zero,
      ),
      Paint()..color = fill,
    );

    // 1px 描边按 0.5 内缩走线，避免半像素发虚
    const inset = 0.5;
    final left = inset;
    final right = w - inset;
    final top = inset;
    final bottom = h - inset;
    final rr = math.max(0.0, r - inset);
    final corner = Radius.circular(rr);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline;

    if (edge == OrbitCardEdge.single) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(left, top, right, bottom),
          corner,
        ),
        stroke,
      );
      return;
    }

    final path = Path();
    if (hasTop) {
      // 左下开口 → 左竖线 → 上圆角 → 顶边 → 上圆角 → 右竖线
      path
        ..moveTo(left, bottom)
        ..lineTo(left, top + rr)
        ..arcToPoint(Offset(left + rr, top),
            radius: corner, clockwise: true)
        ..lineTo(right - rr, top)
        ..arcToPoint(Offset(right, top + rr),
            radius: corner, clockwise: true)
        ..lineTo(right, bottom);
    } else if (hasBottom) {
      // 上开口 → 左竖线 → 下圆角 → 底边 → 下圆角 → 右竖线
      path
        ..moveTo(left, top)
        ..lineTo(left, bottom - rr)
        ..arcToPoint(Offset(left + rr, bottom),
            radius: corner, clockwise: false)
        ..lineTo(right - rr, bottom)
        ..arcToPoint(Offset(right, bottom - rr),
            radius: corner, clockwise: false)
        ..lineTo(right, top);
    } else {
      // 中段：仅左右描边
      path
        ..moveTo(left, top)
        ..lineTo(left, bottom)
        ..moveTo(right, top)
        ..lineTo(right, bottom);
    }
    canvas.drawPath(path, stroke);

    // 段间横线：每段只画自己的下沿，相邻两段不叠线（末段改由底边描边收口）
    if (!hasBottom) {
      canvas.drawLine(
        Offset(left, bottom),
        Offset(right, bottom),
        Paint()
          ..strokeWidth = 1
          ..color = divider,
      );
    }
  }

  @override
  bool shouldRepaint(_SegmentBorderPainter old) =>
      old.edge != edge ||
      old.fill != fill ||
      old.outline != outline ||
      old.divider != divider ||
      old.radius != radius;
}
