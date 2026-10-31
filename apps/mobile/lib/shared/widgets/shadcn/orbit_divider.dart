import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';

/// 分隔线（原语层：flutter_miuix `MiuixHorizontalDivider` 承载）
///
/// **2026-10-31 新增**：此前 6 处直接用 Material `Divider`（设置页区块分隔、
/// 同步结果列表行分隔、矩阵列分隔、下拉面板条目分隔、抽屉尾栏分隔）。
/// Miuix 的分隔线默认厚度 0.75（HyperOS 规范），比 Material 的 1px 更细、
/// 且颜色取 `dividerLine` 语义角色（本仓由 `AppColorSet.divider` 派生）。
///
/// [height] 沿用 Material `Divider.height` 语义（**整条占位高度**，含上下留白）：
/// 传 `AppDimens.space24` 表示"分隔 + 24 高留白"，Miuix 版本用 `SizedBox`
/// 包一层再画线（线本身贴垂直居中）。
class OrbitDivider extends StatelessWidget {
  const OrbitDivider({
    super.key,
    this.height,
    this.thickness,
    this.color,
    this.indent = 0,
    this.endIndent = 0,
  });

  /// 整条占位高度（null = 只占线本身厚度）
  final double? height;

  /// 线厚（null = Miuix 默认 0.75；要 1px 实线时显式传 1）
  final double? thickness;

  /// 线色（null = `divider` token）
  final Color? color;

  /// 左缩进
  final double indent;

  /// 右缩进
  final double endIndent;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final line = Padding(
      padding: EdgeInsets.only(left: indent, right: endIndent),
      child: MiuixHorizontalDivider(
        thickness: thickness ?? 1,
        color: color ?? colors.divider,
      ),
    );
    final h = height;
    if (h == null) return line;
    return SizedBox(height: h, child: Center(child: line));
  }
}

/// 垂直分隔线（原语层：flutter_miuix `MiuixVerticalDivider` 承载）
///
/// Material `VerticalDivider` 的等价物：`width` 是整条占位宽度（含左右留白），
/// 线贴水平居中。
class OrbitVerticalDivider extends StatelessWidget {
  const OrbitVerticalDivider({
    super.key,
    this.width,
    this.thickness,
    this.color,
  });

  final double? width;
  final double? thickness;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final line = MiuixVerticalDivider(
      thickness: thickness ?? 1,
      color: color ?? colors.divider,
    );
    final w = width;
    if (w == null) return line;
    return SizedBox(width: w, child: Center(child: line));
  }
}

