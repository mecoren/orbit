import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/lunar/chinese_almanac.dart';
import '../../core/lunar/lunar_calendar.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/orbit_accents.dart';
import '../../shared/widgets/shadcn/orbit_month_calendar.dart';
import '../../shared/widgets/shadcn/orbit_page_header.dart';
import '../../core/theme/icon_map.dart';

/// 年份边界（与 LunarCalendar 压缩表覆盖范围一致）
const _kMinYear = 1901;
const _kMaxYear = 2100;

/// 迷你月历日格高（日期行等距；空位占位同高，避免行高不齐）
const double _kDayCellHeight = 30;

/// 年视图选择页 /todo/calendar/year（Days Matter 风格）
///
/// 整年 12 个迷你月历（3 列），PageView 左右滑动切换年份，
/// 点击任意日期返回月历并定位到该日。
///
/// 自 wait-home/mobile year_overview_page 移植，适配 orbit 标题栏。
///
/// 标记口径（与桌面端 year-overview 同源）：
/// - 今天：强调色实心圆 + 白字
/// - 春节（正月初一）：红色下划线
/// - 农历每月初一：蓝色下划线
class YearOverviewPage extends StatefulWidget {
  const YearOverviewPage({
    super.key,
    required this.initialYear,
    this.initialMonth,
  });

  final int initialYear;

  /// 高亮提示的月份（打开时所在月，仅视觉参考）
  final int? initialMonth;

  /// 推入年视图；返回选中的日期（取消返回 null）
  static Future<DateTime?> push(
    BuildContext context, {
    required int initialYear,
    int? initialMonth,
  }) {
    return Navigator.of(context).push<DateTime>(
      MaterialPageRoute<DateTime>(
        builder: (_) => YearOverviewPage(
          initialYear: initialYear,
          initialMonth: initialMonth,
        ),
      ),
    );
  }

  @override
  State<YearOverviewPage> createState() => _YearOverviewPageState();
}

class _YearOverviewPageState extends State<YearOverviewPage> {
  late final PageController _controller = PageController(
    initialPage: widget.initialYear.clamp(_kMinYear, _kMaxYear) - _kMinYear,
  );
  late int _year = widget.initialYear.clamp(_kMinYear, _kMaxYear);

