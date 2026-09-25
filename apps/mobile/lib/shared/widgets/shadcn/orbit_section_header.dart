import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 列表分区段头（全屏列表页唯一口径，原侧栏 SectionHeader 上收共享）
///
/// 形态（docs/05 §4.1）：12px / w600 / 次要文字色，内边距 L16 / T12 / R8 / B4。
/// 抽屉与弹层内的字段组标题不属此类（层级更强、语境不同），不强行统一。
class OrbitSectionHeader extends StatelessWidget {
  const OrbitSectionHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppDimens.space16,
        AppDimens.space12,
        AppDimens.space8,
        AppDimens.space4,
      ),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: colors.secondaryText,
          ),
        ),
      ),
    );
  }
}
