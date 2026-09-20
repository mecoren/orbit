import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';

/// 列表空态（大图标 + 文案居中）
///
/// docs/05 §4.2：checklist 图标 56px @40% + bodySmall 副文案。
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.message, this.icon = Icons.checklist_rounded});

  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
          style: theme.textTheme.bodyMedium?.copyWith(
            color: colors.secondaryText,
          ),
        ),
      ],
    );
  }
}
