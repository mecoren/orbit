/// 档位选择网格（原语层：等分列宽 + 实心选中档，2026-11-05）
///
/// 与裸 [OrbitFilterChip] + `Wrap` 的分工：
/// - **本组件 = 设置项/表单里的档位单选**（生成规模 3 档、导入预设 4 档）：
///   列宽等分撑满整卡、末行不足补空列，选中档走 `solid`（实心强调色底 +
///   反白字），热区随整行拉开——档位本身就是主操作，选中态要一眼可见；
/// - **列表筛选行**（任务状态/优先级、冲突解决状态）仍用裸
///   [OrbitFilterChip] + `Wrap` + 默认 16% 底：筛选是辅助动作，多组并排时
///   实心会抢走列表注意力。
///
/// 等分而不换行溢出：`perRow` 固定列数，过长的档位文案由 chip 自身
/// ellipsis 收尾；4 档以上按行折成网格（2×2 / 3×2），不会挤成一条。
library;

import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import 'orbit_filter_chip.dart';
import 'orbit_select_popup.dart';

export 'orbit_select_popup.dart' show SelectItem;

/// 档位选择网格（见文件头）
class OrbitChoiceGrid<T> extends StatelessWidget {
  const OrbitChoiceGrid({
    super.key,
    required this.items,
    required this.current,
    required this.onSelect,
    this.perRow = 3,
    this.enabled = true,
    this.rowGap = AppDimens.space8,
    this.columnGap = AppDimens.space8,
  });

  /// 档位（[SelectItem.value] 是选中判据，[SelectItem.label] 是 chip 文案）
  final List<SelectItem<T>> items;

  /// 当前档（必须能在 [items] 里找到，否则无选中项）
  final T? current;

  /// 选中回调
  final ValueChanged<T> onSelect;

  /// 每行列数（一般 2 或 3）
  final int perRow;

  /// 是否可点（false 时所有 chip 禁用降透明度）
  final bool enabled;

  /// 行距 / 列距
  final double rowGap;
  final double columnGap;

  @override
  Widget build(BuildContext context) {
    final rows = <List<SelectItem<T>>>[];
    for (var i = 0; i < items.length; i += perRow) {
      final end = i + perRow > items.length ? items.length : i + perRow;
      rows.add(items.sublist(i, end));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) SizedBox(height: rowGap),
          Row(
            children: [
              for (var c = 0; c < perRow; c++) ...[
                if (c > 0) SizedBox(width: columnGap),
                Expanded(
                  // 末行不足列数时补空位：保证每列等宽，最后一项不会被拉宽
                  child: c < rows[r].length
                      ? OrbitFilterChip(
                          label: rows[r][c].label,
                          selected: rows[r][c].value == current,
                          solid: true,
                          expand: true,
                          onTap: enabled
                              ? () => onSelect(rows[r][c].value)
                              : null,
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
