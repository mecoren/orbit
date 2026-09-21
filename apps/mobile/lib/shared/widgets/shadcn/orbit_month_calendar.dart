import 'package:flutter/material.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_motion.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/theme/icon_map.dart';
import '../../../core/theme/orbit_accents.dart';

/// 月历尺寸档位
enum AppCalendarSize { large, medium, small }

/// 日格渲染上下文（自定义 dayCellBuilder 使用）
class AppCalendarDayContext {
  const AppCalendarDayContext({
    required this.date,
    required this.inMonth,
    required this.isToday,
    required this.isSelected,
    required this.isWeekend,
    required this.isRowStart,
    required this.isRowEnd,
    this.prevDate,
    this.nextDate,
  });

  final DateTime date;
  final bool inMonth;
  final bool isToday;
  final bool isSelected;
  final bool isWeekend;
  final bool isRowStart;
  final bool isRowEnd;
  final DateTime? prevDate;
  final DateTime? nextDate;
}

/// 中国假日日历标记色（休息日识别色 / 春节 / 节气，与桌面端 month-calendar 同源）
class ChineseCalendarColors {
  ChineseCalendarColors._();

  /// 周末/休息日识别色缺省值；调用方可通过 [OrbitMonthCalendar.weekendColor]
  /// 按模块强调色覆盖，此处的常量仅作回退。
  static const Color weekend = Color(0xFF4C7DF0);

  /// 春节（农历新年）
  static const Color lunarNewYear = Color(0xFFF43F5E);

  /// 节气
  static const Color lunarNewMoon = Color(0xFF0EA5E9);

  /// 调休上班日的压暗底（与休息日浅识别底同源派生）
  static Color workdayBackground(Brightness brightness) =>
      brightness == Brightness.dark
          ? const Color(0x14F59E0B)
          : const Color(0x0FF59E0B);
}

/// 通用月历（设计系统 v3：`table_calendar` 承载网格与手势）。
///
/// **为什么换实现**：v2 的自绘月历要自己维护 42 格网格、翻页手势、行高与选中态；
/// v3 把这些交给成熟的 `table_calendar`（滑动翻页、`firstDay/lastDay` 边界、
/// `onDaySelected/onDayLongPressed` 语义齐全），我们只保留业务相关的**日格内容**——
/// 农历/节气副标签、休/班徽标、事件圆点、周末识别色、调休压暗底，
/// 全部经 `CalendarBuilders.prioritizedBuilder` 注入。
///
/// 业务数据源不变：农历走 `core/lunar/`，节假日走调用方传入的 [holidays]
/// （`holidayProvider` 取 `bridge.holidayList()`，空库回落 Rust 预置表）。
///
/// 头部仍由本组件自绘（标题 + 可选副标题 + 翻月箭头 + 额外动作插槽），
/// 因为调用方依赖 [onTitleTap]（跳年视图）与 [headerActions] 插槽，
/// 这比 `table_calendar` 内置头部更贴近既有信息架构。
///
/// 翻页口径：[month] 由父级单向驱动，[onMonthChange] 只上报
/// （**不在回调里 setState**，否则热重载会重置到初始月）。
class OrbitMonthCalendar extends StatelessWidget {
  const OrbitMonthCalendar({
    super.key,
    required this.month,
    this.size = AppCalendarSize.large,
    this.selected,
    this.onDayTap,
    this.onDayLongPress,
    this.onMonthChange,
    this.showHeader = true,
    this.showWeekdays = true,
    this.onTitleTap,
    this.headerSubtitle,
    this.headerActions = const <Widget>[],
    this.holidays,
    this.subLabelBuilder,
    this.eventDotsBuilder,
    this.dayCellBuilder,
    this.accentColor,
    this.weekendColor,
    this.selectableStart,
    this.selectableEnd,
  });

  /// 当前月（任一天即可，内部取当月 1 日）
  final DateTime month;
  final AppCalendarSize size;
  final DateTime? selected;
  final ValueChanged<DateTime>? onDayTap;

  /// 长按日格（对应桌面端右键：如长按某天快捷新增任务）
  final ValueChanged<DateTime>? onDayLongPress;

  final ValueChanged<DateTime>? onMonthChange;
  final bool showHeader;
  final bool showWeekdays;

  /// 点击头部标题（如打开年视图）；不传则标题不可点
  final VoidCallback? onTitleTap;
  final Widget? headerSubtitle;
  final List<Widget> headerActions;

  /// ymd → 是否休息日（true=休，false=班；small 档不渲染徽标）
  final Map<String, bool>? holidays;

  /// 副标签（large/medium；日历视图传 `ChineseAlmanac.daySubLabel`）
  final String? Function(DateTime date)? subLabelBuilder;

  /// 事件圆点颜色（仅 large；最多 4 个，无事件也保持等高防跳动）
  final List<Color> Function(DateTime date)? eventDotsBuilder;

  /// 完全接管日格渲染
  final Widget? Function(AppCalendarDayContext ctx)? dayCellBuilder;

  /// 今天/选中强调色（缺省为主题主色）
  final Color? accentColor;

