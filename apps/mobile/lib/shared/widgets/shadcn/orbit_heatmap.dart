import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/orbit_accents.dart';
import '../../../data/api/dto.dart';

/// 完成热力图（GitHub 贡献图风格：按年展示逐日完成密度）。
///
/// **为什么不用图表库**：`fl_chart` 只有折线/柱/饼/散点/雷达/K 线，**没有热力图**；
/// shadcn_flutter 的 `tracker` 是单行进度条带，承载不了「7 行 × 53 列」的年历网格。
/// 故按既定兜底策略：网格由 Row/Column 自组，但**色阶与交互全部来自设计 token**——
/// 4 档色阶 = [OrbitAccents.todoAccent] 的 22/45/68/90% 透明度，单元格为圆角方块；
/// 点选格子的信息走页内信息条，不手搓浮层。
///
/// 布局：顶部月份标签、左侧 周一/周三/周五、右侧竖排年份按钮、底部 少/多 图例；
/// 12dp 格横滚（与 wait-home 移动端同款密度）；点按格子显示「日期: N 个完成」。
class OrbitHeatmap extends StatefulWidget {
  const OrbitHeatmap({
    super.key,
    required this.heatmap,
    required this.availableYears,
    required this.year,
    required this.onYearChange,
  });

  final StatsHeatmap heatmap;

  /// 可选年份列表（升序；有完成记录的年份）
  final List<int> availableYears;

  /// 当前选中年份
  final int year;
  final ValueChanged<int> onYearChange;

  @override
  State<OrbitHeatmap> createState() => _OrbitHeatmapState();
}

class _OrbitHeatmapState extends State<OrbitHeatmap> {
  static const double _cell = 12;
  static const double _gap = 2;

  String? _pickedDate;

  DateTime _parse(String ymd) {
    final parts = ymd.split('-');
    return DateTime(
      int.parse(parts[0]),
      int.parse(parts[1]),
      int.parse(parts[2]),
    );
  }

