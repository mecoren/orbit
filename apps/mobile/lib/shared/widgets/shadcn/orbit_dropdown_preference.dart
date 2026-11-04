/// 下拉偏好行（原语层：flutter_miuix 窗口级下拉偏好，2026-11-04）
///
/// 与「外观」页的主题/字号/字重/强调色四行同一组件口径：标题（+可选摘要）
/// 在左，尾随当前值 + 上下双箭头，点行就地展开库内下拉弹层，当前档转主题色
/// 并打勾；弹层挂根 Overlay，不依赖玻璃采样器，push 出来的设置子页可直接用。
///
/// 与 [showOrbitSelectPopup]（锚定单选浮层）的分工：后者是「任意触发控件 +
/// 浮层」的通用选择器，本行是设置项里的下拉偏好，当前值必须在行内常驻可见。
/// 选中判据取 [SelectItem.value] 原始值而非文案；当前值不在 [items] 里时由
/// 调用方补一项（外观页强调色的「当前色」同款），否则库内无选中项 → 尾随值
/// 与弹层对勾双双落空。
library;

import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

import 'orbit_select_popup.dart';

export 'orbit_select_popup.dart' show SelectItem;

/// 下拉偏好行（见文件头）
class OrbitDropdownPreference<T> extends StatelessWidget {
  const OrbitDropdownPreference({
    super.key,
    required this.title,
    required this.items,
    required this.current,
    required this.onSelect,
    this.summary,
    this.startAction,
    this.insideMargin = const EdgeInsets.symmetric(
      horizontal: 16,
      vertical: 14,
    ),
    this.enabled = true,
  });

  /// 行标题
  final String title;

  /// 可选摘要（标题下方次要文字）
  final String? summary;

  /// 下拉选项（[SelectItem.value] 是选中判据，[SelectItem.label] 是尾随值文案）
  final List<SelectItem<T>> items;

  /// 当前值（必须能在 [items] 里找到，否则不显示尾随值）
  final T? current;

  /// 选中回调（弹层点选后触发）
  final ValueChanged<T> onSelect;

  /// 行首动作（如总开关）：并入同一个 `MiuixBasicComponent`，展开时按压灰底
  /// 才会覆盖整行；放在行外另起 `Row` 时灰底只会盖住下拉行那一段。
  /// 行禁用时本控件仍可点（库内禁用只置空行自身的回调），总开关可回开。
  final Widget? startAction;

  /// 行内边距（外观页口径 16×14；行自带水平内边距，外层卡片归零水平内边距，
  /// 按压灰底才能横贯整卡）
  final EdgeInsetsGeometry insideMargin;

  /// 是否启用（false 时整行转禁用色、不可展开）
  final bool enabled;

  @override
  Widget build(BuildContext context) => MiuixWindowDropdownPreference.entry(
    title: title,
    summary: summary,
    startAction: startAction,
    entry: MiuixDropdownEntry(
      items: [
        for (final item in items)
          MiuixDropdownItem(
            text: item.label,
            selected: item.value == current,
            onClick: () => onSelect(item.value),
          ),
      ],
    ),
    insideMargin: insideMargin,
    enabled: enabled,
  );
}
