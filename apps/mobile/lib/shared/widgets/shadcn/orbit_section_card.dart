import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/orbit_accents.dart';

/// 详情/设置区块容器（设计系�?v3：shadcn `Card` 承载�?
///
/// **公共 API 与旧 `SectionCard` 逐字一�?*�?0 处调用，9 个文件）�?
/// 仅内部实现从「自�?Container + 阴影」换�?shadcn `Card`—�?
/// 描边/圆角/填充色全部由 shadcn 主题派生（`border = AppColors.outline`�?
/// `radiusMd = AppShapes.radiusMedium`），因此视觉与其�?shadcn 卡片自动同构�?
///
/// �?v2 的差异（有意）：**不再投阴�?*。shadcn 语言用�?px 描边 + 表面分层�?
/// 表达深度，阴影只留给浮层（抽�?对话�?菜单），与「对比靠描边与层级」的
/// 设计原则一致�?
///
/// 头部�?= 标题（labelMedium/w600，[OrbitAccents.todoAccent]�? 可选副标题
/// + Spacer + trailing。区块间距由父级承担，本组件不管�?
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

  /// 副标题（如子任务区的 doneCount/total�?
  final String? subtitle;

  /// 头部尾随控件
  final Widget? trailing;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return sh.Card(
      padding: const EdgeInsets.all(AppDimens.cardPadding),
      filled: true,
      fillColor: colors.surface,
      borderColor: colors.outline,
      borderWidth: 1,
      borderRadius: AppShapes.medium,
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