  /// 4 档色阶（0 为空格底）：透明度锚定，与桌面端热力图口径一致
  Color _cellColor(int count, Color accent, AppColorSet colors) {
    if (count <= 0) return colors.surfaceSecondary;
    final alpha = count >= 4
        ? 0.90
        : count == 3
            ? 0.68
            : count == 2
                ? 0.45
                : 0.22;
    return accent.withValues(alpha: alpha);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accent = OrbitAccents.todoAccent;

    // 逐日计数表
    final counts = <String, int>{
      for (final cell in widget.heatmap.cells) cell.date: cell.count,
    };

    final start = widget.heatmap.cells.isEmpty
        ? DateTime(widget.year, 1, 1)
        : _parse(widget.heatmap.cells.first.date);
    final end = widget.heatmap.cells.isEmpty
        ? DateTime(widget.year, 12, 31)
        : _parse(widget.heatmap.cells.last.date);

    // 周一起始的网格起点（向前补位到周一）
    final gridStart = start.subtract(Duration(days: (start.weekday + 6) % 7));
    final totalDays = end.difference(gridStart).inDays + 1;
    final weeks = (totalDays / 7).ceil();

    final picked = _pickedDate == null ? null : counts[_pickedDate] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildMonthLabels(gridStart, weeks, colors),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildWeekdayLabels(colors),
                        const SizedBox(width: AppDimens.space6),
                        for (var week = 0; week < weeks; week++)
                          Padding(
                            padding: const EdgeInsets.only(right: _gap),
                            child: Column(
                              children: [
                                for (var row = 0; row < 7; row++)
                                  _buildCell(
                                    gridStart,
                                    week,
                                    row,
                                    counts,
                                    accent,
                                    colors,
                                    end,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppDimens.space8),
            _buildYearColumn(colors, accent),
          ],
        ),
        const SizedBox(height: AppDimens.space8),
        Row(
          children: [
            Text(
              '少',
              style: TextStyle(fontSize: 11, color: colors.secondaryText),
            ),
            const SizedBox(width: AppDimens.space4),
            for (final count in [0, 1, 2, 3, 4])
              Padding(
                padding: const EdgeInsets.only(right: _gap),
                child: Container(
                  width: _cell,
                  height: _cell,
                  decoration: BoxDecoration(
                    color: _cellColor(count, accent, colors),
                    borderRadius: BorderRadius.circular(3),
                  ),
                ),
              ),
            const SizedBox(width: AppDimens.space4),
            Text(
              '多',
              style: TextStyle(fontSize: 11, color: colors.secondaryText),
            ),
            const Spacer(),
            if (_pickedDate != null)
              Flexible(
                child: Text(
                  '$_pickedDate: $picked 个完成',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: colors.titleText),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildCell(
    DateTime gridStart,
    int week,
    int row,
    Map<String, int> counts,
    Color accent,
    AppColorSet colors,
    DateTime end,
  ) {
    final date = gridStart.add(Duration(days: week * 7 + row));
    if (date.isAfter(end)) {
      return const SizedBox(width: _cell, height: _cell + _gap);
    }
    final ymd = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
    final count = counts[ymd] ?? 0;
    final picked = _pickedDate == ymd;
    return Padding(
      padding: const EdgeInsets.only(bottom: _gap),
      child: GestureDetector(
        onTap: () => setState(() => _pickedDate = picked ? null : ymd),
        child: Container(
          width: _cell,
          height: _cell,
          decoration: BoxDecoration(
            color: _cellColor(count, accent, colors),
            borderRadius: BorderRadius.circular(3),
            border:
                picked ? Border.all(color: colors.titleText, width: 1) : null,
          ),
        ),
      ),
    );
  }

  Widget _buildMonthLabels(DateTime gridStart, int weeks, AppColorSet colors) {
    const labelWidth = _cell + _gap;
    return Row(
      children: [
        // 让位给左侧周几标签列
        const SizedBox(width: 28 + AppDimens.space6),
        for (var week = 0; week < weeks; week++)
          SizedBox(
            width: labelWidth,
            child: _monthLabelAt(gridStart, week, colors),
          ),
      ],
    );
  }

  Widget _monthLabelAt(DateTime gridStart, int week, AppColorSet colors) {
    final date = gridStart.add(Duration(days: week * 7));
    final prev =
        week == 0 ? null : gridStart.add(Duration(days: (week - 1) * 7));
    // 只在月份首次出现时打标，避免标签重叠
    if (prev != null && prev.month == date.month) {
      return const SizedBox.shrink();
    }
    return Text(
      '${date.month}月',
      style: TextStyle(fontSize: 10, color: colors.secondaryText),
      maxLines: 1,
      overflow: TextOverflow.clip,
    );
  }

  Widget _buildWeekdayLabels(AppColorSet colors) {
    // 周一/周三/周五 三档（与 wait-home 同款稀疏标注）
    final labels = <int, String>{0: '一', 2: '三', 4: '五'};
    return Column(
      children: [
        for (var row = 0; row < 7; row++)
          SizedBox(
            height: _cell + _gap,
            width: 28,
            child: labels[row] == null
                ? null
                : Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      labels[row]!,
                      style: TextStyle(
                        fontSize: 10,
                        color: colors.secondaryText,
                      ),
                    ),
                  ),
          ),
      ],
    );
  }

  Widget _buildYearColumn(AppColorSet colors, Color accent) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final y in widget.availableYears)
          Padding(
            padding: const EdgeInsets.only(bottom: AppDimens.space4),
            child: InkWell(
              borderRadius: AppShapes.small,
              onTap: () => widget.onYearChange(y),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.space8,
                  vertical: AppDimens.space4,
                ),
                decoration: BoxDecoration(
                  borderRadius: AppShapes.small,
                  color:
                      y == widget.year ? accent.withValues(alpha: 0.12) : null,
                ),
                child: Text(
                  '$y',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        y == widget.year ? FontWeight.w600 : FontWeight.w400,
                    color: y == widget.year ? accent : colors.secondaryText,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