  /// 周末/休息日识别色，数字与「休」徽标同源（缺省为固定周末蓝）
  final Color? weekendColor;

  /// 可选范围（small 档表单选择用，范围外禁用）
  final DateTime? selectableStart;
  final DateTime? selectableEnd;

  static const _weekdayLabels = ['一', '二', '三', '四', '五', '六', '日'];

  double get _cellHeight => switch (size) {
        AppCalendarSize.large => 74,
        AppCalendarSize.medium => 48,
        AppCalendarSize.small => 36,
      };

  double get _numberFont => switch (size) {
        AppCalendarSize.large => 19.5,
        AppCalendarSize.medium => 14,
        AppCalendarSize.small => 12.5,
      };

  double get _titleFont => switch (size) {
        AppCalendarSize.large => 22,
        AppCalendarSize.medium => 18,
        AppCalendarSize.small => 14,
      };

  double get _navIconSize => switch (size) {
        AppCalendarSize.large => 22,
        AppCalendarSize.medium => 18,
        AppCalendarSize.small => 16,
      };

  String _ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.ofContext(context);
    final accent = accentColor ?? OrbitAccents.themeAccent;
    final weekend = weekendColor ?? ChineseCalendarColors.weekend;
    final monthStart = DateTime(month.year, month.month, 1);

