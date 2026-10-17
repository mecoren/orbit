import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';

/// 行内状态开关（设计系统 v3 原语层）：星标 / 我的一天这类**行内高频切换**。
///
/// 对齐桌面 `task-list-view.tsx:945-979` / `task-table-view.tsx:481-519` /
/// `matrix-view.tsx:347-363` 的 hover 开关钮——桌面 hover 显现、点按切换；
/// 移动端无 hover，故**恒显**：未激活走 [inactiveColor]（弱化灰），
/// 激活走 [activeColor]（语义色），点按即回调。
///
/// 触控口径：视觉 [iconSize] 只是图形，热区外扩到 `AppDimens.touchTarget`
/// 的方形盒（与 `OrbitCheckbox.minHitExtent` 同源的 a11y 下限），
/// 行内挤时按 [hitExtent] 收小但不小于 32。
class OrbitRowToggle extends StatelessWidget {
  const OrbitRowToggle({
    super.key,
    required this.icon,
    required this.active,
    required this.activeColor,
    required this.inactiveColor,
    required this.tooltip,
    required this.onTap,
    this.iconSize = 14,
    this.hitExtent = 44,
  });

  final IconData icon;
  final bool active;
  final Color activeColor;
  final Color inactiveColor;

  /// 读屏标签（随态可点调用方传入，如「收藏 / 取消收藏」）
  final String tooltip;
  final VoidCallback onTap;

  /// 图形尺寸（列表行 12 / 表格 11 / 矩阵 14）
  final double iconSize;

  /// 热区方形边长（≤0 用 [AppDimens.touchTarget]）
  final double hitExtent;

  @override
  Widget build(BuildContext context) {
    final extent = hitExtent <= 0 ? AppDimens.touchTarget : hitExtent;
    return Semantics(
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: extent,
            height: extent,
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: active ? activeColor : inactiveColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
