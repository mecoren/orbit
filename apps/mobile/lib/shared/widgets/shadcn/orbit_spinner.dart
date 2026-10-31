import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/orbit_accents.dart';

// ── 几何比例（HyperOS `InfiniteProgressIndicator` 同源口径）──
// 全部按边长比例表达，任意 [OrbitSpinner.size] 下观感一致；禁止改成裸数字
//（布局尺寸一律走 token / 具名常量，见 AGENTS.md）。
/// 环描边宽度 / 边长（Miuix 默认 2/20 = 0.1，取 0.08 与本仓更细的图标线宽同档）
const double _kSpinnerStrokeRatio = 0.08;

/// 绕行点半径 / 边长（Miuix 默认 2/20 = 0.1）
const double _kSpinnerDotRatio = 0.10;

/// 加载指示器（原语层：flutter_miuix `MiuixInfiniteProgressIndicator` 承载）
///
/// **2026-10-31 换承载**：原实现是自绘 CustomPainter（细环 + 绕行实心点），
/// 现改为 HyperOS 的 `MiuixInfiniteProgressIndicator`——同一套「静止细环 +
/// 环内绕行圆点」语义，但描边圆头、点尺寸与轨道内缩按 miuix 原版标定
/// （源端 Compose `InfiniteProgressIndicator`），是系统加载态的直观观感对齐。
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
///
/// **动效时长不再可配**：HyperOS 版本把绕行周期固定在库内（800ms），旧实现
/// 的 `duration` 参数（唯一调用点是测试）随之移除——周期是 miuix 观感的一部分，
/// 逐处可调只会让加载态在页面之间不一致。
class OrbitSpinner extends StatelessWidget {
  const OrbitSpinner({
    super.key,
    this.size = 20,
    this.color,
    this.semanticLabel,
  });

  /// 方形边长。按钮内 16~18，内容区居中 24~32，遮罩 40~50。
  final double size;

  /// 前景色（点与环都基于它）。null → [OrbitAccents.themeAccent]。
  ///
  /// 渲染在主题色按钮、深色图片遮罩等深底上时**必须**显式传，
  /// 否则默认色可能与底色撞色而看不见。
  final Color? color;

  /// 无障碍标签。null → 库内置的「进度」语义。
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final child = MiuixInfiniteProgressIndicator(
      color: color ?? OrbitAccents.themeAccent,
      size: size,
      strokeWidth: size * _kSpinnerStrokeRatio,
      orbitingDotSize: size * _kSpinnerDotRatio,
    );
    final label = semanticLabel;
    if (label == null) return child;
    // 库内已包 `Semantics(label: '进度')`：调用方给了更具体的文案时，用
    // [ExcludeSemantics] 把内层丢掉再挂自己的标签，避免读屏把「进度」与
    // 调用方文案播报两遍（合并成「正在加载\n进度」同样别扭）。
    return Semantics(
      label: label,
      liveRegion: true,
      child: ExcludeSemantics(child: child),
    );
  }
}

/// 组件几何（供测试与文档读取，避免在断言里硬编码裸数字）
abstract final class OrbitSpinnerMetrics {
  /// 环描边宽度 / 边长
  static const double strokeRatio = _kSpinnerStrokeRatio;

  /// 绕行点半径 / 边长
  static const double dotRatio = _kSpinnerDotRatio;

  /// 给定边长下的实际描边宽度
  static double strokeWidthOf(double size) => size * strokeRatio;
}
