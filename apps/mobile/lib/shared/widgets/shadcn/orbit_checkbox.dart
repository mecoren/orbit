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
  });

  final bool checked;
  final VoidCallback onToggle;

  /// 外圆直径（列表行 24 / 详情标题 28 / 子任�?22�?
  final double size;

  void _handleChanged() {
    HapticFeedback.selectionClick();
    onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return SizedBox.square(
      dimension: size,
      child: sh.Checkbox(
        state: checked ? sh.CheckboxState.checked : sh.CheckboxState.unchecked,
        size: size,
        borderRadius: BorderRadius.circular(size / 2),
        activeColor: OrbitAccents.todoAccent,
        borderColor: colors.secondaryText.withValues(alpha: 0.4),
        onChanged: (_) => _handleChanged(),
      ),
    );
  }
}
