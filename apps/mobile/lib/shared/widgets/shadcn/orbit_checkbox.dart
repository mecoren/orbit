import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 任务勾选框（设计系统 v3：shadcn `Checkbox` 承载，方角形态）
///
/// 形态：未完成 = 2px 描边空心**方角**（TickTick 同款，圆角 4px 与桌面端
/// 完成钮 `rounded-[4px]` 跨端同源）；完成 = [OrbitAccents.todoAccent] 实底 +
/// 白色对勾。方角化（2026-09-25）替换原圆形形态——与桌面端对齐竞品口径，
/// 视觉语言仍由 shadcn `Checkbox`（描边/填充/勾选绘制动画）统一承担。
///
/// 与旧实现的差异：**删除了 `checkSize` 参数**（shadcn 的勾选图形随 `size`
/// 等比缩放，单独指定勾选大小已无意义），调用点改为只传 `size`。
/// 历史名 `OrbitCheckbox` 已随方角化更名 [OrbitCheckbox]。
///
/// 完成态（checked）填充走弱化灰（`deactivatedText`）：已完成行整行置灰
///（标题 / 日期 / 元信息同口径），勾选框不再保留待办蓝——未完成态仍是
///空心方框（描边由 [borderColor] 承载优先级语义）。
class OrbitCheckbox extends StatelessWidget {
  const OrbitCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    this.size = AppDimens.taskCheckboxSize,
    this.borderColor,
  });

  /// 方角圆角半径（TickTick 参照；与桌面端 `rounded-[4px]` 同值）
  static const double cornerRadius = 4;

  final bool checked;
  final VoidCallback onToggle;

  /// 未勾选态描边色；null = 组件默认中性灰。
  ///
  /// 任务列表用它承载优先级语义（高/紧急/立即以橙红方环表达，P0「无」
  /// 回落默认灰）——同一信息不再于副标题重复一枚色点（docs/05 §4.5）。
  final Color? borderColor;

  /// 热区外扩下限：勾选是高频精确点击，22–28px 图形热区在密集列表里
  /// 误触率高——布局盒取 `max(size, 44)`、图形居中，可点面积扩到触控
  /// 标准档而视觉直径不变
  static const double minHitExtent = 44;

  /// 外框边长（列表行 24 / 详情标题 28 / 子任务 22；可点热区不小于 44）
  final double size;

  void _handleChanged() {
    // 触感只给「勾选确认」（未选→已选）；点回来取消完成不震（docs/05 §9.1）
    if (!checked) HapticFeedback.selectionClick();
    onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return SizedBox.square(
      dimension: size < minHitExtent ? minHitExtent : size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _handleChanged,
        child: Center(
          child: sh.Checkbox(
            state:
                checked ? sh.CheckboxState.checked : sh.CheckboxState.unchecked,
            size: size,
            borderRadius: BorderRadius.circular(cornerRadius),
            activeColor: colors.deactivatedText,
            borderColor:
                borderColor ?? colors.secondaryText.withValues(alpha: 0.4),
            onChanged: (_) => _handleChanged(),
          ),
        ),
      ),
    );
  }
}
