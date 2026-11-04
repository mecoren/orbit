import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';

/// 设置行开关（原语层：Material `Switch` 承载，强调色蓝轨 + 白 thumb）
///
/// **2026-11-04 改版**：此前曾用 flutter_miuix `MiuixSwitch`（HyperOS 胶囊
/// 开关），按用户要求全项目开关统一对齐 Material 蓝色开关样式（同底部弹层
/// `SwitchListTile` 的口径）——视觉走 `app_theme.dart` 全局 `switchTheme`：
/// 选中态主题强调色轨道 + 白 thumb，非选中中性灰轨道，无描边。
///
/// **语义保留**：`onChanged: null` 仍表示禁用（Material `Switch` 原生语义，
/// 调用点写法零变化）。
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
    final enabled = onChanged != null;
    return Semantics(
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      child: Switch(value: value, onChanged: onChanged),
    );
  }
}

/// 行内开关（左标签 + 右开关）——设置页最常用的形态
///
/// 直接替代各页手写的 `Row(children: [Expanded(Text), Switch(...)])`：
/// 标签走正文色 14px，开关右对齐，整行高度不低于触控标准，
/// 点击整行也能切换（命中面积从开关本体扩到整行，符合触控口径）。
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