  void _shiftYear(int delta) {
    final target = (_year + delta).clamp(_kMinYear, _kMaxYear);
    if (target == _year) return;
    HapticFeedback.selectionClick();
    _controller.animateToPage(
      target - _kMinYear,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // 今天实心格/周末数字/当前月标题走全局主题强调色（与桌面端日历同源）；
    // scheme.primary 是 M3 fromSeed 派生值（#455E91），与桌面明显偏差
    final accent = OrbitAccents.themeAccent;

    return Scaffold(
      backgroundColor: scheme.surface,
      body: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: OrbitPageHeader.rowHeight),
                // ===== 头部：大年份 + 干支生肖/图例 + 切年 =====
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppDimens.space12,
                    AppDimens.space4,
                    AppDimens.space8,
                    0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(width: AppDimens.space8),
                      // 大年份：参考图（wait-home 年视图）为超大字重标题，
                      // 比 headlineLarge 明显更大，此处显式压字号 + 收紧字距
                      Text(
                        '$_year',
                        style: theme.textTheme.headlineLarge?.copyWith(
                          fontSize: 44,
                          height: 1.05,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(width: AppDimens.space12),
                      Padding(
                        // 与 44px 年份的视觉重心对齐（参考图图例居年份上/中段）
                        padding: const EdgeInsets.only(top: AppDimens.space12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _LegendLine(
                              color: ChineseCalendarColors.lunarNewYear,
                              label: ChineseAlmanac.lunarYearLabel(_year),
                            ),
                            const SizedBox(height: AppDimens.space6),
                            const _LegendLine(
                              color: ChineseCalendarColors.lunarNewMoon,
                              label: '农历初一',
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      Padding(
                        padding: const EdgeInsets.only(top: AppDimens.space6),
                        child: Row(
                          children: [
                            IconButton(
                              onPressed: () => _shiftYear(-1),
                              icon: const Icon(OrbitIcons.chevronLeft),
                              tooltip: '上一年',
                            ),
                            IconButton(
                              onPressed: () => _shiftYear(1),
                              icon: const Icon(OrbitIcons.chevronRight),
                              tooltip: '下一年',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // ===== 年份页面（左右滑动切年） =====
                Expanded(
                  child: PageView.builder(
                    controller: _controller,
                    onPageChanged: (index) =>
                        setState(() => _year = _kMinYear + index),
                    itemCount: _kMaxYear - _kMinYear + 1,
                    itemBuilder: (context, index) {
                      final year = _kMinYear + index;
                      return SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(
                          AppDimens.space8,
                          AppDimens.space8,
                          AppDimens.space8,
                          AppDimens.space32,
                        ),
                        child: Column(
                          children: [
                            for (var row = 0; row < 4; row++) ...[
                              // 月份块之间留出参考图同款的段落呼吸感
                              if (row > 0) const SizedBox(height: 18),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  for (var col = 0; col < 3; col++)
                                    Expanded(
                                      child: _MiniMonth(
                                        year: year,
                                        month: row * 3 + col,
                                        highlightMonth: year == _year
                                            ? widget.initialMonth
                                            : null,
                                        accent: accent,
                                        onPick: (day) {
                                          HapticFeedback.selectionClick();
                                          Navigator.of(context).pop(
                                            DateTime(
                                                year, row * 3 + col + 1, day),
                                          );
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: OrbitPageHeader(
              title: '选择日期',
              showBack: true,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendLine extends StatelessWidget {
  const _LegendLine({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 2,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                fontSize: 12.5,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
        ),
      ],
    );
  }
}

/// 迷你月历（仅本月日期，无前后月补位）
class _MiniMonth extends StatelessWidget {
  const _MiniMonth({
    required this.year,
    required this.month,
    required this.accent,
    required this.onPick,
    this.highlightMonth,
  });

  final int year;
  final int month;

  /// 今天/当前月强调色
  final Color accent;
  final ValueChanged<int> onPick;

  /// 打开时所在的月份（标题着色提示当前位置）
  final int? highlightMonth;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final today = DateTime.now();
    final first = DateTime(year, month, 1);
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final offset = (first.weekday + 6) % 7; // 周一=0
    final isCurrentMonth = year == today.year && month == today.month;

    final rows = <List<int?>>[];
    final cells = <int?>[
      ...List.filled(offset, null),
      ...List.generate(daysInMonth, (i) => i + 1),
    ];
    while (cells.length % 7 != 0) {
      cells.add(null);
    }
    for (var i = 0; i < cells.length; i += 7) {
      rows.add(cells.sublist(i, i + 7));
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.space6, vertical: AppDimens.space4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onPick(1),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                  vertical: AppDimens.space2, horizontal: AppDimens.space4),
              child: Text(
                '${month + 1}月',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: isCurrentMonth || month + 1 == highlightMonth
                      ? accent
                      : scheme.onSurface,
                ),
              ),
            ),
          ),
          const SizedBox(height: AppDimens.space6),
          Row(
            children: [
              for (final label in _weekdayLabels)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 10.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: AppDimens.space2),
          for (final row in rows)
            Row(
              children: [
                for (final day in row)
                  Expanded(
                    child: day == null
                        ? const SizedBox(height: _kDayCellHeight)
                        : _Day(
                            date: DateTime(year, month, day),
                            accent: accent,
                            isToday: year == today.year &&
                                month == today.month &&
                                day == today.day,
                            onPick: () => onPick(day),
                          ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Day extends StatelessWidget {
  const _Day({
    required this.date,
    required this.accent,
    required this.isToday,
    required this.onPick,
  });

  final DateTime date;

  /// 今天实心圆 / 周末数字强调色
  final Color accent;
  final bool isToday;
  final VoidCallback onPick;

  static const _springColor = ChineseCalendarColors.lunarNewYear;
  static const _newMoonColor = ChineseCalendarColors.lunarNewMoon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;

    // 农历标记：春节红杠 / 初一蓝杠
    Color? markColor;
    final lunar = LunarCalendar.solarToLunar(date);
    if (lunar != null && lunar.day == 1 && !lunar.isLeapMonth) {
      markColor = lunar.month == 1 ? _springColor : _newMoonColor;
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPick,
      child: SizedBox(
        height: _kDayCellHeight,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 今天 = 强调色圆角方块（与月视图日格 BorderRadius.circular(10)
            // 同形制，非圆形）；农历杠（春节红/初一蓝）与数字留 4px 间距
            //（原 bottom:1 紧贴数字底边视觉粘连）
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: isToday
                  ? BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(8),
                    )
                  : null,
              child: Text(
                '${date.day}',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontSize: 12.5,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  fontWeight: isToday ? FontWeight.w800 : FontWeight.w500,
                  color: isToday
                      ? Colors.white
                      : isWeekend
                          ? accent
                          : theme.colorScheme.onSurface,
                ),
              ),
            ),
            if (markColor != null)
              Positioned(
                bottom: 1,
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Container(
                    width: 13,
                    height: 2,
                    decoration: BoxDecoration(
                      color: markColor,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
