import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_motion.dart';
import '../../core/theme/orbit_accents.dart';

/// 圆形勾选框（自绘 Container + Icon，docs/05 §七）
///
/// 未完成：2px 边框（sub 色 @40%）+ 透明底；完成：todoAccent 实底 + 白色 check。
/// 直径与 check 尺寸按场景传入（列表行 24/16、详情标题 28/18、子任务 22/14）。
///
/// 动效（对齐微软 To-Do 点按手感）：勾选时底色与描边渐入、对号缩放淡入，
/// 取消勾选反向播放；点按附一次轻触感反馈。全部用隐式动画表达，
/// 无 AnimationController、无 State（本组件保持 StatelessWidget，调用点零改动）。
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

  void _handleTap() {
    HapticFeedback.selectionClick();
    onToggle();
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final borderColor = checked
        ? OrbitAccents.todoAccent
        : colors.secondaryText.withValues(alpha: 0.4);

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _handleTap,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: checked ? OrbitAccents.todoAccent : Colors.transparent,
          border: Border.all(width: 2, color: borderColor),
        ),
        // 对号进出场：缩放 + 淡入（easeOutBack 轻微过冲，收尾弹一下）
        child: AnimatedSwitcher(
          duration: AppMotion.fast,
          switchInCurve: AppMotion.bounce,
          switchOutCurve: AppMotion.standard,
          transitionBuilder: (child, animation) => ScaleTransition(
            scale: animation,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: checked
              ? Icon(
                  Icons.check_rounded,
                  key: const ValueKey('checked'),
                  size: checkSize,
                  color: Colors.white,
                )
              : const SizedBox.shrink(key: ValueKey('unchecked')),
        ),
      ),
    );
  }
}
