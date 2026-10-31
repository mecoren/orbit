import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';

/// 线性进度条（原语层：flutter_miuix `MiuixLinearProgressIndicator` 承载）
///
/// **2026-10-31 新增**：此前 5 处直接用 Material `LinearProgressIndicator`
/// （CSV 导入、节假日范围补写、子任务完成度、分诊队列进度、同步进度条），
/// 圆角/高度/底色散在各自 `ClipRRect` + `minHeight` 里，观感不统一。
///
/// 本原语把口径收成三件事：
/// - **圆头胶囊**：Miuix 的画法本身就是圆头，外层不再需要 `ClipRRect`；
/// - **确定态**（[value] 非空）：按比例填充，进度为 0 时仍保留一枚圆头胶囊
///   （HyperOS 的语义，避免"进度 0 看起来像没渲染"）；
/// - **不定态**（[value] 为 null）：库内 1250ms 线性循环动画。
///
/// [color] 缺省走主题强调色；子任务完成度等语义色场景显式传。
class OrbitProgressBar extends StatelessWidget {
  const OrbitProgressBar({
    super.key,
    this.value,
    this.color,
    this.trackColor,
    this.height = 6,
  });

  /// 0..1 的确定进度；null = 不定态循环
  final double? value;

  /// 前景（进度）色，null → 主题强调色
  final Color? color;

  /// 轨道底色，null → `surfaceSecondary`
  final Color? trackColor;

  /// 进度条高度（6 = 内容区标准档，3~4 = 行内极细档）
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final foreground = color ?? colors.accent;
    return MiuixLinearProgressIndicator(
      progress: value?.clamp(0.0, 1.0),
      height: height,
      colors: MiuixProgressIndicatorColors(
        foregroundColor: foreground,
        disabledForegroundColor: colors.deactivatedText,
        backgroundColor: trackColor ?? colors.surfaceSecondary,
      ),
    );
  }
}

/// 兼容常量：旧 Material 进度条的圆角（Miuix 版本自带圆头，仅供文档/测试引用）
const BorderRadius kOrbitProgressBarRadius = AppShapes.full;

/// 语义色快捷入口（子任务完成度等）：保留 `MiuixProgressIndicatorColors` 的
/// 构造口径，避免调用点重复拼三色
MiuixProgressIndicatorColors orbitProgressColors(
  BuildContext context, {
  Color? foreground,
  Color? background,
}) {
  final colors = AppColors.ofContext(context);
  return MiuixProgressIndicatorColors(
    foregroundColor: foreground ?? colors.accent,
    disabledForegroundColor: colors.deactivatedText,
    backgroundColor: background ?? colors.surfaceSecondary,
  );
}

