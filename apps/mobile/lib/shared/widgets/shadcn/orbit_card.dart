import 'package:flutter/material.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' as sh;

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';

/// 基础卡片（设计系统 v3 原语层：shadcn `Card` 承载）
///
/// v3 卡片口径：1px `outline` 描边 + `surface` 填充 + medium 圆角，
/// **不投阴影**——深度靠描边与表面分层表达，阴影只留给浮层
/// （抽屉/对话/菜单/Toast，见 AppElevation）。
/// 手搓 `Container + Border.all(outline)` 一律换这里；带标题的区块用
/// [SectionCard]（本原语的带头变体，见 orbit_section_card.dart）。
///
/// [fillColor] 缺省 `surface`；次级行（备份条目/标签行/冲突卡等）用
/// `surfaceSecondary`，内嵌对比盒用 `background`——填充分层保留，
/// 统一下沉的只是描边/圆角/阴影口径。
class OrbitCard extends StatelessWidget {
  const OrbitCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppDimens.cardPadding),
    this.borderRadius = AppShapes.medium,
    this.fillColor,
  });

  final Widget child;

  /// 内边距（默认卡片标准垫 `cardPadding`）
  final EdgeInsetsGeometry padding;

  /// 圆角（默认 medium；与 shadcn 主题 `radiusMd` 同值）
  final BorderRadiusGeometry borderRadius;

  /// 填充色（默认 `surface`）
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    return sh.Card(
      padding: padding,
      filled: true,
      fillColor: fillColor ?? colors.surface,
      borderColor: colors.outline,
      borderWidth: 1,
      borderRadius: borderRadius,
      child: child,
    );
  }
}
