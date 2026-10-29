import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';
import '../../../core/theme/orbit_accents.dart';

// ── 几何比例（与参考实现 PiggyCount `piggy_spinner.dart` 同源）──
// 全部按环半径 / 边长比例表达，任意 [OrbitSpinner.size] 下观感一致；
// 禁止改成裸数字（布局尺寸一律走 token / 具名常量，见 AGENTS.md）。
/// 环描边宽度 / 边长。
const double _kSpinnerStrokeRatio = 0.08;

/// 点心到圆心的距离 / 环半径。
const double _kSpinnerOrbitRatio = 0.42;

/// 点半径 / 环半径。
const double _kSpinnerDotRatio = 0.34;

/// 轨道（环）相对前景色的透明度；点用实色，两者拉开层次。
const double _kSpinnerTrackAlpha = 0.28;

/// 加载指示器（设计系统 v3 原语层）：静止的细环 + 一个沿环内轨道匀速绕行的实心点。
///
/// 与 [CircularProgressIndicator] 的区别是**不画进度弧** —— 环只作轨道，
/// 动效全在点上。因此它只能表达「在动」，无法表达「完成了多少」。
///
/// 口径：凡是「不定态、只表示正在转」的加载动效一律用本组件，
/// 不要在各页手写 [CircularProgressIndicator]（尺寸/描边曾一度散出六档）。
/// 组件自带方形占位，调用方直接替换即可，无需在外面套 [SizedBox]。
///
/// ```dart
/// // 内容区居中
/// const Center(child: OrbitSpinner(size: 24))
/// // 主题色按钮内（白色）
/// const OrbitSpinner(size: 16, color: Colors.white)
/// ```
///
/// **不要**用它替代语义进度：有确切百分比的东西（预算 / 额度 / 下载进度 /
/// 同步 checked/total 环）继续用 [LinearProgressIndicator] 或带 `value` 的
/// [CircularProgressIndicator]，换掉会丢失进度信息。
class OrbitSpinner extends StatefulWidget {
  const OrbitSpinner({
    super.key,
    this.size = 20,
    this.color,
    this.duration = AppMotion.spinnerOrbit,
    this.semanticLabel,
  });

  /// 方形边长。按钮内 16~18，内容区居中 24~32，遮罩 40~50。
  final double size;

  /// 前景色（点与环都基于它）。null → [OrbitAccents.themeAccent]。
  ///
  /// 渲染在主题色按钮、深色图片遮罩等深底上时**必须**显式传，
  /// 否则默认色可能与底色撞色而看不见。
  final Color? color;

  /// 点绕行一圈的时长。
  final Duration duration;

  /// 无障碍标签。null → 不包 [Semantics]。
  final String? semanticLabel;

  @override
  State<OrbitSpinner> createState() => _OrbitSpinnerState();
}

class _OrbitSpinnerState extends State<OrbitSpinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat();

  @override
  void didUpdateWidget(covariant OrbitSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.duration != oldWidget.duration) {
      _controller.duration = widget.duration;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _OrbitSpinnerPainter(
            color: widget.color ?? OrbitAccents.themeAccent,
            strokeWidth: widget.size * _kSpinnerStrokeRatio,
            animation: _controller,
          ),
        ),
      ),
    );
    final label = widget.semanticLabel;
    if (label == null) return child;
    return Semantics(label: label, liveRegion: true, child: child);
  }
}

/// 动画经 `super(repaint:)` 驱动重绘，**不触发 setState / rebuild**。
class _OrbitSpinnerPainter extends CustomPainter {
  _OrbitSpinnerPainter({
    required this.color,
    required this.strokeWidth,
    required this.animation,
  }) : super(repaint: animation);

  final Color color;
  final double strokeWidth;
  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    // 轨道：低透明度细环，不画进度弧。
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color.withValues(alpha: _kSpinnerTrackAlpha),
    );

    // 绕行点：12 点方向起、顺时针匀速。
    final angle = animation.value * 2 * math.pi - math.pi / 2;
    final dotCenter = center +
        Offset(math.cos(angle), math.sin(angle)) *
            (radius * _kSpinnerOrbitRatio);
    canvas.drawCircle(
        dotCenter, radius * _kSpinnerDotRatio, Paint()..color = color);
  }

  /// 相位变化不走这里 —— 由 `super(repaint: animation)` 通知重绘。
  @override
  bool shouldRepaint(covariant _OrbitSpinnerPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}
