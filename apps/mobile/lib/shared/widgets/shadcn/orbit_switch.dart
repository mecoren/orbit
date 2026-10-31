import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/miuix_theme.dart';
import '../../../core/theme/orbit_accents.dart';

/// 设置行开关（原语层：flutter_miuix `MiuixSwitch` 承载，HyperOS 胶囊开关）
///
/// **2026-10-31 新增**：此前各设置页直接用 Material `Switch`（8 处），
/// 尺寸/轨道色/thumb 动效散在 `app_theme.dart` 的 `switchTheme` 里，与 HyperOS
/// 语言不符。本原语把它们统一换成 [MiuixSwitch]——49×28 胶囊轨道 + 20dp 圆点
/// thumb，按下/悬停/拖拽时 thumb 放大到 1.127 倍（Folme 弹簧），开关状态切换
/// 走同一条弹簧曲线（源端 Compose `Switch` 同款手感）。
///
/// **语义保留**：`onChanged: null` 仍表示禁用（MiuixSwitch 的 `enabled`
/// 由「回调非空」推导，这里显式转成 `enabled` 参数，调用点写法零变化）。
/// 触控热区：Miuix 轨道本身就是 49×28 的可点区域，行内布局由调用方的
/// `Row` 决定，本组件不再额外撑高（与 Material `Switch` 的
/// `materialTapTargetSize: padded` 不同——设置行整行通常已由
/// `InkWell` / `minHeight: touchTarget` 保证热区）。
class OrbitSwitch extends StatelessWidget {
  const OrbitSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.semanticLabel,
  });

  final bool value;

  /// null = 禁用（与 Material `Switch.onChanged` 语义一致）
  final ValueChanged<bool>? onChanged;

  /// 读屏标签（行内已有文字说明时可省）
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final mColors = buildMiuixColors(Theme.of(context).brightness);
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: MiuixSwitch(
        value: value,
        enabled: enabled,
        onChanged: onChanged,
        colors: MiuixSwitchColors(
          // 开：主题强调色轨道 + 白 thumb（与 OrbitFab / 选中态同源）
          checkedTrackColor: OrbitAccents.themeAccent,
          checkedThumbColor: mColors.onPrimary,
          // 关：中性表面轨道 + 次要文字色 thumb
          uncheckedTrackColor: colors.surfaceSecondary,
          uncheckedThumbColor: colors.secondaryText,
          disabledCheckedTrackColor: colors.divider,
          disabledCheckedThumbColor: colors.deactivatedText,
          disabledUncheckedTrackColor: colors.surfaceSecondary,
          disabledUncheckedThumbColor: colors.deactivatedText,
        ),
      ),
    );
  }
}

/// 兼容常量：旧 Material `Switch` 的视觉宽度（供既有布局/测试引用）
const double kOrbitSwitchWidth = MiuixSwitchDefaults.trackWidth;

/// 兼容常量：旧 Material `Switch` 的视觉高度
const double kOrbitSwitchHeight = MiuixSwitchDefaults.trackHeight;

/// 行内开关（左标签 + 右开关）——设置页最常用的形态
///
/// 直接替代各页手写的 `Row(children: [Expanded(Text), Switch(...)])`：
/// 标签走正文色 14px，开关右对齐，整行高度不低于 [AppDimens.touchTarget]，
/// 点击整行也能切换（命中面积从 49×28 扩到整行，符合触控口径）。
class OrbitSwitchRow extends StatelessWidget {
  const OrbitSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.description,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// 可选说明文案（12px 次要文字，渲染在标签下方）
  final String? description;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final enabled = onChanged != null;
    final descriptionText = description;
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(8)),
      onTap: enabled ? () => onChanged!(!value) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppDimens.touchTarget),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      color: enabled ? colors.bodyText : colors.deactivatedText,
                    ),
                  ),
                  if (descriptionText != null) ...[
                    const SizedBox(height: AppDimens.space2),
                    Text(
                      descriptionText,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.secondaryText,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: AppDimens.space12),
            OrbitSwitch(
              value: value,
              onChanged: onChanged,
              semanticLabel: label,
            ),
          ],
        ),
      ),
    );
  }
}
