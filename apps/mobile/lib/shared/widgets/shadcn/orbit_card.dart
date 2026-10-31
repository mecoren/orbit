import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/miuix_theme.dart';

/// 基础卡片（原语层：flutter_miuix `MiuixCard` 承载）
///
/// **2026-10-31 换承载**：卡面从 shadcn `Card`（直角圆角矩形）改为
/// [MiuixCard]——HyperOS 的标志性 **squircle 超椭圆圆角**（`MiuixSquircleBorder`），
/// 同一尺寸下比普通圆角更"方中带圆"，是 miuix 语言最直观的一处观感差异。
/// 表面分层/描边/阴影口径**保持不变**：1px `outline` 描边 + `surface` 填充，
/// **不投阴影**（深度靠描边与表面分层表达，阴影只留给浮层，见 AppElevation）。
///
/// [MiuixCard] 没有独立的描边参数（它只吃 `colors.color` + `contentColor`），
/// 故描边在卡面之上叠一层 [CustomPaint]（`_CardOutlinePainter`）——用
/// [MiuixSquircleBorder] 同一套超椭圆路径描边，保证描边与卡面圆角**逐像素同形**
/// （用普通 `RoundedRectangleBorder` 描边会在四个角露出直角/圆角错位）。
///
/// [fillColor] 缺省 `surface`；次级行（备份条目/标签行/冲突卡等）用
/// `surfaceSecondary`，内嵌对比盒用 `background`——填充分层保留。
/// [borderColor] 缺省 `outline`，选中态等场景传强调色覆盖。
///
/// 公共 API 与旧实现逐字一致（`child` / `padding` / `borderRadius` /
/// `fillColor` / `borderColor`），调用点零改动。
class OrbitCard extends StatelessWidget {
  const OrbitCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppDimens.cardPadding),
    this.borderRadius = AppShapes.medium,
    this.fillColor,
    this.borderColor,
  });

  final Widget child;

  /// 内边距（默认卡片标准垫 `cardPadding`）
  final EdgeInsetsGeometry padding;

  /// 圆角（默认 medium；取统一圆角半径供超椭圆与描边共用）
  final BorderRadiusGeometry borderRadius;

  /// 填充色（默认 `surface`）
  final Color? fillColor;

  /// 描边色（默认 `outline`；选中态等场景传强调色覆盖）
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final radius = _radiusOf(borderRadius);
    final mColors = buildMiuixColors(Theme.of(context).brightness);
    return CustomPaint(
      foregroundPainter: _CardOutlinePainter(
        radius: radius,
        color: borderColor ?? colors.outline,
      ),
      child: MiuixCard(
        cornerRadius: radius,
        insideMargin: padding,
        colors: MiuixCardColors(
          color: fillColor ?? colors.surface,
          contentColor: mColors.onSurfaceContainer,
        ),
        child: child,
      ),
    );
  }

  /// [BorderRadiusGeometry] → 统一半径（squircle 只吃单一 `cornerRadius`）
  ///
  /// 调用点传的都是一致的 [BorderRadius]（`AppShapes.*` 或 `BorderRadius.circular`），
  /// 故取左上角即可；传 `BorderRadius.zero` 时 `MiuixCard` 自动关闭超椭圆
  /// （`cornerRadius > 0` 判据）。
  static double _radiusOf(BorderRadiusGeometry geometry) {
    if (geometry is BorderRadius) return geometry.topLeft.x;
    return geometry.resolve(TextDirection.ltr).topLeft.x;
  }
}

/// 超椭圆描边（与 [MiuixCard] 的卡面路径同形）
///
/// 为什么用 `foregroundPainter`：描边必须压在卡面之上、内容之下，
/// `foregroundPainter` 正好画在子树之后（不遮内容文字）。
class _CardOutlinePainter extends CustomPainter {
  const _CardOutlinePainter({required this.radius, required this.color});

  final double radius;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final shape = MiuixSquircleBorder(
      cornerRadius: radius,
      enabled: radius > 0,
    );
    final rrect = shape.getOuterPath(Offset.zero & size);
    // 1px 走线内缩 0.5，避免半像素发虚（与 OrbitCardSegment 同口径）
    canvas.drawPath(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CardOutlinePainter old) =>
      old.radius != radius || old.color != color;
}
