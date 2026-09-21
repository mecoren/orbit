import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_shapes.dart';
import '../../core/theme/orbit_accents.dart';
import '../../data/api/dto.dart';

/// 完成热力图（2026-09-10 对齐 wait-home activity_heatmap）
///
/// GitHub 贡献图风格：按年展示逐日完成密度。
/// - 当前年 = 滚动 365 天（跨年覆盖去年同日至今）；历史年 = 完整年；
/// - 4 档色阶走待办强调色 alpha 22/45/68/90%（锚定 max≥4 分档）；
/// - 布局：顶部月份标签、左侧 周一/周三/周五、右侧竖排年份按钮、底部 少/多 图例；
/// - 12dp 格横滚（wait-home 移动端同款）；长按/悬停格显示「日期: N 个完成」。
class OrbitHeatmap extends StatelessWidget {
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

  /// 单元格尺寸（dp）——14dp 与桌面 max-w-5xl 视觉口径一致（2026-09-10
  /// 用户反馈"框太小挤"后从 12dp 调大；完整一年仍可横向滚动）
  static const double _cellSize = 14;

  /// 单元格间距（dp）
  static const double _cellGap = 3;

  /// 星期标签宽度（dp）
  static const double _weekdayLabelWidth = 28;

  /// 月份标签高度（dp）
  static const double _monthLabelHeight = 20;

  /// 年份按钮宽/高/间距（dp）
  static const double _yearPillWidth = 52;
  static const double _yearPillHeight = 26;
  static const double _yearPillGap = 6;

  static const double _cellStep = _cellSize + _cellGap;

  /// 月份标签最小列间距，避免文字重叠
  static const int _minMonthLabelGapCols = 4;

