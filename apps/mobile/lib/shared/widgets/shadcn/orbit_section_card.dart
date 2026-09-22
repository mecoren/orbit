import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/orbit_accents.dart';
import 'orbit_card.dart';

/// 详情/设置区块容器（[OrbitCard] 的带头变体）
///
/// **公共 API 与旧 `SectionCard` 逐字一致**（调用方零改动）：
/// 仅内部实现从直铺 shadcn `Card` 改为复用 [OrbitCard]——描边/圆角/
/// 填充色仍由 shadcn 主题派生（`border = AppColors.outline` /
/// `radiusMd = AppShapes.radiusMedium`），视觉与其他 shadcn 卡片自动同构。
///
/// 与 v2 的差异（有意）：**不再投阴影**。shadcn 语言用 1px 描边 + 表面分层
/// 表达深度，阴影只留给浮层（抽屉/对话/菜单），与「对比靠描边与层级」的
/// 设计原则一致。
///
/// 头部 = 标题（labelMedium/w600，[OrbitAccents.todoAccent]）+ 可选副标题
/// + Spacer + trailing。区块间距由父级承担，本组件不管。
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
    return OrbitCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Row(
              children: [
                Flexible(
                  child: Text(
                    title!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: OrbitAccents.todoAccent,
                    ),
                  ),
                ),
                if (subtitle != null) ...[
                  const SizedBox(width: AppDimens.space8),
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
            const SizedBox(height: AppDimens.space12),
          ],
          child,
        ],
      ),
    );
  }
}
