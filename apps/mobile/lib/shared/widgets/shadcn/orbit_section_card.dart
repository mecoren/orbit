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
    this.padding = const EdgeInsets.all(AppDimens.cardPadding),
    this.edgeToEdgeContent = false,
  });

  /// 卡片内边距（默认全 16）。由本组件分派给头行与内容（[OrbitCard] 归零），
  /// 默认值下与旧「整卡 16」渲染逐像素一致；内容行自带水平内边距的
  /// 「贴边高亮」布局（miuix GroupCard 口径）传仅含 bottom 的内边距，
  /// 行按压灰底即可横贯整卡、由卡片圆角裁切。
  final EdgeInsetsGeometry padding;

  /// 内容行贴边（头行仍按 [padding] 左右留白）。
  ///
  /// 承载 `OrbitDropdownPreference` 这类自带 16 水平内边距的行时必须置 true：
  /// 否则卡片内边距会把行的按压灰底缩成一小块（设置/配置页档位行的统一口径）。
  /// 同一卡片内的其余字段需自行补回 16 水平内边距。
  final bool edgeToEdgeContent;

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
    final p =
        padding.resolve(Directionality.maybeOf(context) ?? TextDirection.ltr);
    return OrbitCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (title != null) ...[
            Padding(
              padding: EdgeInsets.only(
                left: p.left,
                right: p.right,
                top: p.top,
              ),
              child: Row(
                children: [
                  // 标题+副标题整体 Expanded、内部各自 Flexible：不能用
                  // 「Flexible(标题) + Spacer」并列——两个 flex 子项平分剩余
                  // 空间，标题用不完的份额按 mainAxisAlignment.start 堆到
                  // 行尾，trailing 会悬在中间不贴右（2026-11-04 同步配置页
                  // 两处「刷新」踩坑）。内层行剩余空间天然落在文案与
                  // trailing 之间，trailing 恒贴右。
                  Expanded(
                    child: Row(
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
                          Flexible(
                            child: Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.secondaryText,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (trailing != null) ...[
                    const SizedBox(width: AppDimens.space8),
                    trailing!,
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppDimens.space12),
          ],
          Padding(
            padding: EdgeInsets.only(
              left: edgeToEdgeContent ? 0 : p.left,
              right: edgeToEdgeContent ? 0 : p.right,
              // 无头卡（详情标题区）没有头行承载顶部留白，内容须自己补回
              // padding.top，否则贴顶、与底部 16 留白不对称
              top: title == null ? p.top : 0,
              bottom: p.bottom,
            ),
            child: child,
          ),
        ],
      ),
    );
  }
}
