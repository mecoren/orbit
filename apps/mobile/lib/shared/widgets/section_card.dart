import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_elevation.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';

/// 详情屏区块容器（设计系统 v2：白卡 + 柔和阴影）
///
/// v2 变化：旧版 `surface@60%` + `divider@30%` 边框 + 无阴影，在灰底上几乎
/// 与背景同色；v2 改为**纯白卡面 + 极浅描边 + e1 柔和阴影**，区块从页面底
/// 明确"浮起"。圆角走 [AppShapes.sectionCard]，内边距走 [AppDimens.cardPadding]。
///
/// 头部行 = 标题（labelMedium/w600，todoAccent）+ 可选副标题 + Spacer + trailing。
/// 区块间距由父级承担，本组件不管。
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
    final theme = Theme.of(context);
    final colors = AppColors.ofContext(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppDimens.cardPadding),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppShapes.sectionCard,
        border: Border.all(color: colors.outline),
        boxShadow: AppElevation.e1(theme.brightness),
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
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: OrbitAccents.todoAccent,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (subtitle != null) ...[
                  SizedBox(width: title != null ? AppDimens.space8 : 0),
                  Text(
                    subtitle!,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: colors.secondaryText,
                      fontWeight: FontWeight.w400,
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
