import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';

/// 列表/页面空态（大图标 + 文案居中，可选主行动按钮）
///
/// **公共 API 与旧 `EmptyState` 逐字一致**（6 处调用，6 个文件）：
/// 新增的 [actionLabel] / [onAction] 全部可选，不传则保持原样——
/// 空态给一个出口能显著降低「不知道下一步做什么」的死路感。
/// 用 [OutlinedButton] 而非实心钮：空态里已经有一个显眼的图标，
/// 再压一个主色实心块会盖过页面本身；且不少空态旁已有 FAB 同款入口。
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = OrbitIcons.listChecks,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final IconData icon;

  /// 空态下的主行动按钮文案（null = 不渲染按钮）
  final String? actionLabel;

  /// 主行动回调；[actionLabel] 非空时必填
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          icon,
          size: 56,
          color: colors.iconText.withValues(alpha: 0.5),
        ),
        const SizedBox(height: AppDimens.space12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 14, color: colors.secondaryText),
        ),
        if (actionLabel != null) ...[
          const SizedBox(height: AppDimens.space16),
          OutlinedButton(
            onPressed: onAction,
            child: Text(actionLabel!),
          ),
        ],
      ],
    );
  }
}
