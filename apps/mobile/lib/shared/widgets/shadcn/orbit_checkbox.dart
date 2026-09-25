import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';

/// 任务勾选框（设计系�?v3：shadcn `Checkbox` 承载，圆形形态保留）
///
/// 形态：未完�?= 1px 描边空心圆；完成 = [OrbitAccents.todoAccent] 实底 + 白色对勾�?
/// 圆形（而非 shadcn 默认的方角）是待办列表的既有交互识别，通过
/// `borderRadius: BorderRadius.circular(size / 2)` 表达，视觉语言仍由 shadcn �?
/// `Checkbox`（描�?填充/勾选绘�?动画）统一承担�?
///
/// 与旧实现的差异：**删除�?`checkSize` 参数**（shadcn 的勾选图形随 `size` 等比
/// 缩放，单独指定勾选大小已无意义），调用点改为只传 `size`�?
class CircleCheckbox extends StatelessWidget {
  const CircleCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    this.size = AppDimens.taskCheckboxSize,
    this.borderColor,
  });

  final bool checked;
  final VoidCallback onToggle;

  /// 未勾选态描边色；null = 组件默认中性灰。
  ///
  /// 任务列表用它承载优先级语义（高/紧急/立即以橙红圆环表达，P0「无」
  /// 回落默认灰）——同一信息不再于副标题重复一枚色点（docs/05 §4.5）。
  final Color? borderColor;

  /// 热区外扩下限：勾选是高频精确点击，22–28px 图形热区在密集列表里
  /// 误触率高——布局盒取 `max(size, 44)`、图形居中，可点面积扩到触控
  /// 标准档而视觉直径不变
  static const double minHitExtent = 44;

  /// 外圆直径（列表行 24 / 详情标题 28 / 子任务 22；可点热区不小于 44）
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
            borderRadius: BorderRadius.circular(size / 2),
            activeColor: OrbitAccents.todoAccent,
            borderColor:
                borderColor ?? colors.secondaryText.withValues(alpha: 0.4),
            onChanged: (_) => _handleChanged(),
          ),
        ),
      ),
    );
  }
}
