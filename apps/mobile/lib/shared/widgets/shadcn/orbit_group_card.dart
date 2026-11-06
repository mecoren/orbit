import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_dimens.dart';

/// 详情/日志类分组卡（设计系统 v3 原语层）
///
/// 版式与任务详情页 `_groupCard` 同一口径：**卡片左右外距 12 + 零内边距
/// [MiuixCard]**。行自带 16 水平内边距时，按压灰底可横贯整卡、由卡片圆角
/// 裁切（外层再包 `Padding` 会把灰底缩成一小块）。
///
/// **与设置页分组卡的分工**：设置页行首有 24 图标槽，分隔线缩进 56 才能
/// 对齐标题；本组件面向详情/日志这类无图标槽的行（缩进 16，见
/// [OrbitGroupDivider]）。两者卡体/padding 相同，只有分隔线缩进不同。
///
/// 卡外小标题直接用库内 `MiuixSmallTitle`（28×8 内边距，与卡内标题同线）。
class OrbitGroupCard extends StatelessWidget {
  const OrbitGroupCard({super.key, required this.children});

  /// 卡内行（通常为 `Miuix*` 行原语 / 自绘只读行；行间自行插入
  /// [OrbitGroupDivider]）
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: AppDimens.space12),
    child: MiuixCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ),
  );
}

/// 分组卡行间分隔线
///
/// 缩进取行内边距本身（16）——行首没有 24 图标位时，只有这个值能让分隔线
/// 与行标题落在同一条竖线上（设置页用 56 是因为其行首有图标位）。
class OrbitGroupDivider extends StatelessWidget {
  const OrbitGroupDivider({super.key, this.indent = AppDimens.space16});

  final double indent;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: indent),
    child: const MiuixHorizontalDivider(),
  );
}
