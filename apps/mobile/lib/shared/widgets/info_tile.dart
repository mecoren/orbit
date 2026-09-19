import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../utils/hex_color.dart';

/// 信息行（详情页信息区与新建/编辑表单字段行共用，docs/05 §4.3 _InfoTile）
///
/// 结构：label 固定列宽 80（12px secondary）→ 可选 10×10 色点 + 值（15px）
/// → 可选清除叉 → 可选尾箭头。传 [onClick] 时整行可点——两侧调用方均以
/// 「点行唤起底部选择抽屉」为交互口径（字段值不在行内直改）。
class InfoTile extends StatelessWidget {
  const InfoTile({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.dotColorHex,
    this.onClick,
    this.onClear,
  });

  /// 行标签（优先级/状态/项目/重复/截止日期…）
  final String label;

  /// 值文案
  final String value;

  /// 值文字直接着色（#36 项目名按项目色；null 用默认 bodyText）
  final Color? valueColor;

  /// 值前 10×10 色点 hex（null/空串不渲染）
  final String? dotColorHex;

  final VoidCallback? onClick;

  /// 可清除值（如截止日期）的清除钮回调；null 不渲染
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final row = Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(fontSize: 12, color: colors.secondaryText),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              if (dotColorHex != null && dotColorHex!.isNotEmpty) ...[
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: hexToColor(dotColorHex!),
                  ),
                ),
                const SizedBox(width: AppDimens.space8),
              ],
              Flexible(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: valueColor ?? colors.bodyText,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (onClear != null) ...[
          GestureDetector(
            onTap: onClear,
            child: Icon(
              Icons.close_rounded,
              size: AppDimens.iconSizeSm,
              color: colors.secondaryText,
            ),
          ),
          const SizedBox(width: AppDimens.space4),
        ],
        if (onClick != null)
          Icon(
            Icons.keyboard_arrow_right_rounded,
            size: AppDimens.iconSizeSm + 2,
            color: colors.secondaryText,
          ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.space8),
      child: onClick == null
          ? row
          : InkWell(borderRadius: AppShapes.small, onTap: onClick, child: row),
    );
  }
}
