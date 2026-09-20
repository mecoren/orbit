import 'package:flutter/material.dart';

import '../../core/theme/app_motion.dart';

/// 完成态标题文本：删除线自左向右绘制 + 文字色过渡（对齐微软 To-Do 完成反馈）
///
/// 用法：把原来的 `Text(...)` 换成本组件，[style] 传**未完成态**样式，
/// [doneColor] 传**完成态**颜色（原样式完成态未变色者传同色即可——此时只画线不换色）。
///
/// 为什么不用 `TextDecoration.lineThrough`：原生装饰只能瞬时切换，无法表达绘制进度。
/// 本组件保留真实 [Text] 节点（widget 测试 `find.text` 可见，项目硬约束——不可改为
/// `Text.rich`/`CustomPaint` 整体绘制），只在其上叠一层按行度量绘制的动画横线。
///
/// 唯一状态是进度控制器，且**初值即终态**（[done] 为真时直接 1）：列表虚拟化重建
/// 不会重播划线，只在 [done] 真正翻转的那一次播放。
class AnimatedStrikethrough extends StatefulWidget {
  const AnimatedStrikethrough({
    super.key,
    required this.text,
    required this.done,
    required this.style,
    required this.doneColor,
    this.maxLines,
    this.thickness = 1.5,
  });

  final String text;
  final bool done;

  /// 未完成态样式（字号/字重/行高/未完成色）
  final TextStyle style;

  /// 完成态文字颜色
  final Color doneColor;

  /// 行数上限（null = 不限行，与原 `Text` 默认一致）
  final int? maxLines;

  /// 删除线粗细
  final double thickness;

  @override
  State<AnimatedStrikethrough> createState() => _AnimatedStrikethroughState();
}

class _AnimatedStrikethroughState extends State<AnimatedStrikethrough>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.strikethrough,
    value: widget.done ? 1 : 0,
  );
  late final Animation<double> _progress =
      CurvedAnimation(parent: _controller, curve: AppMotion.standard);

  @override
  void didUpdateWidget(covariant AnimatedStrikethrough oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.done != oldWidget.done) {
      widget.done ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 与 Text 的解析口径一致：显式样式并入环境默认样式后再量文本
    final baseStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return AnimatedBuilder(
      animation: _progress,
      builder: (context, _) {
        final t = _progress.value;
        final style = baseStyle.copyWith(
          color: Color.lerp(
            baseStyle.color ?? widget.doneColor,
            widget.doneColor,
            t,
          ),
        );
        return Stack(
          children: [
            Text(
              widget.text,
              style: style,
              maxLines: widget.maxLines,
              overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
            ),
            if (t > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _StrikePainter(
                      text: widget.text,
                      style: style,
                      maxLines: widget.maxLines,
                      thickness: widget.thickness,
                      progress: t,
                      textDirection: textDirection,
                      textScaler: textScaler,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 按行度量绘制删除线（进度 = 已绘制宽度占比）
class _StrikePainter extends CustomPainter {
  const _StrikePainter({
    required this.text,
    required this.style,
    required this.maxLines,
    required this.thickness,
    required this.progress,
    required this.textDirection,
    required this.textScaler,
  });

  final String text;
  final TextStyle style;
  final int? maxLines;
  final double thickness;
  final double progress;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// 线位置相对基线的纵向偏移（em 倍数）；接近引擎 lineThrough 落点
  static const double _baselineOffsetRatio = 0.33;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || size.width <= 0 || size.height <= 0) return;

    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
      textDirection: textDirection,
      textScaler: textScaler,
    )..layout(maxWidth: size.width);

    final paint = Paint()..color = style.color ?? const Color(0xFF000000);
    final offset = (style.fontSize ?? 14) * _baselineOffsetRatio;
    for (final line in painter.computeLineMetrics()) {
      final width = line.width * progress;
      if (width <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          line.left,
          line.baseline - offset - thickness / 2,
          width,
          thickness,
        ),
        paint,
      );
    }
    painter.dispose();
  }

  @override
  bool shouldRepaint(_StrikePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.text != text ||
      oldDelegate.style != style ||
      oldDelegate.maxLines != maxLines ||
      oldDelegate.thickness != thickness;
}
