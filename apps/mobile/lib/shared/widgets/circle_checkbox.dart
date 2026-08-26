import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';

/// 圆形勾选框（自绘 Container + Icon，docs/05 §七）
///
/// 未完成：2px 边框（sub 色 @40%）+ 透明底；完成：todoAccent 实底 + 白色 check。
/// 直径与 check 尺寸按场景传入（列表行 24/16、详情标题 28/18、子任务 22/14）。
class CircleCheckbox extends StatelessWidget {
  const CircleCheckbox({
    super.key,
    required this.checked,
    required this.onToggle,
    this.size = AppDimens.taskCheckboxSize,
    this.checkSize = AppDimens.taskCheckboxSize - AppDimens.space8,
  });

  final bool checked;
  final VoidCallback onToggle;

  /// 外圆直径
  final double size;

  /// 白色对勾图标边长
  final double checkSize;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onToggle,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? OrbitAccents.todoAccent : Colors.transparent,
          border: Border.all(
            width: 2,
            color: checked
                ? OrbitAccents.todoAccent
                : colors.secondaryText.withValues(alpha: 0.4),
          ),
        ),
        child: checked
            ? Icon(Icons.check_rounded, size: checkSize, color: Colors.white)
            : null,
      ),
    );
  }
}