  /// 4 档色阶 alpha（0 档 = 空格中性色；wait-home 22/45/68/90 同款）
  static const List<double> _alphas = [0.22, 0.45, 0.68, 0.90];

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);

    // 窗口范围（与 core stats_heatmap_impl 同口径）：
    // 当前年 = 滚动 365 天；历史年 = 完整年
    final now = DateTime.now();
    final today = year == now.year
        ? DateTime(now.year, now.month, now.day)
        : DateTime(year, 12, 31);
    final startDate = DateTime(year, 1, 1);
    // 当前年滚动窗口起点 = 今天往前 364 天（可能早于 1/1，以 heatmap.cells 为准兜底）
    final rollingStart = year == now.year
        ? DateTime(now.year, now.month, now.day).subtract(const Duration(days: 364))
        : startDate;
    final gridStart = year == now.year && rollingStart.isBefore(startDate)
        ? rollingStart
        : startDate;

    final cells = heatmap.cells;
    // 兜底：cells 为空（异常口径）直接画空窗
    if (cells.isEmpty) {
      return SizedBox(
        height: 7 * _cellStep - _cellGap + _monthLabelHeight,
        child: Center(
          child: Text(
            '$year 年暂无完成记录',
            style: TextStyle(fontSize: 13, color: colors.secondaryText),
          ),
        ),
      );
    }

    // 逐日值映射（以 core 返回 cells 为唯一事实来源；gridStart 起的日期
    // 若不在 cells（跨年滚动窗），按 0 处理）
    final valueMap = <String, int>{
      for (final c in cells) c.date: c.count,
    };
    final maxVal = cells.fold<int>(0, (prev, c) => c.count > prev ? c.count : prev);

    // 不做周一对齐：网格从窗口首日按其实际星期几开始铺（wait-home 同款）；
    // 首列前置空行数 = weekday - 1（周一为 0，周日为 6）
    final leadingEmptyRows = gridStart.weekday - 1;
    final daysInRange = today.difference(gridStart).inDays + 1;
    final totalColumns = ((daysInRange + leadingEmptyRows) / 7).ceil();

    // 月份标签：从 gridStart 逐日扫描，每月第一个日期所在列记录标签；
    // 列索引 = (leadingEmptyRows + 距 gridStart 天数) ~/ 7
    final rawMonthLabels = <_MonthLabel>[];
    var lastMonth = -1;
    var cursor = gridStart;
    while (!cursor.isAfter(today)) {
      if (cursor.month != lastMonth) {
        final col = (leadingEmptyRows + cursor.difference(gridStart).inDays) ~/ 7;
        rawMonthLabels.add(_MonthLabel(col: col, text: _monthAbbreviation(cursor.month)));
        lastMonth = cursor.month;
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    // 过滤重叠的月份标签（最小列间距）
    final monthLabels = <_MonthLabel>[];
    var lastKeptCol = -_minMonthLabelGapCols;
    for (final label in rawMonthLabels) {
      if (label.col - lastKeptCol >= _minMonthLabelGapCols) {
        monthLabels.add(label);
        lastKeptCol = label.col;
      }
    }

    final gridWidth = totalColumns * _cellStep - _cellGap;
    const gridHeight = 7 * _cellStep - _cellGap;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 左侧：月份标签 + 星期标签 + 网格
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 月份标签行
                  SizedBox(
                    height: _monthLabelHeight,
                    child: Row(
                      children: [
                        const SizedBox(width: _weekdayLabelWidth + _cellGap),
                        SizedBox(
                          width: gridWidth,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: monthLabels
                                .map((label) => Positioned(
                                      left: label.col * _cellStep,
                                      top: 0,
                                      child: Text(
                                        label.text,
                                        style: TextStyle(
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500,
                                          color: colors.secondaryText,
                                        ),
                                      ),
                                    ))
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: AppDimens.space4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildWeekdayLabels(colors),
                      const SizedBox(width: _cellGap),
                      _buildGrid(
                        gridStart: gridStart,
                        leadingEmptyRows: leadingEmptyRows,
                        today: today,
                        valueMap: valueMap,
                        maxVal: maxVal,
                        totalColumns: totalColumns,
                        gridWidth: gridWidth,
                        gridHeight: gridHeight,
                        colors: colors,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(width: AppDimens.space12),
              // 右侧：竖排年份按钮
              _buildYearPills(context, colors),
            ],
          ),
        ),
        const SizedBox(height: AppDimens.space12),
        _buildLegend(colors),
      ],
    );
  }

  /// 右侧竖排年份按钮（降序，最新年在顶部；选中态强调色实底白字）
  Widget _buildYearPills(BuildContext context, AppColorSet colors) {
    final sortedYears = [...availableYears, year]..sort((a, b) => b.compareTo(a));

    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxHeight: 7 * _cellStep - _cellGap + _monthLabelHeight + AppDimens.space4,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final y in sortedYears)
              Padding(
                padding: const EdgeInsets.only(bottom: _yearPillGap),
                child: GestureDetector(
                  onTap: y == year ? null : () => onYearChange(y),
                  child: Container(
                    width: _yearPillWidth,
                    height: _yearPillHeight,
                    decoration: BoxDecoration(
                      color: y == year
                          ? OrbitAccents.todoAccent
                          : colors.surfaceSecondary.withValues(alpha: 0.4),
                      borderRadius: AppShapes.of(20),
                      border: Border.all(
                        color: y == year
                            ? OrbitAccents.todoAccent
                            : colors.outline,
                      ),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      '$y',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: y == year ? FontWeight.w600 : FontWeight.w500,
                        color: y == year ? Colors.white : colors.secondaryText,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 星期标签列：与网格行同构的 7 槽（行 = 格 + 尾距），槽内垂直居中——
  /// 固定 spacer 结构会让标签逐级下沉（wait-home 原版缺陷），标签必须
  /// 与对应网格行的垂直中心严格对齐
  Widget _buildWeekdayLabels(AppColorSet colors) {
    Widget slot(String text) => SizedBox(
          width: _weekdayLabelWidth,
          height: _cellSize,
          child: Align(
            alignment: Alignment.centerRight,
            child: Text(
              text,
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: colors.secondaryText,
              ),
            ),
          ),
        );
    const empty = SizedBox(width: _weekdayLabelWidth, height: _cellSize);
    return Column(
      children: [
        for (var i = 0; i < 7; i++) ...[
          if (i > 0) const SizedBox(height: _cellGap),
          i == 0 ? slot('周一') : i == 2 ? slot('周三') : i == 4 ? slot('周五') : empty,
        ],
      ],
    );
  }

  /// 热力图网格：Row of Columns（每列一周，每列 7 格）
  Widget _buildGrid({
    required DateTime gridStart,
    required int leadingEmptyRows,
    required DateTime today,
    required Map<String, int> valueMap,
    required int maxVal,
    required int totalColumns,
    required double gridWidth,
    required double gridHeight,
    required AppColorSet colors,
  }) {
    return SizedBox(
      width: gridWidth,
      height: gridHeight,
      child: Row(
        children: [
          for (var col = 0; col < totalColumns; col++)
            Padding(
              padding: EdgeInsets.only(
                right: col < totalColumns - 1 ? _cellGap : 0,
              ),
              child: Column(
                children: [
                  for (var row = 0; row < 7; row++)
                    () {
                      // 首列前置空行 / 超出 today 的格渲染透明占位（保持网格对齐）
                      final dateOffset = col * 7 + row - leadingEmptyRows;
                      if (dateOffset < 0 ||
                          gridStart.add(Duration(days: dateOffset)).isAfter(today)) {
                        return _buildEmptyCell(row: row);
                      }
                      final cellDate = gridStart.add(Duration(days: dateOffset));

                      final key =
                          '${cellDate.year.toString().padLeft(4, '0')}-'
                          '${cellDate.month.toString().padLeft(2, '0')}-'
                          '${cellDate.day.toString().padLeft(2, '0')}';
                      final value = valueMap[key] ?? 0;
                      return Padding(
                        padding: EdgeInsets.only(bottom: row < 6 ? _cellGap : 0),
                        child: Tooltip(
                          message: '$key：完成 $value 个',
                          preferBelow: false,
                          child: Container(
                            width: _cellSize,
                            height: _cellSize,
                            decoration: BoxDecoration(
                              color: _resolveCellColor(value, maxVal, colors),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      );
                    }(),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// 透明占位单元格（保持网格对齐；末行不加尾距，列高与实际格严格一致）
  Widget _buildEmptyCell({required int row}) {
    return Padding(
      padding: EdgeInsets.only(bottom: row < 6 ? _cellGap : 0),
      child: const SizedBox(width: _cellSize, height: _cellSize),
    );
  }

  /// 值 → 色阶（锚定 max≥4 分档，wait-home 同款）
  Color _resolveCellColor(int value, int maxVal, AppColorSet colors) {
    if (value <= 0 || maxVal <= 0) {
      return colors.surfaceSecondary.withValues(alpha: 0.5);
    }
    final effectiveMax = maxVal < 4 ? 4 : maxVal;
    final ratio = value / effectiveMax;
    var level = 1;
    if (ratio <= 0.25) {
      level = 1;
    } else if (ratio <= 0.5) {
      level = 2;
    } else if (ratio <= 0.75) {
      level = 3;
    } else {
      level = 4;
    }
    return OrbitAccents.todoAccent.withValues(alpha: _alphas[level - 1]);
  }

  /// 图例：少 → 5 个色块（空 + 4 档）→ 多
  Widget _buildLegend(AppColorSet colors) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '少',
          style: TextStyle(fontSize: 10, color: colors.secondaryText),
        ),
        const SizedBox(width: AppDimens.space4),
        for (var i = 0; i <= 4; i++)
          Padding(
            padding: const EdgeInsets.only(right: _cellGap),
            child: Container(
              width: _cellSize,
              height: _cellSize,
              decoration: BoxDecoration(
                color: i == 0
                    ? colors.surfaceSecondary.withValues(alpha: 0.5)
                    : OrbitAccents.todoAccent
                        .withValues(alpha: _alphas[i - 1]),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        const SizedBox(width: AppDimens.space4),
        Text(
          '多',
          style: TextStyle(fontSize: 10, color: colors.secondaryText),
        ),
      ],
    );
  }

  /// 月份缩写（与 wait-home 桌面/移动同款中文标签）
  static String _monthAbbreviation(int month) {
    const names = [
      '1月', '2月', '3月', '4月', '5月', '6月',
      '7月', '8月', '9月', '10月', '11月', '12月',
    ];
    return names[month - 1];
  }
}

class _MonthLabel {
  final int col;
  final String text;

  const _MonthLabel({required this.col, required this.text});
}
