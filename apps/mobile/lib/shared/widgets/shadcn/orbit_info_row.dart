import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/icon_map.dart';
import '../../utils/hex_color.dart';

/// 信息行（详情页信息区与新�?编辑表单字段行共用，docs/05 §4.3�?
///
/// **公共 API 与旧 `InfoTile` 逐字一�?*�?0 处调用，2 个文件）�?
///
/// 结构：label 固定列宽 80�?2px secondary）→ 可�?10×10 色点 + 值（15px�?
/// �?可选清除叉 �?可选尾箭头。传 [onClick] 时整行可点——两侧调用方均以
/// 「点行唤起底部选择抽屉」为交互口径（字段值不在行内直改）�?
///
/// 设计系统 v3 变化：色�?箭头/清除叉统一走线性图标集（[OrbitIcons]），
/// 不再混用 Material 的圆角实心图标�?
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

  final String label;
  final String value;
  final Color? valueColor;

  /// 可选色点（六位/八位 hex，见 [hexToColor]�?
  final String? dotColorHex;

  /// 整行点击（唤起选择抽屉�?
  final VoidCallback? onClick;

  /// 尾随清除�?
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final dot = dotColorHex == null ? null : hexToColor(dotColorHex!);

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.rowVertical),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.secondaryText),
            ),
          ),
          if (dot != null) ...[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppDimens.space8),
          ],
          Expanded(
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
          if (onClear != null)
            IconButton(
              tooltip: '清除',
              onPressed: onClear,
              icon: Icon(
                OrbitIcons.close,
                size: AppDimens.iconSizeSm,
                color: colors.iconText,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: AppDimens.touchTarget,
                minHeight: AppDimens.touchTarget,
              ),
            ),
          if (onClick != null)
            Icon(
              OrbitIcons.chevronRight,
              size: AppDimens.iconSizeSm,
              color: colors.iconText,
            ),
        ],
      ),
    );

    if (onClick == null) return row;
    return InkWell(
      onTap: onClick,
      borderRadius: BorderRadius.circular(AppDimens.space8),
      child: row,
    );
  }
}
