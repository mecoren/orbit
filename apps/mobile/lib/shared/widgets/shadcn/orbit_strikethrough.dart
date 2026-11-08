import 'package:flutter/material.dart';

import '../../../core/theme/app_motion.dart';

/// 完成态标题：删除线自左向右绘制 + 文字色过渡（对齐微软 To-Do 完成反馈）。
///
/// 用法：把原来的 `Text(...)` 换成本组件，[style] 传**未完成态**样式，
/// [doneColor] 传**完成态**颜色（原样式完成态未变色者传同色即可——此时只画线不换色）。
///
/// **公共 API 与旧实现逐字一致**（12 处调用，9 个文件）。
///
/// 为什么不用 `TextDecoration.lineThrough`：原生装饰只能瞬时切换，无法表达绘制进度。
/// 本组件保留真实 [Text] 节点（widget 测试 `find.text` 可见，项目硬约束——不可改为
/// `Text.rich` 或整体 CustomPaint 绘制），只在其上叠一层按行度量绘制的动画横线。
///
/// 设计系统 v3 的实现简化：用 [TweenAnimationBuilder] 取代旧的
/// `AnimationController` + `State` 样板（省掉 `SingleTickerProviderStateMixin`
/// 与 `dispose`）。**首帧即终态**的语义不变——`TweenAnimationBuilder` 首帧直接落在
/// `end`，只在 `end` 变化（即 [done] 真正翻转）的那一次播放，
/// 因此列表虚拟化重建不会重播划线。
///
/// 性能口径（2026-11-08）：文本布局（`TextPainter.layout` + `computeLineMetrics`）
/// 只依赖文本/布局样式/行数上限/宽度/文本缩放/方向，与逐帧插值的**颜色无关**——
/// 布局结果缓存在 State 里，260ms 动画内每帧只画矩形线，不重量文本。此前每帧
/// 一次全量 layout 是行内动画里最贵的一笔（多行标题尤其明显）。
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

  /// 未完成态样式（完成态颜色由 [doneColor] 提供）
  final TextStyle style;

  /// 完成态颜色（删除线与文字同色）
  final Color doneColor;

  final int? maxLines;

  /// 删除线粗细
  final double thickness;

  @override
  State<AnimatedStrikethrough> createState() => _AnimatedStrikethroughState();
}

class _AnimatedStrikethroughState extends State<AnimatedStrikethrough> {
  final _StrikeMetricsCache _cache = _StrikeMetricsCache();

  @override
  Widget build(BuildContext context) {
    // 与 Text 的解析口径一致：显式样式并入环境默认样式后再量文本
    final baseStyle = DefaultTextStyle.of(context).style.merge(widget.style);
    final textScaler = MediaQuery.textScalerOf(context);
    final textDirection = Directionality.of(context);

    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: widget.done ? 1.0 : 0.0),
      duration: AppMotion.strikethrough,
      curve: AppMotion.standard,
      builder: (context, t, _) {
        // 布局样式恒为 baseStyle（颜色不进布局）；只有线与文字的**颜色**逐帧插值
        final color = Color.lerp(
          baseStyle.color ?? widget.doneColor,
          widget.doneColor,
          t,
        )!;
        return Stack(
          children: [
            Text(
              widget.text,
              style: baseStyle.copyWith(color: color),
              maxLines: widget.maxLines,
              overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
            ),
            if (t > 0)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _StrikePainter(
                      text: widget.text,
                      layoutStyle: baseStyle,
                      color: color,
                      maxLines: widget.maxLines,
                      thickness: widget.thickness,
                      progress: t,
                      textDirection: textDirection,
                      textScaler: textScaler,
                      cache: _cache,
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

/// 行度量缓存：布局输入不变时复用 [LineMetrics]，免每帧 `layout` + `computeLineMetrics`
class _StrikeMetricsCache {
  List<LineMetrics>? _lines;
  String? _text;
  TextStyle? _style;
  int? _maxLines;
  double? _width;
  TextDirection? _direction;
  TextScaler? _scaler;

  List<LineMetrics> lines({
    required String text,
    required TextStyle style,
    required int? maxLines,
    required double width,
    required TextDirection direction,
    required TextScaler scaler,
  }) {
    if (_lines != null &&
        text == _text &&
        style == _style &&
        maxLines == _maxLines &&
        width == _width &&
        direction == _direction &&
        scaler == _scaler) {
      return _lines!;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
      textDirection: direction,
      textScaler: scaler,
    )..layout(maxWidth: width);
    // LineMetrics 是纯值快照，painter.dispose 后仍可安全持有
    final result = painter.computeLineMetrics();
    painter.dispose();
    _lines = result;
    _text = text;
    _style = style;
    _maxLines = maxLines;
    _width = width;
    _direction = direction;
    _scaler = scaler;
    return result;
  }
}

/// 按行度量绘制删除线（进度 = 已绘制宽度占比）
class _StrikePainter extends CustomPainter {
  const _StrikePainter({
    required this.text,
    required this.layoutStyle,
    required this.color,
    required this.maxLines,
    required this.thickness,
    required this.progress,
    required this.textDirection,
    required this.textScaler,
    required this.cache,
  });

  final String text;

  /// 布局样式（不含逐帧色；颜色由 [color] 单独传）
  final TextStyle layoutStyle;

  /// 本帧线色（与 Text 同步插值）
  final Color color;

  final int? maxLines;
  final double thickness;
  final double progress;
  final TextDirection textDirection;
  final TextScaler textScaler;

  /// 布局缓存宿主（State 持有，动画跨帧复用）
  final _StrikeMetricsCache cache;

  /// 线位置相对基线的纵向偏移（em 倍数）；接近引擎 lineThrough 落点
  static const double _baselineOffsetRatio = 0.33;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || size.width <= 0 || size.height <= 0) return;

    final lines = cache.lines(
      text: text,
      style: layoutStyle,
      maxLines: maxLines,
      width: size.width,
      direction: textDirection,
      scaler: textScaler,
    );

    final paint = Paint()..color = color;
    final offset = (layoutStyle.fontSize ?? 14) * _baselineOffsetRatio;
    for (final line in lines) {
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
  }

  @override
  bool shouldRepaint(_StrikePainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.text != text ||
      oldDelegate.layoutStyle != layoutStyle ||
      oldDelegate.color != color ||
      oldDelegate.maxLines != maxLines ||
      oldDelegate.thickness != thickness;
}
