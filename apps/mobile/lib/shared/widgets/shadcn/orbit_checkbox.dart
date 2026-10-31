import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/miuix_theme.dart';

/// 任务勾选框（原语层：flutter_miuix `MiuixCheckbox` 承载，圆形 HyperOS 形态）
///
/// **2026-10-31 换承载**：勾选框从 shadcn `Checkbox`（方角空心方框）改为
/// HyperOS 的 [MiuixCheckbox]——圆形底 + 描画式对勾（对勾路径按 `trim` 逐帧
/// 生长，源端 Compose `Checkbox` 同款动效），并自带 `MiuixPressable` 的
/// **下沉按压反馈**（按下时整体缩到 0.85 再回弹）。
///
/// **有意保留的语义差异**（避免误读为"漏改"）：
/// - 方角 → 圆角：HyperOS 勾选框就是圆形，这是本组件库最核心的形态语言之一；
/// - 完成态填充色仍是 [AppColorSet.deactivatedText]（弱化灰），**不**取
///   miuix 的 `primary`：仓库口径「已完成行整行置灰」是跨端一致的既有语义
///   （docs/05 §4.5），换成强调蓝会让已完成行重新抢眼（`done_gray_test` 锁定）。
/// - 未勾选态描边色仍由 [borderColor] 承载优先级语义（高/紧急/立即橙红环）。
///
/// **热区**：`MiuixCheckbox` 固定 26dp 图形且不自带外扩热区，本组件仍保留
/// 旧实现的 `max(size, 44)` 布局盒 + 图形居中——勾选是高频精确点击，
/// 22–28px 图形在密集列表里误触率高。
class OrbitCheckbox extends StatelessWidget {
  const OrbitCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    this.size = AppDimens.taskCheckboxSize,
    this.borderColor,
  });

  /// 视觉圆角半径（旧方角口径的兼容常量；HyperOS 勾选框恒为圆形，
  /// 保留符号供既有调用点/文档引用，不再参与绘制）
  static const double cornerRadius = 4;

  /// 热区外扩下限：勾选是高频精确点击，22–28px 图形热区在密集列表里
  /// 误触率高——布局盒取 `max(size, 44)`、图形居中，可点面积扩到触控
  /// 标准档而视觉直径不变
  static const double minHitExtent = 44;

  final bool checked;
  final VoidCallback onToggle;

  /// 未勾选态描边色；null = 组件默认中性灰。
  ///
  /// 任务列表用它承载优先级语义（高/紧急/立即以橙红圆环表达，P0「无」
  /// 回落默认灰）——同一信息不再于副标题重复一枚色点（docs/05 §4.5）。
  final Color? borderColor;

  /// 视觉直径（列表行 20 / 详情标题 28 / 子任务 22；可点热区不小于 44）
  final double size;

  void _handleChanged() {
    // 触感只给「勾选确认」（未选→已选）；点回来取消完成不震（docs/05 §9.1）。
    //
    // 注意：`MiuixCheckbox` 内部在每次切换时自己发 `HapticFeedback.lightImpact()`。
    // 本层**不再**补 `selectionClick()`——叠加会让"确认"变成两下震感；
    // 库内那次 lightImpact 语义上就是勾选框的确认反馈，取消完成时同样震一下
    // 属于上游行为（若后续要严格区分，需在库侧加开关，不在本层硬抵消）。
    onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final mColors = buildMiuixColors(Theme.of(context).brightness);
    // 未勾选态的"空心圆环"：MiuixCheckbox 的未选中态只画填充色 + 对勾，
    // 没有描边参数，故把环单独画在它下面（勾选后灰底实心圆直接盖住环）。
    final ringColor =
        borderColor ?? colors.secondaryText.withValues(alpha: 0.4);
    return SizedBox.square(
      dimension: size < minHitExtent ? minHitExtent : size,
      child: Center(
        child: SizedBox.square(
          dimension: size,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (!checked)
                CustomPaint(
                  painter: _CheckboxRingPainter(
                    color: ringColor,
                    strokeWidth: size >= 24 ? 2 : 1.5,
                  ),
                ),
              MiuixCheckbox(
                value: checked,
                onChanged: (_) => _handleChanged(),
                colors: MiuixCheckboxColors(
                  // 勾选：弱化灰底 + 白勾（已完成行整行置灰口径）
                  checkedBackgroundColor: colors.deactivatedText,
                  checkedForegroundColor: mColors.onPrimary,
                  // 未勾选：透明底（露出下面的优先级圆环）
                  uncheckedBackgroundColor: Colors.transparent,
                  uncheckedForegroundColor: Colors.transparent,
                  disabledCheckedBackgroundColor: colors.deactivatedText,
                  disabledCheckedForegroundColor: mColors.onPrimary,
                  disabledUncheckedBackgroundColor: Colors.transparent,
                  disabledUncheckedForegroundColor: Colors.transparent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 未勾选态圆环（2px 描边，与桌面端方框 2px 描边同档；小尺寸档收窄到 1.5）
class _CheckboxRingPainter extends CustomPainter {
  const _CheckboxRingPainter({required this.color, required this.strokeWidth});

  final Color color;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final inset = strokeWidth / 2;
    canvas.drawOval(
      Rect.fromLTWH(inset, inset, size.width - strokeWidth,
          size.height - strokeWidth),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_CheckboxRingPainter old) =>
      old.color != color || old.strokeWidth != strokeWidth;
}
