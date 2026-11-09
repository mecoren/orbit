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

  /// 卡面四角半径（纯函数）：段位决定上下，侧滑抹平侧决定左右。
  ///
  /// `squareLeft/squareRight` 供侧滑时把接缝侧两角抹成 0——行卡圆角会随行
  /// 平移到接缝处，不抹平就会与动作面板的直边之间凹出月牙缝（见
  /// [OrbitCardEdgeSwipeActionRadius]）。抽成纯函数便于 painter 与测试共用。
  ({double topLeft, double topRight, double bottomLeft, double bottomRight})
      cornerRadii(
    double radius, {
    bool squareLeft = false,
    bool squareRight = false,
  }) {
    final hasTop = this == OrbitCardEdge.first || this == OrbitCardEdge.single;
    final hasBottom = this == OrbitCardEdge.last || this == OrbitCardEdge.single;
    return (
      topLeft: hasTop && !squareLeft ? radius : 0.0,
      topRight: hasTop && !squareRight ? radius : 0.0,
      bottomLeft: hasBottom && !squareLeft ? radius : 0.0,
      bottomRight: hasBottom && !squareRight ? radius : 0.0,
    );
  }
}

/// 侧滑动作面板的圆角口径（2026-11-09 真机反馈）
///
/// `SlidableAction` 的 `borderRadius` 会套在整个动作按钮的 `shape` 上；四角全圆
/// 时**贴行的内侧**也圆进去，与行的直边之间露出一条月牙状页面底色，看着像
/// 两块断开的卡片。口径：内侧一律直边，外侧只在该段本身有外缘圆角时跟随
/// （首段上、末段下、单段上下），动作面板与行拼起来仍是同一张卡。
extension OrbitCardEdgeSwipeActionRadius on OrbitCardEdge {
  /// [startPane] = 右滑露出的 `startActionPane`（面板靠左，内侧是右沿）；
  /// false = 左滑露出的 `endActionPane`（面板靠右，内侧是左沿）。
  BorderRadius swipeActionRadius({required bool startPane}) {
    final hasTop = this == OrbitCardEdge.first || this == OrbitCardEdge.single;
    final hasBottom =
        this == OrbitCardEdge.last || this == OrbitCardEdge.single;
    final radius = Radius.circular(AppShapes.radiusMedium);
    return BorderRadius.only(
      topLeft: startPane && hasTop ? radius : Radius.zero,
      bottomLeft: startPane && hasBottom ? radius : Radius.zero,
      topRight: !startPane && hasTop ? radius : Radius.zero,
      bottomRight: !startPane && hasBottom ? radius : Radius.zero,
    );
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
    this.squareLeft = false,
    this.squareRight = false,
  });

  final OrbitCardEdge edge;
  final Widget child;

  /// 外缘圆角（默认与 [OrbitCard] 的 medium 同值）
  final double radius;

  /// 侧滑时把左侧两角抹平（接缝侧），见 [OrbitCardEdge.swipeActionRadius]。
  /// 行卡的外缘圆角会随行一起平移，落在与动作面板相接的一侧就会凹出月牙缝；
  /// 面板打开时由 `OrbitSwipeCardSegment` 按方位置位，收起后恢复整卡圆角。
  final bool squareLeft;
  final bool squareRight;

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
        squareLeft: squareLeft,
        squareRight: squareRight,
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
    required this.squareLeft,
    required this.squareRight,
  });

  final OrbitCardEdge edge;
  final Color fill;
  final Color outline;
  final Color divider;
  final double radius;
  final bool squareLeft;
  final bool squareRight;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;
    final hasTop = edge == OrbitCardEdge.first || edge == OrbitCardEdge.single;
    final hasBottom =
        edge == OrbitCardEdge.last || edge == OrbitCardEdge.single;
    final r = math.min(radius, math.min(w, h) / 2);
    // 四角半径逐角决定：侧滑时贴动作面板的一侧抹成 0，接缝才是直边
    final corners = edge.cornerRadii(
      r,
      squareLeft: squareLeft,
      squareRight: squareRight,
    );
    final topLeft = corners.topLeft;
    final topRight = corners.topRight;
    final bottomLeft = corners.bottomLeft;
    final bottomRight = corners.bottomRight;

    // 卡面：整段填充，只在外缘切圆角
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(0, 0, w, h),
        topLeft: Radius.circular(topLeft),
        topRight: Radius.circular(topRight),
        bottomLeft: Radius.circular(bottomLeft),
        bottomRight: Radius.circular(bottomRight),
      ),
      Paint()..color = fill,
    );

    // 1px 描边按 0.5 内缩走线，避免半像素发虚
    const inset = 0.5;
    final left = inset;
    final right = w - inset;
    final top = inset;
    final bottom = h - inset;
    double cornerOf(double value) => math.max(0.0, value - inset);
    final tl = cornerOf(topLeft);
    final tr = cornerOf(topRight);
    final bl = cornerOf(bottomLeft);
    final br = cornerOf(bottomRight);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = outline;

    if (edge == OrbitCardEdge.single) {
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(left, top, right, bottom),
          topLeft: Radius.circular(tl),
          topRight: Radius.circular(tr),
          bottomLeft: Radius.circular(bl),
          bottomRight: Radius.circular(br),
        ),
        stroke,
      );
      return;
    }

    final path = Path();
    if (hasTop) {
      // 左下开口 → 左竖线 → 上圆角 → 顶边 → 上圆角 → 右竖线
      //（圆角半径为 0 时直接走直线，接缝侧不画弧）
      path.moveTo(left, bottom);
      if (tl > 0) {
        path
          ..lineTo(left, top + tl)
          ..arcToPoint(Offset(left + tl, top),
              radius: Radius.circular(tl), clockwise: true);
      } else {
        path.lineTo(left, top);
      }
      if (tr > 0) {
        path
          ..lineTo(right - tr, top)
          ..arcToPoint(Offset(right, top + tr),
              radius: Radius.circular(tr), clockwise: true);
      } else {
        path.lineTo(right, top);
      }
      path.lineTo(right, bottom);
    } else if (hasBottom) {
      // 上开口 → 左竖线 → 下圆角 → 底边 → 下圆角 → 右竖线
      path.moveTo(left, top);
      if (bl > 0) {
        path
          ..lineTo(left, bottom - bl)
          ..arcToPoint(Offset(left + bl, bottom),
              radius: Radius.circular(bl), clockwise: false);
      } else {
        path.lineTo(left, bottom);
      }
      if (br > 0) {
        path
          ..lineTo(right - br, bottom)
          ..arcToPoint(Offset(right, bottom - br),
              radius: Radius.circular(br), clockwise: false);
      } else {
        path.lineTo(right, bottom);
      }
      path.lineTo(right, top);
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
      old.radius != radius ||
      old.squareLeft != squareLeft ||
      old.squareRight != squareRight;
}