    // 可翻范围：调用方给了可选范围就用它，否则以当前月 ±5 年为界
    final firstDay = selectableStart ?? DateTime(month.year - 5, month.month, 1);
    final lastDay = selectableEnd ?? DateTime(month.year + 5, month.month, 1);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showHeader) ...[
          _buildHeader(context, colors, monthStart),
          const SizedBox(height: 4),
        ],
        TableCalendar<void>(
          // 网格与手势交给 table_calendar；今天/选中的底色由我们自己画，
          // 故把内置装饰全部置空，避免"双份高亮"
          firstDay: firstDay,
          lastDay: lastDay,
          focusedDay: monthStart,
          locale: 'zh_CN',
          startingDayOfWeek: StartingDayOfWeek.monday,
          calendarFormat: CalendarFormat.month,
          availableGestures: AvailableGestures.horizontalSwipe,
          headerVisible: false,
          daysOfWeekHeight:
              showWeekdays ? (size == AppCalendarSize.large ? 24 : 18) : 0,
          rowHeight: _cellHeight,
          pageAnimationDuration: AppMotion.normal,
          pageAnimationCurve: AppMotion.standard,
          selectedDayPredicate: (day) =>
              selected != null && isSameDay(day, selected),
          onDaySelected: (selectedDay, focusedDay) {
            if (_outOfRange(selectedDay)) return;
            onDayTap?.call(selectedDay);
            onMonthChange?.call(focusedDay);
          },
          // 注意：table_calendar 的 onDayLongPressed 复用双参 OnDaySelected 签名
          onDayLongPressed: (selectedDay, _) {
            if (_outOfRange(selectedDay)) return;
            onDayLongPress?.call(selectedDay);
          },
          onPageChanged: (focusedDay) => onMonthChange?.call(focusedDay),
          calendarStyle: const CalendarStyle(
            todayDecoration: BoxDecoration(),
            selectedDecoration: BoxDecoration(),
            markerDecoration: BoxDecoration(),
            outsideDaysVisible: true,
            cellMargin: EdgeInsets.zero,
          ),
          calendarBuilders: CalendarBuilders<void>(
            // 单一入口接管全部日格（含前后月补位），保证 today/selected/
            // 休班/农历副标签/事件圆点 的判定与旧实现完全一致
            prioritizedBuilder: (context, day, _) =>
                _buildCell(context, colors, day, accent, weekend),
            dowBuilder: showWeekdays
                ? (context, day) => Center(
                      child: Text(
                        _weekdayLabels[(day.weekday - 1) % 7],
                        style: TextStyle(
                          fontSize: switch (size) {
                            AppCalendarSize.large => 14,
                            AppCalendarSize.medium => 12,
                            AppCalendarSize.small => 10,
                          },
                          color: colors.secondaryText,
                        ),
                      ),
                    )
                : null,
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(
    BuildContext context,
    AppColorSet colors,
    DateTime monthStart,
  ) {
    final today = DateTime.now();
    return Row(
      children: [
        InkWell(
          onTap: onTitleTap,
          borderRadius: AppShapes.small,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                if (monthStart.year != today.year) ...[
                  Text(
                    '${monthStart.year}年',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: colors.secondaryText,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
                Text(
                  '${monthStart.month}月',
                  style: TextStyle(
                    fontSize: _titleFont,
                    fontWeight: FontWeight.w800,
                    color: colors.titleText,
                  ),
                ),
              ],
            ),
          ),
        ),
        ?headerSubtitle,
        const Spacer(),
        IconButton(
          onPressed: onMonthChange == null
              ? null
              : () => onMonthChange!(
                    monthStart.month == 1
                        ? DateTime(monthStart.year - 1, 12)
                        : DateTime(monthStart.year, monthStart.month - 1),
                  ),
          icon: Icon(OrbitIcons.chevronLeft, size: _navIconSize + 4),
          tooltip: '上个月',
          visualDensity: VisualDensity.compact,
        ),
        IconButton(
          onPressed: onMonthChange == null
              ? null
              : () => onMonthChange!(
                    monthStart.month == 12
                        ? DateTime(monthStart.year + 1, 1)
                        : DateTime(monthStart.year, monthStart.month + 1),
                  ),
          icon: Icon(OrbitIcons.chevronRight, size: _navIconSize + 4),
          tooltip: '下个月',
          visualDensity: VisualDensity.compact,
        ),
        ...headerActions,
      ],
    );
  }

  bool _outOfRange(DateTime date) =>
      (selectableStart != null && date.isBefore(selectableStart!)) ||
      (selectableEnd != null && date.isAfter(selectableEnd!));

  Widget _buildCell(
    BuildContext context,
    AppColorSet colors,
    DateTime date,
    Color accent,
    Color weekend,
  ) {
    final ymd = _ymd(date);
    final now = DateTime.now();
    final inMonth = date.month == month.month && date.year == month.year;
    final isToday = isSameDay(date, now);
    final isSelected = selected != null && _ymd(selected!) == ymd;
    final isWeekend =
        date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
    final isOffDay = holidays?[ymd] == true;
    final isWorkday = holidays?[ymd] == false;
    final outOfRange = _outOfRange(date);

    final dayContext = AppCalendarDayContext(
      date: date,
      inMonth: inMonth,
      isToday: isToday,
      isSelected: isSelected,
      isWeekend: isWeekend,
      // 周一起始：列 0 = 周一（行首），列 6 = 周日（行尾）
      isRowStart: date.weekday == DateTime.monday,
      isRowEnd: date.weekday == DateTime.sunday,
      prevDate: date.subtract(const Duration(days: 1)),
      nextDate: date.add(const Duration(days: 1)),
    );

    // 完全接管模式
    if (dayCellBuilder != null) {
      final custom = dayCellBuilder!(dayContext);
      if (custom != null) return SizedBox(height: _cellHeight, child: custom);
    }

    // ===== 默认日格 =====
    // 今天 = 实心强调块；选中（非今天）= 描边
    final filled = isToday;
    final outlined = !isToday && isSelected;
    final numberColor = outOfRange
        ? colors.deactivatedText.withValues(alpha: 0.5)
        : filled
            ? const Color(0xFFFFFFFF)
            : !inMonth
                ? colors.deactivatedText
                : isWeekend
                    ? weekend
                    : colors.titleText;

    final showBadge = holidays != null &&
        holidays!.containsKey(ymd) &&
        size != AppCalendarSize.small;

    final Color? cellBackground;
    if (filled) {
      cellBackground = accent;
    } else if (isOffDay) {
      cellBackground = weekend.withValues(alpha: 0.10);
    } else if (isWorkday) {
      cellBackground = ChineseCalendarColors.workdayBackground(
        Theme.of(context).brightness,
      );
    } else {
      cellBackground = null;
    }

    final sub = size != AppCalendarSize.small && subLabelBuilder != null
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              subLabelBuilder!(date) ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: size == AppCalendarSize.large ? 12 : 9,
                height: 1.1,
                // 今天实心块内副标签转白（强调色底上灰字对比度不足）
                color: filled
                    ? const Color(0xFFFFFFFF).withValues(alpha: 0.9)
                    : colors.secondaryText.withValues(alpha: inMonth ? 1 : 0.5),
              ),
            ),
          )
        : null;

    final dots = size == AppCalendarSize.large && eventDotsBuilder != null
        ? SizedBox(
            // 固定高度占位（无事件也保持等高，避免选中/今天时格子内容跳动）
            height: 6,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final color in eventDotsBuilder!(date).take(4))
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 1),
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                  ),
              ],
            ),
          )
        : null;

    final isCircle = size == AppCalendarSize.small;

    return SizedBox(
      height: _cellHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 3),
        child: Stack(
          children: [
            Container(
              width: double.infinity,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: cellBackground,
                shape: isCircle ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: isCircle ? null : AppShapes.small,
                border:
                    outlined ? Border.all(color: accent, width: 1.5) : null,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: _numberFont,
                        fontWeight: isToday || isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: numberColor,
                      ),
                    ),
                    ?sub,
                    ?dots,
                  ],
                ),
              ),
            ),
            if (showBadge)
              Positioned(
                top: 0,
                right: 0,
                child: _HolidayBadge(
                  isOff: holidays![ymd] == true,
                  weekendColor: weekend,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 休/班徽标（色块右上角独立圆标：休=周末蓝底、班=橙红底）
class _HolidayBadge extends StatelessWidget {
  const _HolidayBadge({required this.isOff, required this.weekendColor});

  final bool isOff;
  final Color weekendColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: isOff ? weekendColor : const Color(0xFFF97316),
        shape: BoxShape.circle,
      ),
      child: Text(
        isOff ? '休' : '班',
        style: const TextStyle(
          fontSize: 9,
          height: 1,
          fontWeight: FontWeight.w600,
          color: Color(0xFFFFFFFF),
        ),
      ),
    );
  }
}
