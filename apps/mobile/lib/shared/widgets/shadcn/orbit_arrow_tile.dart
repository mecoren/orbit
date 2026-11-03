import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';

/// 箭头跳转行（原语层：flutter_miuix `MiuixArrowPreference` 承载）
///
/// **2026-11-02 新增**：此前设置页各跳转入口都是手搓
/// `InkWell + Row + chevron`（行高/字号/箭头色各处不一致），本原语把它们
/// 统一换成 [MiuixArrowPreference]——HyperOS 语言的标准跳转行：左标题
/// （+ 可选摘要）→ 尾部可挂值文本 / 徽标 / 转环 → 固定 10×16 右箭头
/// （颜色取 Miuix `onSurfaceVariantActions`），整行按压带 Folme 语义，
/// minHeight 56 满足触控口径（对标 miuix demo「列表项 Item」的
/// 箭头跳转段）。
///
/// 语义约定：
/// - [onClick] 为 null 或 [enabled] = false 时整行禁用（标题/箭头转禁用色）；
/// - [value] 尾随值文本（如「30 天」「08:00」，默认次要色，可经
///   [valueColor] 强调）；[trailing] 任意尾随 widget（角标/图标/转环），
///   两者都排在箭头之前；
/// - [titleColor] 覆写标题色（强调色入口/破坏性操作行用）。
class OrbitArrowTile extends StatelessWidget {
  const OrbitArrowTile({
    super.key,
    required this.title,
    this.summary,
    this.value,
    this.trailing,
    this.startAction,
    this.titleColor,
    this.valueColor,
    this.onClick,
    this.enabled = true,
  });

  /// 行标题
  final String title;

  /// 可选摘要（标题下方次要文字）
  final String? summary;

  /// 尾随值文本（排在箭头之前；如保留时间档位、当前版本号）
  final String? value;

  /// 尾随自定义 widget（角标 / 图标 / 转环；排在 [value] 之后、箭头之前）
  final Widget? trailing;

  /// 起始侧图标（可选）
  final Widget? startAction;

  /// 标题色覆写；缺省正文色，禁用时自动转禁用色
  final Color? titleColor;

  /// [value] 文本色；缺省次要文字色
  final Color? valueColor;

  /// 整行点击；null = 禁用
  final VoidCallback? onClick;

  /// 是否启用（false 时整行转禁用色、不可点）
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final effectiveEnabled = enabled && onClick != null;
    final valueText = value;
    final trailingWidget = trailing;
    return MiuixArrowPreference(
      title: title,
      summary: summary,
      startAction: startAction,
      titleColor: MiuixBasicComponentColors(
        color: titleColor ?? colors.bodyText,
        disabledColor: colors.deactivatedText,
      ),
      summaryColor: MiuixBasicComponentColors(
        color: colors.secondaryText,
        disabledColor: colors.deactivatedText,
      ),
      endActions: [
        if (valueText != null)
          Text(
            valueText,
            style: TextStyle(
              fontSize: 14,
              color: effectiveEnabled
                  ? (valueColor ?? colors.secondaryText)
                  : colors.deactivatedText,
            ),
          ),
        ?trailingWidget,
      ],
      onClick: effectiveEnabled ? onClick : null,
      enabled: effectiveEnabled,
    );
  }
}
