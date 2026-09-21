import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';

/// 列表/页面空态（大图�?+ 文案居中�?
///
/// **公共 API 与旧 `EmptyState` 逐字一�?*�? 处调用，6 个文件）�?
/// 唯一变化是默认图标从 Material �?`Icons.checklist_rounded` 换成线性图标集
/// �?[OrbitIcons.listChecks]（设计系�?v3 全站图标线性化）�?
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.message,
    this.icon = OrbitIcons.listChecks,
  });

  final String message;
  final IconData icon;

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
      ],
    );
  }
}
