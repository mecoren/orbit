import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';

/// 详情屏区块容器（docs/05 §4.3 _SectionCard）
///
/// radius 12、边框 divider@30%、内边距 16、无阴影；头部行 =
/// 标题 12/w600 accent（todoAccent）+ 可选副标题 bodySmall/sub + Spacer + trailing。
/// 区块间距 12 由父级承担，本组件不管。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    this.title,
    this.subtitle,
    this.trailing,
    required this.child,
  });

  /// 头部标题；缺省不渲染头行（详情标题区为无头卡片）
  final String? title;

  /// 副标题（如子任务区的 doneCount/total）
  final String? subtitle;

  /// 头部尾随控件
  final Widget? trailing;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppDimens.space16),
      decoration: BoxDecoration(
        color: colors.surface.withValues(alpha: 0.6),
        borderRadius: AppShapes.sectionCard,
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null || subtitle != null || trailing != null) ...[
            Row(
              children: [
                if (title != null)
                  Text(
                    title!,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: OrbitAccents.todoAccent,
                    ),
                  ),
                if (subtitle != null) ...[
                  SizedBox(width: title != null ? AppDimens.space8 : 0),
                  Text(
                    subtitle!,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.secondaryText,
                    ),
                  ),
                ],
                const Spacer(),
                ?trailing,
              ],
            ),
            const SizedBox(height: AppDimens.space8),
          ],
          child,
        ],
      ),
    );
  }
}
